// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";

import "src/Vault.sol";
import "test/USDC.sol";
import "test/WETH.sol";
import "test/MockV3Aggregator.sol";
using stdStorage for StdStorage;


abstract contract StateZero is Test {
    USDC public usdc;
    WETH9 public weth;
    MockV3Aggregator public priceFeed;

    Vault public vault;
    address user;
    address deployer;

    event Deposit(address indexed collateralAsset, address indexed user, uint collateralAmount);  
    event Borrow(address indexed debtAsset, address indexed user, uint debtAmount); 
    event Repay(address indexed debtAsset, address indexed user, uint debtAmount);
    event Withdraw(address indexed collateralAsset, address indexed user, uint collateralAmount);  
    event Liquidation(address indexed collateralAsset, address indexed debtAsset, address indexed user, uint debtToCover, uint liquidatedCollateralAmount);


    function setUp() public virtual {
        //vm.chainId(4);
        usdc = new USDC();
        vm.label(address(usdc), "usdc contract");

        weth = new WETH9();
        vm.label(address(weth), "weth contract");

        priceFeed = new MockV3Aggregator(18, 1e18);
        vm.label(address(priceFeed), "priceFeed contract");

        deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
        vm.label(deployer, "deployer");

        user = address(1);
        vm.label(user, "user");
        
        // collateralLevel@80% = 0.8 = 8e17
        vault = new Vault(address(usdc), address(weth), address(priceFeed));
        vm.label(address(vault), "vault contract");
        
        //usdc.mint(address(vault), 10000*10**18);
        //......accessing stdstore instance........\\
        stdstore    
        .target(address(usdc))
        .sig(usdc.balanceOf.selector)         //select balanceOf mapping
        .with_key(address(vault))           //set mapping key balanceOf(address(vault))
        .checked_write(100000 * 1e18);      //data to be written to the storage slot -> balanceOf(address(vault)) = 10000*10**18
    }

    function getMaxDebt(address user_) public view returns(uint) {
        (,int price,,,) = priceFeed.latestRoundData();

        uint availableCollateral = vault.deposits(user_) - vault.getCollateralRequired(vault.debts(user_));
        uint maxDebt = (availableCollateral * vault.scalarFactor() / uint(price));
        maxDebt = vault.scaleDecimals(maxDebt, weth.decimals(), usdc.decimals());
        return maxDebt;
      }

}


contract StateZeroTest is StateZero {
 
    function testVaultHasUsdc() public {
        console2.log("Check Vault has 100 usdc on deployment");
        uint vaultUsdc = usdc.balanceOf(address(vault));
        assertTrue(vaultUsdc == 100000 * 1e18);
    }


    function testUserDepositsWETH() public {
        vm.deal(user, 1 ether);
        vm.startPrank(user);

        //weth.deposit{value: 1 ether}();
        //......accessing stdstore instance........\\
        stdstore    
        .target(address(weth))
        .sig(weth.balanceOf.selector)         //select balanceOf mapping
        .with_key(address(user))            //set mapping key balanceOf(address(user))
        .checked_write(1 ether);           //data to be written to the storage slot -> balanceOf(address(user)) = 1 ether | assertTrue(weth.balanceOf(user) == 1 ether); 

        vm.expectEmit(true, true, false, true);
        emit Deposit(address(weth), user, 1 ether);

        weth.approve(address(vault), 1 ether);
        vault.deposit(1 ether);
        assertTrue(vault.deposits(user) == 1 ether);

        vm.stopPrank();
    }
}


abstract contract StateDeposited is StateZero {

    function setUp() public override virtual {
        super.setUp();

        // user deposits 1 WETH into Vault
        vm.deal(user, 1 ether);

        //weth.deposit{value: 1 ether}();
        //......accessing stdstore instance........\\
        stdstore    
        .target(address(weth))
        .sig(weth.balanceOf.selector)         //select balanceOf mapping
        .with_key(address(user))            //set mapping key balanceOf(address(user))
        .checked_write(1 ether);           //data to be written to the storage slot -> balanceOf(address(user)) = 1 ether
        
        vm.startPrank(user);
        weth.approve(address(vault), 1 ether);
        vault.deposit(0.5 ether);
        vm.stopPrank();
    }
}

