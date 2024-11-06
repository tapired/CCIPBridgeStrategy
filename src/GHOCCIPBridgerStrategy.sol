// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {CCIPBridgerStrategy} from "./CCIPBridgerStrategy.sol";
import {IRMN} from "./interfaces/chainlink/IRMN.sol";
import {IPool} from "./interfaces/chainlink/IPool.sol";

contract GHOCCIPBridgerStrategy is CCIPBridgerStrategy {
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
        address rmnProxy = ccipPool.getRmnProxy();
        if (rmnProxy != address(0)) {
            // if cursed then no deposits allowed
            if (IRMN(rmnProxy).isCursed(bytes16(uint128(destChainSelector))))
                return false;
        }

        // NOTE: This part of the code is only specific for GHO token since AAVE
        // has a different CCIP Pool implementation.
        uint256 idleBalance = asset.balanceOf(address(this));
        uint256 bridgedAmount = ccipPool.getCurrentBridgedAmount();
        uint256 bridgeLimit = ccipPool.getBridgeLimit();

        if (bridgedAmount + idleBalance > bridgeLimit) return false;
        return super._tendTrigger();
    }

    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        uint256 superLimit = super.availableDepositLimit(_owner);
        if (superLimit == 0) return 0; // can only return 0 so this is safe

        address rmnProxy = ccipPool.getRmnProxy();
        if (rmnProxy != address(0)) {
            // if cursed then no deposits allowed
            if (IRMN(rmnProxy).isCursed(bytes16(uint128(destChainSelector))))
                return 0;
        }

        // NOTE: This part of the code is only specific for GHO token since AAVE
        // has a different CCIP Pool implementation.
        uint256 bridgedAmount = ccipPool.getCurrentBridgedAmount();
        uint256 bridgeLimit = ccipPool.getBridgeLimit();

        if (bridgeLimit > bridgedAmount) {
            return bridgeLimit - bridgedAmount;
        }
        return 0;
    }
}
