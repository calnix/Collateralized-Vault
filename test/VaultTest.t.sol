// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/console2.sol";

import "src/Vault.sol";
import "test/Dai.sol";
import "test/WETH.sol";
import "test/MockV3Aggregator.sol";


abstract contract StateZero is Test {
    Dai public dai;
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
        dai = new Dai(4);
        vm.label(address(dai), "dai contract");

        weth = new WETH9();
        vm.label(address(weth), "weth contract");

        priceFeed = new MockV3Aggregator(18, 386372840000000);
        vm.label(address(priceFeed), "priceFeed contract");

        deployer = 0xb4c79daB8f259C7Aee6E5b2Aa729821864227e84;
        vm.label(deployer, "deployer");

        user = address(1);
        vm.label(user, "user");

        //mint 100 DAI for Vault
        vault = new Vault(address(dai), address(weth), address(priceFeed),8,10);
        vm.label(address(vault), "vault contract");
        dai.mint(address(vault), 10000*10**18);
    }
}


contract StateZeroTest is StateZero {
 
    function testVaultHasDAI() public {
        console2.log("Check Vault has 100 DAI on deployment");
        uint vaultDAI = dai.balanceOf(address(vault));
        assertTrue(vaultDAI == 10000*10**18);
    }


    function testUserDepositsWETH () public {
        vm.deal(user, 1 ether);
        vm.startPrank(user);

        weth.deposit{value: 1 ether}();
        assertTrue(weth.balanceOf(user) == 1 ether); 

        vm.expectEmit(true, true, false, true);
        emit Deposit(address(weth), user, 1 ether);

        weth.approve(address(vault), 1 ether);
        vault.deposit(1 ether);
        assertTrue(vault.deposits(user) == 1 ether);

        vm.stopPrank;
    }

}


abstract contract StateDeposited is StateZero {

    function setUp() public override virtual {
        super.setUp();

        // user deposits 1 WETH into Vault
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        weth.deposit{value: 1 ether}();
        weth.approve(address(vault), 1 ether);
        vault.deposit(1 ether);
        vm.stopPrank();
    }
}

contract StateDepositedTest is StateDeposited {
    // Vault has 100 DAI & 1 WETH deposited by user

    function testCannotWithdrawInExcess(uint wethAmount) public {
        console2.log("Cannot withdraw in excess of deposits");
        vm.assume(wethAmount > 1 ether);
        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdraw(wethAmount);
    }

    function testCannotBeLiquidatedWithoutDebt() public {
        console2.log("Cannot be wrongly liquidated with no debt");
        vault.liquidation(user);
        assertTrue(vault.deposits(user) == 1 ether);
    }

    function testCannotBorrowInExcess(uint excessDebt) public {
        console2.log("Cannot borrow in excess of collateral provided");
        uint maxDebt = vault.getMaxDebt(user);
        vm.assume(excessDebt > maxDebt);
        
        vm.prank(user);
        vm.expectRevert("Insufficient collateral!");
        vault.borrow(excessDebt);
    }

    function testWithdraw(uint wethAmount) public {
        console2.log("User can withdraw freely in absence of debt");
        vm.assume(wethAmount > 0);
        vm.assume(wethAmount <= 1 ether);
        
        uint userInitialDeposit = vault.deposits(user);
        vm.prank(user);

        vm.expectEmit(true, true, false, true);
        emit Withdraw(address(weth), user, wethAmount);
    
        vault.withdraw(wethAmount);

        assertTrue(vault.deposits(user) == userInitialDeposit - wethAmount);
        assertTrue(weth.balanceOf(user) == wethAmount);
    }

    function testBorrow(uint daiAmount) public {
        console2.log("User can borrow against collateral provided");
        uint maxDebt = vault.getMaxDebt(user);
        vm.assume(daiAmount > 0);
        vm.assume(daiAmount <= maxDebt);        
        
        vm.expectEmit(true, true, false, true);
        emit Borrow(address(dai), user, daiAmount);

        vm.prank(user);
        vault.borrow(daiAmount);
    }
}

abstract contract StateBorrowed is StateDeposited {
    function setUp() public override virtual {
        super.setUp();

        // user borrows 1/2 of maxDebt
        vm.startPrank(user);
        uint halfDebt = vault.getMaxDebt(user)/2;
        vault.borrow(halfDebt);
        vm.stopPrank();
    }
}

contract StateBorrowedTest is StateBorrowed {

    function testCannotBorrowExceedingMargin(uint excessDebt) public {
        console2.log("With existing debt, user should be unable to exceed margin limits");
        uint maxDebt = vault.getMaxDebt(user);
        vm.assume(excessDebt > maxDebt);
        
        vm.prank(user);
        vm.expectRevert("Insufficient collateral!");
        vault.borrow(excessDebt);
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
        emit Repay(address(dai), user, repayAmount);

        vm.startPrank(user);
        dai.approve(address(vault), repayAmount);
        vault.repay(repayAmount);   
        vm.stopPrank();

    }
}


abstract contract StateLiquidated is StateBorrowed {
    function setUp() public override virtual {
        super.setUp();

        // user borrows 1/2 of maxDebt earlier
        // modify price to cause liquidation
        // if 1 WETH is converted to less DAI, at mkt price, Vault will be unable to recover DAI lent
        // DAI/WETH price must appreciate for liquidation (DAI has devalued against WETH)
        priceFeed.updateAnswer(386372840000000*10**5);
    }
}

contract StateLiquidatedTest is StateLiquidated {

    function testLiquidationOnPriceAppreciation() public {
        console2.log("DAI/WETH price appreciated significantly; user should be liquidated");
        uint userDebt = vault.debts(user);
        uint userDeposit = vault.deposits(user);

        vm.expectEmit(true, true, false, true);
        emit Liquidation(address(weth),address(dai), user, userDebt, userDeposit);

        vault.liquidation(user);
        assertTrue(vault.deposits(user) == 0);
        assertTrue(vault.debts(user) == 0);
    }

    function testOnlyOwnerCanCallLiquidate() public {
        console2.log("Only Owner of contract can call liquidate -onlyOwner modifier");
        vm.prank(user);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.liquidation(user);
    }
}

