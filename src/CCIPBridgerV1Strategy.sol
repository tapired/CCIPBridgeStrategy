// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {CCIPBridgerStrategy} from "./CCIPBridgerStrategy.sol";
import {IPool} from "./interfaces/chainlink/IPool.sol";
import {Client} from "./libraries/Client.sol";

contract CCIPBridgerV1Strategy is CCIPBridgerStrategy {

    constructor(
        address _asset,
        string memory _name,
        uint64 _destChainSelector,
        address _ccipRouter,
        address _destinationStrategy
    )
        CCIPBridgerStrategy(
            _asset,
            _name,
            _destChainSelector,
            _ccipRouter,
            _destinationStrategy
        )
    {}

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _amount The amount of the token to be transferred.
    /// @param _isDeposit if true, then we are depositing, if false then we are withdrawing from destination strategy
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        uint256 _amount,
        bool _isDeposit
    ) internal view override returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVM2AnyMessage memory evm2AnyMessage;
        if (_isDeposit) {
            Client.EVMTokenAmount[]
                memory tokenAmounts = new Client.EVMTokenAmount[](1);
            Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
                token: address(asset),
                amount: _amount
            });
            tokenAmounts[0] = tokenAmount;
            evm2AnyMessage.tokenAmounts = tokenAmounts;
        }

        evm2AnyMessage.receiver = abi.encode(destinationStrategy);
        evm2AnyMessage.data = abi.encode(_amount); // when deposit destination will ignore this, when withdraw it will be used
        // @dev: this is the different part!
        evm2AnyMessage.extraArgs = Client._argsToBytes(
            Client.EVMExtraArgsV1({
                gasLimit: gasLimitExtraArgs
            })
        );
        evm2AnyMessage.feeToken = feeToken;
        return evm2AnyMessage;
    }
}