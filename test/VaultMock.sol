// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "src/Vault.sol";

contract VaultMock is Vault {

    constructor(address dai_, address weth_, address priceFeedAddress) Vault(dai_, weth_, priceFeedAddress){

    }

    // call internal function _debtToCollateral for testing purposes
    function debtToCollateral(uint debtAmount) public view returns(uint) {
        return _debtToCollateral(debtAmount);
    }
    
    // call internal function _collateralToDebt for testing purposes
    function collateralToDebt(uint collateralAmount) public view returns(uint) {
        return _collateralToDebt(collateralAmount);
    }

    // call internal function _isCollateralized for testing purposes
    function isCollateralized(uint debtAmount, uint collateralAmount) public view returns(bool) {
        return _isCollateralized(debtAmount, collateralAmount);
    }


}