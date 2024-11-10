// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {Client} from "../libraries/Client.sol";

interface IStrategyInterface is IStrategy {
    //TODO: Add your specific implementation interface in here.

    enum CallType {
        NONE,
        WITHDRAW,
        HARVEST,
        WITHDRAW_AND_HARVEST
    }

    // Public Storage Variables
    function destinationStrategy() external view returns (address);
    function destChainSelector() external view returns (uint64);
    function gasLimitExtraArgs() external view returns (uint256);
    function ccipOnRamp() external view returns (address);
    function ccipPool() external view returns (address);
    function bridgedAssets() external view returns (uint256);
    function feeToken() external view returns (address);
    function allowOutOfOrderExecutionExtraArgs() external view returns (bool);
    function open() external view returns (bool);
    function areWeAllowed() external view returns (bool);
    function allowed(address) external view returns (bool);
    function manualTend(uint256 _amount) external;
    function repayEmergencyWithdrawal(
        uint256 _amount,
        bool _reportAswell
    ) external;
    function sweep(address _token) external;
    function setFeeToken(address _feeToken) external;
    function setCCIPExtraArgParameters(
        uint256 _gasLimitExtraArgs,
        bool _allowOutOfOrderExecutionExtraArgs
    ) external;
    function setOpenAndAreWeAllowed(bool _open, bool _areWeAllowed) external;
    function setOnRampAndPool() external;

    function buildCCIPMessage(
        uint256 _amount,
        bool _isDeposit
    ) external view returns (Client.EVM2AnyMessage memory);

    function getFeeWithMessage(
        Client.EVM2AnyMessage memory m
    ) external view returns (uint256);

    function getFeeGenerateMessage() external view returns (uint256);
    function setThisKeeper(address _thisKeeper) external;
    function reportFromOriginChain() external;
}