contract StateDepositedTest is StateDeposited {
    // Vault has 100 usdc & 1 WETH deposited by user

    function testCannotWithdrawInExcess(uint wethAmount) public {
        console2.log("Cannot withdraw in excess of deposits");
        vm.assume(wethAmount > 0.5 ether);
        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdraw(wethAmount);
    }

    function testCannotBeLiquidatedWithoutDebt() public {
        console2.log("Cannot be wrongly liquidated with no debt");
        vault.liquidation(user);
        assertTrue(vault.deposits(user) == 0.5 ether);
    }

    function testCannotBorrowInExcess() public {
        console2.log("Cannot borrow in excess of collateral provided");
        uint maxDebt = StateZero.getMaxDebt(user);       
        
        vm.prank(user);
        vm.expectRevert("Insufficient collateral!");
        vault.borrow(maxDebt * 2);
    }

    function testWithdraw(uint wethAmount) public {
        console2.log("User can withdraw freely in absence of debt");
        vm.assume(wethAmount > 0);
        vm.assume(wethAmount <= 0.5 ether);
        
        uint userInitialDeposit = vault.deposits(user);
        vm.prank(user);

        vm.expectEmit(true, true, false, true);
        emit Withdraw(address(weth), user, wethAmount);
    
        vault.withdraw(wethAmount);

        assertTrue(vault.deposits(user) == userInitialDeposit - wethAmount);
        assertTrue(weth.balanceOf(user) == 0.5 ether + wethAmount);
    }

    function testBorrow(uint usdcAmount) public {
        console2.log("User can borrow against collateral provided");
        uint maxDebt = StateZero.getMaxDebt(user);
  
        vm.assume(usdcAmount > 0 && usdcAmount < maxDebt);
        
        vm.expectEmit(true, true, false, true);
        emit Borrow(address(usdc), user, usdcAmount);

        vm.prank(user);
        vault.borrow(usdcAmount);

        assertTrue(vault.debts(user) == usdcAmount);
    }
}

abstract contract StateBorrowed is StateDeposited {
    function setUp() public override virtual {
        super.setUp();

        // user borrows 1/2 of maxDebt
        uint halfDebt = StateZero.getMaxDebt(user)/2;
        vm.prank(user);
        vault.borrow(halfDebt);
        assertTrue(vault.debts(user) == halfDebt);
    }
}

contract StateBorrowedTest is StateBorrowed {

    function testCannotBorrowExceedingMargin() public {
        console2.log("With existing debt, user should be unable to exceed margin limits");
        uint maxDebt = StateZero.getMaxDebt(user);       
        vm.prank(user);
        vm.expectRevert("Insufficient collateral!");
        vault.borrow(maxDebt*2);
    }

    function testCannotWithdrawExceedingMargin(uint excessWithdrawl) public {
        console2.log("With existing debt, user should be unable to withdraw in excess of required collateral");

        uint collateralRequired = vault.getCollateralRequired(vault.debts(user));
        uint spareDeposit = vault.deposits(user) - collateralRequired;
        vm.assume(excessWithdrawl > spareDeposit);

        vm.prank(user);
        vm.expectRevert("Collateral unavailable!");
        vault.withdraw(excessWithdrawl);
    }

    function testCannotBeLiquidatedAtSamePrice() public {
        console2.log("Ceteris paribus, user should not be liquidated");
        uint userDebt = vault.debts(user);
        uint userDeposit = vault.deposits(user);

        vault.liquidation(user);
        assertTrue(vault.deposits(user) == userDeposit);
        assertTrue(vault.debts(user) == userDebt);
    }

    function testRepay(uint repayAmount) public {
        console2.log("User repays debt");
        uint userDebt = vault.debts(user);

        vm.assume(repayAmount <= userDebt);
        vm.assume(repayAmount > 0);
        

        vm.expectEmit(true, true, false, true);
        emit Repay(address(usdc), user, repayAmount);

        vm.startPrank(user);
        usdc.approve(address(vault), repayAmount);
        vault.repay(repayAmount);   
        vm.stopPrank();

        assertTrue(vault.debts(user) == userDebt - repayAmount);
    }
}


