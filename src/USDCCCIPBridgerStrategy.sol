// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {CCIPBridgerStrategy} from "./CCIPBridgerStrategy.sol";
import {IPool} from "./interfaces/chainlink/IPool.sol";

contract USDCCCIPBridgerStrategy is CCIPBridgerStrategy {
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

    function _tendTrigger() internal view override returns (bool) {
        IPool.Domain memory domain = ccipPool.getDomain(destChainSelector);
        if (!domain.enabled) return false;

        return super._tendTrigger();
    }

    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        // USDC ccip pool in Ethereum uses outdated version of the CCIP Pool
        uint256 superLimit = super.availableDepositLimit(_owner);
        if (superLimit == 0) return 0; // can only return 0 so this is safe

        // if the domain is not enabled then no deposits are allowed
        IPool.Domain memory domain = ccipPool.getDomain(destChainSelector);
        if (!domain.enabled) return 0;

        return type(uint256).max;
    }
}
