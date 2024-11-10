// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {CCIPReceiver} from "./CCIPReceiver.sol";
import {Client} from "./libraries/Client.sol";
import {DestinationStrategy} from "./DestinationStrategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract DestinationStrategyV1 is DestinationStrategy {
    constructor(
        address _router,
        address _yieldStrategy,
        address _asset,
        uint64 _destChainSelector,
        address _owner
    )
        DestinationStrategy(
            _router,
            _yieldStrategy,
            _asset,
            _destChainSelector,
            _owner
        )
    {}

    function _buildCCIPMessage(
        IStrategyInterface.CallType _callType,
        uint256 _withdrawnAmount,
        uint256 _deltaAmount,
        bool _isProfit
    ) internal view override returns (Client.EVM2AnyMessage memory) {
        Client.EVM2AnyMessage memory m = super._buildCCIPMessage(
            _callType,
            _withdrawnAmount,
            _deltaAmount,
            _isProfit
        );
        m.extraArgs = Client._argsToBytes(
            Client.EVMExtraArgsV1({gasLimit: gasLimitExtraArgs})
        );
        return m;
    }
}