abstract contract StateRateChange is StateBorrowed {
    function setUp() public override virtual {
        super.setUp();

        // user borrowed 1/2 of maxDebt earlier
        // price appreciates -> 1 DAI is convertible for double the WETH
        //1 expect revert on borrowing the other half (because of rate change) 
        //2 borrow less and it works
        priceFeed.updateAnswer(1e18 * 2);
    }
}

contract StateRateChangeTest is StateRateChange {

    function testCannotBorrowFurtherOnRateChange() public {
        console2.log("Rate appreciates: User is unable to borrow another half of original debt amount due to rate change");
        console2.log("Rate appreciates: Twice the amout of collateral is needed to support debt position. No free collateral.");

        uint userDebt = vault.debts(user);
        uint usedCollateral = vault.getCollateralRequired(userDebt);
        assertEq(usedCollateral, 0.5 ether);

        vm.prank(user);
        vm.expectRevert("Insufficient collateral!");
        vault.borrow(0.1 ether);

    }
}

abstract contract StateRateChange2 is StateRateChange {
    function setUp() public override virtual {
        super.setUp();

        // user borrowed 1/2 of maxDebt earlier
        // price appreciates -> 1 DAI is convertible for double the WETH
        //1 expect revert on borrowing the other half (because of rate change) 
        //2 borrow less and it works
        priceFeed.updateAnswer(1e18 + (1e18 / 4));
    }

    function getMaxDebt2(address user_) public view returns(uint) {
        (,int price,,,) = priceFeed.latestRoundData();

        uint availableCollateral = vault.deposits(user_) - vault.getCollateralRequired(vault.debts(user_));
        uint maxDebt = (availableCollateral * vault.scalarFactor() / uint(price));
        maxDebt = vault.scaleDecimals(maxDebt, weth.decimals(), usdc.decimals());
        return maxDebt;
    }

}

contract StateRateChange2Test is StateRateChange2 {

    function testBorrowLessAtNewRate() public {
        console2.log("Rate appreciates: User can borrow a lesser amount of DAI than before");
        
        uint currentAvailableDebt = StateRateChange2.getMaxDebt2(user); 

        // testing
        uint collateralRequired = vault.getCollateralRequired(currentAvailableDebt);
        uint availableCollateral = vault.deposits(user) - vault.getCollateralRequired(vault.debts(user));
        assertEq(currentAvailableDebt, availableCollateral);

        vm.expectEmit(true, true, false, true);
        emit Borrow(address(usdc), user, availableCollateral/2);
        
        vm.prank(user);
        vault.borrow(availableCollateral/2);
    }   

}


abstract contract StateLiquidated is StateBorrowed {
    function setUp() public override virtual {
        super.setUp();

        // user borrows 1/2 of maxDebt earlier
        // modify price to cause liquidation
        // if 1 WETH is converted to less usdc, at mkt price, Vault will be unable to recover usdc lent
        // USDC/WETH price must appreciate for liquidation (usdc has devalued against WETH)
        priceFeed.updateAnswer(386372840000000 * 1e5);
    }
}

contract StateLiquidatedTest is StateLiquidated {

    function testLiquidationOnPriceAppreciation() public {
        console2.log("Price appreciated significantly: user should be liquidated");
        uint userDebt = vault.debts(user);
        uint userDeposit = vault.deposits(user);

        vm.expectEmit(true, true, false, true);
        emit Liquidation(address(weth),address(usdc), user, userDebt, userDeposit);

        vault.liquidation(user);
        assertTrue(vault.deposits(user) == 0);
        assertTrue(vault.debts(user) == 0);
    }

    function testOnlyOwnerCanCallLiquidate() public {
        console2.log("Only Owner of contract can call liquidate: onlyOwner modifier");
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.liquidation(user);
    }
   
}

