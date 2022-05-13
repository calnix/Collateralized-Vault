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
    ///@param collateralAsset The address of the collateral asset
    ///@param user The address of the user calling deposit()
    ///@param collateralAmount The amount of collateral asset deposited
    event Deposit(address indexed collateralAsset, address indexed user, uint collateralAmount);  

    ///@dev Emitted on borrow()
    ///@param debtAsset The address of the debt asset
    ///@param user The address of the user calling borrow()
    ///@param debtAmount The amount of debt asset borrowed
    event Borrow(address indexed debtAsset, address indexed user, uint debtAmount); 

    ///@dev Emitted on repay()
    ///@param debtAsset The address of the debt asset
    ///@param user The address of the user calling repay()
    ///@param debtAmount The amount of debt asset being repaid
    event Repay(address indexed debtAsset, address indexed user, uint debtAmount);

    ///@dev Emitted on withdraw()
    ///@param collateralAsset The address of the debt asset
    ///@param user The address of the user calling withdraw()
    ///@param collateralAmount The amount of collateral asset withdrawn
    event Withdraw(address indexed collateralAsset, address indexed user, uint collateralAmount);  

    ///@dev Emitted on liquidation()
    ///@param collateralAsset The address of the debt asset
    ///@param debtAsset The address of the debt asset
    ///@param user The address of the user calling withdraw()
    ///@param debtToCover The amount of debt the liquidator wants to cover
    ///@param liquidatedCollateralAmount The amount of collateral received by the liquidator
    event Liquidation(address indexed collateralAsset, address indexed debtAsset, address indexed user, uint debtToCover, uint liquidatedCollateralAmount);
    
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

    ///@dev Users deposit collateral asset into Vault
    ///@param collateralAmount Amount of collateral to deposit
    function deposit(uint collateralAmount) external {       
        deposits[msg.sender] += collateralAmount;
        bool sent = collateral.transferFrom(msg.sender, address(this), collateralAmount);
        require(sent, "Deposit failed!");  
        emit Deposit(address(collateral), msg.sender, collateralAmount);
    }
    
    ///@notice Users borrow debt asset calculated based on collateralization level and their deposits 
    ///@dev See getMaxDebt() for colleteralization calculation
    ///@param debtAmount Amount of debt asset to borrow
    function borrow(uint debtAmount) external {      
        uint collateralRequired = getCollateralRequired(debtAmount);
        uint availableCollateral = deposits[msg.sender] - getCollateralRequired(debts[msg.sender]);
        require(collateralRequired <= availableCollateral, "Insufficient collateral!");

        debts[msg.sender] += debtAmount;
        bool sent = debt.transfer(msg.sender, debtAmount);
        require(sent, "Borrow failed!");       
        emit Borrow(address(debt), msg.sender, debtAmount);
    }

    ///@notice Users repay their debt, in debt asset terms
    ///@dev This covers partial and full repayment
    ///@param debtAmount Amount of debt asset to repay
    function repay(uint debtAmount) external {
        debts[msg.sender] -= debtAmount;

        bool sent = debt.transferFrom(msg.sender, address(this), debtAmount);
        require(sent, "Repayment failed!");       
        emit Repay(address(debt), msg.sender, debtAmount);   
    }


    ///@notice Users withdraw their deposited collateral
    ///@dev This covers partial and full withdrawal; checks for spare capacity before initiating withdrawal
    ///@param collateralAmount Amount of collateral asset to withdraw
    function withdraw(uint collateralAmount) external {       
        uint userDebt = debts[msg.sender];                          // caching this saves an SLOAD
        uint userDeposit = deposits[msg.sender];                   // caching this saves an SLOAD

        if (userDebt > 0){
            uint collateralRequired = getCollateralRequired(userDebt);
            uint spareDeposit = userDeposit - collateralRequired;
            require(collateralAmount < spareDeposit, "Collateral unavailable!");
        }
        
        deposits[msg.sender] -= collateralAmount;
        bool sent = collateral.transfer(msg.sender, collateralAmount);
        require(sent, "Withdraw failed!");
        emit Withdraw(address(collateral), msg.sender, collateralAmount);            
    }

    ///@notice Price is returned as an integer extending over its decimal places
    ///@dev Calculates collateral required to support a debt position, at current market prices 
    ///@param debtAmount Amount of debt 
    function getCollateralRequired(uint debtAmount) public view returns(uint) {
        (,int price,,,) = priceFeed.latestRoundData();
        uint collateralRequired = debtAmount * uint(price) / scalarFactor;
        return collateralRequired = scaleDecimals(collateralRequired, collateralDecimals, debtDecimals);
    }

    ///@dev Can only be called by Vault owner; triggers liquidation check on supplied user address
    ///@param user Address of user to trigger liquidation check
    function liquidation(address user) public onlyOwner { 
        uint collateralRequired = getCollateralRequired(debts[user]);

        if (collateralRequired > deposits[user]){
            emit Liquidation(address(collateral), address(debt), user, debts[user], deposits[user]); 
            delete deposits[user];
            delete debts[user];
        }
    }

   
    ///@notice Rebasement is necessary when utilising assets with divergering decimal precision
    ///@dev For rebasement of the trailing zeros which are representative of decimal precision
    function scaleDecimals(uint integer, uint from, uint to) public pure returns(uint) {
        //downscaling | (to-from) => (-ve)
        if (from > to ){ 
            return integer * 10**(to - from);
        } 
        // upscaling | (to >= from) => +ve
        else {  
            return integer * 10**(to - from);
        }
    }

    ///@notice Calculates the maximum possible debt a user can take on at current market prices
    ///@param user_ Address of user to calculate max debt for 
    function getMaxDebt(address user_) external view returns(uint maxDebt) {
        (,int price,,,) = priceFeed.latestRoundData();
        uint availableCollateral = deposits[user_] - getCollateralRequired(debts[user_]);
        maxDebt = (availableCollateral * scalarFactor) / uint(price);
        maxDebt = scaleDecimals(maxDebt, debtDecimals, collateralDecimals);
    }

}
