# Objective
Collateralized Vault: contract that acts as a collateralized debt engine

For a full illustrated walkthrough, please see: https://calnix.gitbook.io/solidity-lr/yield-mentorship-2022/5-collateralized-vault

Contract allows users to deposit an asset they own (collateral), 
to **borrow a different asset**  that the Vault owns (underlying). 
Exchange rate determined by oracle;
    - if value of collateral drops in underlying terms, the user will be liquidated.

# Tokens
Collateral: WETH
Underlying: DAI

# Contract
1. Pull the contract code for both from Etherscan
2. Add a mint() function that allows you to obtain as much as you need for testing.

# Workflow
1. Users deposit WETH into Vault, 
    - (WETH frm User to Vault. Vault recirds WETH deposited.)

2. Users *borrow* DAI against their WETH
    - as long as the value DAI they borrow in WETH terms is less than the value of their WETH collateral
    - DAI_value_in_WETH < WETH Collateral
    - Vault sends DAI to the users.
    - Vault owner finances DAI to the Vault on construction.

3. Exchange rate: Chainlink Oracle [https://docs.chain.link/docs/ethereum-addresses]

4. *Users can repay debt in DAI*

5. *Withdrawal* 
    - To withdraw WETH, the users must repay the DAI they borrowed.

6. Liquidation
    - If ETH/DAI price changes such tt **debt_value** *>* **collateral_value**, 
    Vault will erase user records from the contract -> cancelling the user debt, and at the same time stopping that user from withdrawing their collateral.

(https://1733885843-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FTgomzlmn9NrxUY0OQ3cD%2Fuploads%2FfMw1V1lKmxE7suN2JUGs%2FUntitled-2022-05-08-1843.excalidraw.png?alt=media&token=13abcd1e-710c-44c2-ad9d-f804b55bd501)

# Process
## Dependencies
- forge install yieldprotocol/yield-utils-v2
    (IERC20 interface)
- forge install openZeppelin/openzeppelin-contracts  
    (Ownable.sol)
- forge install smartcontractkit/chainlink  
    (AggregatorV3 and MockV3Aggregator)

## Pull contracts from Etherscan
WETH9.sol: https://etherscan.io/address/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2#code
DAI.sol: https://etherscan.io/address/0x6b175474e89094c44da98b954eedeac495271d0f#code

## Updating contracts to v0.8.0 
#### WETH9.sol: 
1. added 'emit' to all events 
2. uint(-1) refactored to type(uint).max (line 70) 

#### DAI.sol:
-> removed inheritance of LibNote 
-> removed note modifier from function reply and deny (line 78 & 79) 
-> line 112: removed public from constructor. 
-> line 190: now deprecated. changed to block.timestamp 
-> line 192: uint(-1) changed to type(uint).max (also on 131, 147)

# Pricing + Decimal scaling
(https://1733885843-files.gitbook.io/~/files/v0/b/gitbook-x-prod.appspot.com/o/spaces%2FTgomzlmn9NrxUY0OQ3cD%2Fuploads%2Ft0KkvBkGt0SWEBZXDo52%2Fimage.png?alt=media&token=0d39a856-7e07-4b40-9c67-f4ae06e9be77)

# Testing 
### Action: deposit, borrow, repay, withdraw. liquidated
StateZero:(Vault has 10000 DAI)
+ testVaultHasDAI
+ User deposits WETH 
> - cannotWithdraw -> nothing to withdraw. no need to test.

StateDeposited: (Vault has 10000 DAI, 1 WETH) | (user deposited 1 WETH. can borrow, withdraw)
- userCannotWithdrawExcess
- userCannotBeLiquidatedWithoutDebt 
- userCannotBorrowInExcess
+ User can withdraw freely in absence of debt (fuzzing)
+ User can borrow against collateral provided

StateBorrowed: (user has borrowed half of maxDebt. actions:[borrow,repay,withdraw])
- userCannotBorrowExcessOfMargin
- userCannotWithdrawExcessOfMargin
- userCannotbeLiquidated  - price unchanged.
+ User Repays (Fuzzing)

StateLiquidation (setup price to exceed)
+ userLiquidated 
+ testOnlyOwnerCanCallLiquidate


# Deployment
Node provider: Alchemy
Target network: Ethereum-Goerli