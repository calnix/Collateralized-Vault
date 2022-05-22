// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "lib/yield-utils-v2/contracts/token/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";


interface IERC20Decimals is IERC20 {
    function decimals() external view returns (uint);
}

contract Vault is Ownable {

    ///@dev Vault records collateral deposits of each user
    mapping (address => uint) public deposits; 

    ///@dev Vault records debt holdings of each user
    mapping (address => uint) public debts;  

    ///@dev ERC20 interface specifying token contract functions
    IERC20Decimals public immutable collateral;    
    IERC20Decimals public immutable debt;  

    ///@dev Asset Pricefeed interface from Chainlink
    AggregatorV3Interface public immutable priceFeed;   
    
    ///@dev Emitted on deposit()
    ///@param user The address of the user calling deposit()
    ///@param collateralAmount The amount of collateral asset deposited
    event Deposit(address indexed user, uint collateralAmount);  

    ///@dev Emitted on borrow()
    ///@param user The address of the user calling borrow()
    ///@param debtAmount The amount of debt asset borrowed
    event Borrow(address indexed user, uint debtAmount); 

    ///@dev Emitted on repay()
    ///@param user The address of the user calling repay()
    ///@param debtAmount The amount of debt asset being repaid
    event Repay(address indexed user, uint debtAmount);

    ///@dev Emitted on withdraw()
    ///@param user The address of the user calling withdraw()
    ///@param collateralAmount The amount of collateral asset withdrawn
    event Withdraw(address indexed user, uint collateralAmount);  

    ///@dev Emitted on liquidation()
    ///@param user The address of the user calling withdraw()
    ///@param debtToCover The amount of debt the liquidator wants to cover
    ///@param liquidatedCollateralAmount The amount of collateral received by the liquidator
    event Liquidation(address indexed user, uint debtToCover, uint liquidatedCollateralAmount);
    
    ///@dev Returns decimal places of price as dictated by Chainlink Oracle
    uint public immutable scalarFactor;
    
    ///@dev Returns decimal places of tokens as dictated by their respective contracts
    uint public collateralDecimals;
    uint public debtDecimals;

    
    constructor(address dai_, address weth_, address priceFeedAddress) {
        collateral = IERC20Decimals(weth_);
        debt = IERC20Decimals(dai_);

        priceFeed = AggregatorV3Interface(priceFeedAddress);
        scalarFactor = 10**priceFeed.decimals();

        collateralDecimals = collateral.decimals();
        debtDecimals = debt.decimals();
    }

    /*////////////////////////////////////////////////////////////////////////*/
    /*                             TRANSACTIONS                               */
    /*////////////////////////////////////////////////////////////////////////*/

    ///@dev Users deposit collateral asset into Vault
    ///@param collateralAmount Amount of collateral to deposit
    function deposit(uint collateralAmount) external {       
        deposits[msg.sender] += collateralAmount;

        bool sent = collateral.transferFrom(msg.sender, address(this), collateralAmount);
        require(sent, "Deposit failed!");  
        emit Deposit(msg.sender, collateralAmount);
    }
    
    ///@notice Users borrow debt asset calculated based on collateralization level and their deposits 
    ///@dev See _isCollateralized() for collateralization calculation
    ///@param debtAmount Amount of debt asset to borrow
    function borrow(uint debtAmount) external {      
        uint newDebt = debts[msg.sender] + debtAmount;
        require(_isCollateralized(newDebt, deposits[msg.sender]),"Would become undercollateralized");
        
        debts[msg.sender] = newDebt;
        bool sent = debt.transfer(msg.sender, debtAmount);
        require(sent, "Borrow failed!");       
        emit Borrow(msg.sender, debtAmount);
    }

    ///@notice Users repay their debt, in debt asset terms
    ///@dev This covers partial and full repayment
    ///@param debtAmount Amount of debt asset to repay
    function repay(uint debtAmount) external {
        debts[msg.sender] -= debtAmount;

        bool sent = debt.transferFrom(msg.sender, address(this), debtAmount);
        require(sent, "Repayment failed!");       
        emit Repay(msg.sender, debtAmount);   
    }


    ///@notice Users withdraw their deposited collateral
    ///@dev This covers partial and full withdrawals; checks if under-collateralization occurs before withdrawal
    ///@param collateralAmount Amount of collateral asset to withdraw
    function withdraw(uint collateralAmount) external {       
        uint newDeposit = deposits[msg.sender] - collateralAmount;
        require(_isCollateralized(debts[msg.sender], newDeposit),"Would become undercollateralized");

        deposits[msg.sender] = newDeposit;
        bool sent = collateral.transfer(msg.sender, collateralAmount);
        require(sent, "Withdraw failed!");
        emit Withdraw(msg.sender, collateralAmount);            
    }


    /*////////////////////////////////////////////////////////////////////////*/
    /*                           COLLATERALIZATION                            */  
    /*////////////////////////////////////////////////////////////////////////*/
  
    ///@notice Check if the supplied amount of collateral can support the debt amount, given current market prices
    ///@dev Checks conditionals in return statement sequentially; first if debt is 0, otherwise, check that debt amount can be supported with given collateral
    ///@param debtAmount Amount of debt 
    ///@param collateralAmount Amount of collateral  
    ///@return collateralized True is debt can be supported
    function _isCollateralized(uint debtAmount, uint collateralAmount) internal view returns(bool collateralized) {
        return debtAmount == 0 || debtAmount <= _collateralToDebt(collateralAmount);
    }
        //Note: Conditions are evaluated sequentially.
        // First check if debtAmount ==0, if so, return TRUE. 
        // If debtAmount does not equal to 0 (FALSE), proceed to evaluate 2nd conditional
        // Second conditional checks that debtAmount is less than the max possible debt a user can take on given their deposits. 
        // If second conditional evaluates to be true, TRUE is returned.
        // Else, FALSE is returned.


    ///@notice Price is returned as an integer extending over it's decimal places
    ///@dev For a given collateral amount, calculate the debt it can support at current market prices 
    ///@param collateralAmount Amount of collateral
    ///@return debtAmount Amount of debt
    function _collateralToDebt(uint collateralAmount) internal view returns(uint debtAmount) {
        (,int price,,,) = priceFeed.latestRoundData();
        debtAmount = collateralAmount * scalarFactor / uint(price);
        debtAmount = _scaleDecimals(debtAmount, debtDecimals, collateralDecimals);
    }


    ///@dev Calculates minimum collateral required of a user to support existing debts, at current market prices 
    ///@param user Address of user 
    function minimumCollateral(address user) public view returns(uint collateralAmount) {
        collateralAmount = _debtToCollateral(debts[user]);
    }


    ///@notice Price is returned as an integer extending over it's decimal places
    ///@dev Calculates minimum collateral required to support given amount of debt, at current market prices 
    ///@param debtAmount Amount of debt
    function _debtToCollateral(uint debtAmount) internal view returns(uint collateralAmount) {
        (,int price,,,) = priceFeed.latestRoundData();
        collateralAmount = debtAmount * uint(price) / scalarFactor;
        collateralAmount = _scaleDecimals(collateralAmount, collateralDecimals, debtDecimals);
    }



    ///@notice Rebasement is necessary when utilising assets with divergering decimal precision
    ///@dev For rebasement of the trailing zeros which are representative of decimal precision
    function _scaleDecimals(uint integer, uint from, uint to) internal pure returns(uint) {
        //downscaling | 10^(to-from) => 10^(-ve) | cant have negative powers, bring down as division => integer / 10^(from - to)
        if (from > to ){ 
            return integer / 10**(from - to);
        } 
        // upscaling | (to >= from) => +ve
        else {  
            return integer * 10**(to - from);
        }
    }

    /*///////////////////////////////////////////////////////////////////////*/
    /*                               LIQUIDATIONS                            */  
    /*///////////////////////////////////////////////////////////////////////*/

    ///@dev Can only be called by Vault owner; triggers liquidation check on supplied user address
    ///@param user Address of user to trigger liquidation check
    function liquidation(address user) external onlyOwner { 
        uint userDebt = debts[user];             //saves an extra SLOAD
        uint userDeposit = deposits[user];       //saves an extra SLOAD

        require(!_isCollateralized(userDebt, userDeposit), "Not undercollateralized");

        delete deposits[user];
        delete debts[user];
        emit Liquidation(user, userDebt, userDeposit); 

    }
}
