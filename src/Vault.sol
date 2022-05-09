// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "lib/yield-utils-v2/contracts/token/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract Vault is Ownable {

    ///@dev Vault records collateral deposits of each user
    mapping (address => uint) public deposits; 

    ///@dev Vault records debt holdings of each user
    mapping (address => uint) public debts;  


    ///@notice ERC20 interface specifying token contract functions
    ///@dev For constant variables, the value has to be fixed at compile-time, while for immutable, it can still be assigned at construction time.
    IERC20 public immutable collateral;    
    IERC20 public immutable debt;  

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
    
    ///@dev To set collateralization level of debt engine
    ///@notice To allow for margin call at defined level, preventing Vault from bearing risk in fast moving markets
    uint public immutable bufferDenominator; 
    uint public immutable bufferNumerator;

    ///@dev Returns decimal places of asset prices as dictated by Chainlink Oracle
    uint public immutable decimals;
    
    constructor(address dai_, address weth_, address priceFeedAddress, uint bufferNumerator_, uint bufferDenominator_) {
        collateral = IERC20(weth_);
        debt = IERC20(dai_);

        priceFeed = AggregatorV3Interface(priceFeedAddress);
        decimals = priceFeed.decimals();

        // collateralization level
        bufferNumerator = bufferNumerator_;
        bufferDenominator = bufferDenominator_;
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
    ///@dev See getMaxDebt() for margined colleteralization colculation
    ///@param debtAmount Amount of debt asset to borrow
    function borrow(uint debtAmount) external {             
        uint maxDebt = getMaxDebt(msg.sender);
        require(debtAmount <= maxDebt, "Insufficient collateral!");

        debts[msg.sender] += debtAmount;
        bool sent = debt.transfer(msg.sender, debtAmount);
        require(sent, "Borrow failed!");       
        emit Borrow(address(debt), msg.sender, debtAmount);
    }

    ///@notice Get maximum debt asset borrowable, calculated based on collateralization level
    ///@dev Collateralization level: bufferNumerator/bufferDenominator (e.g. 8/10 -> 80%) | Think of this as margining
    ///@param user User address to calculate maximum debt possible based on collateralization level
    function getMaxDebt(address user) public view returns(uint) {
        uint availableCollateral = (deposits[user]/bufferDenominator)*bufferNumerator;
        uint maxDebt = (availableCollateral*10**decimals / get_daiETH_Price());
        return maxDebt;
    }

    ///@notice Users repay their debt; in debt asset terms
    ///@dev This covers partial and full repayment scenarioes
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
        
        if (debts[msg.sender] > 0){
            uint collateralRequired = getCollateralRequired(debts[msg.sender]);
            uint spareDeposit = deposits[msg.sender] - collateralRequired;
            require(collateralAmount < spareDeposit, "Collateral unavailable!");
        }
        
        deposits[msg.sender] -= collateralAmount;
        bool sent = collateral.transfer(msg.sender, collateralAmount);
        require(sent, "Withdraw failed!");
        emit Withdraw(address(collateral), msg.sender, collateralAmount);            
    }


    ///@dev Calculates collateral required to support existing debt position at current market prices 
    ///@param debtAmount Amount of debt asset to support
    function getCollateralRequired(uint debtAmount) public view returns(uint) {
        uint baseCollateralRequired = debtAmount*get_daiETH_Price() / (10**decimals);
        uint bufferCollateralRequired = (baseCollateralRequired/bufferNumerator)*bufferDenominator;
        return bufferCollateralRequired;
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

    ///@notice Price is returned as integer extending over its decimal places
    ///@dev Get current market price of Collateral/Debt asset from Chainlink
    function get_daiETH_Price() public view returns(uint) {
        (,int price,,,) = priceFeed.latestRoundData();
        return uint(price);
    }
    

}
