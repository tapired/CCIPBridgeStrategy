pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPool {
    function getCurrentBridgedAmount() external view returns (uint256);
    function getBridgeLimit() external view returns (uint256);
    function getRmnProxy() external view returns (address rmnProxy);
    function getToken() external view returns (IERC20 token);
    function getRouter() external view returns (address router);
    function getAllowListEnabled() external view returns (bool);
    function getAllowList() external view returns (address[] memory allowList);

    // for USDC
    struct Domain {
        bytes32 allowedCaller; //      Address allowed to mint on the domain
        uint32 domainIdentifier; // ─╮ Unique domain ID
        bool enabled; // ────────────╯ Whether the domain is enabled
    }

    function getDomain(
        uint64 chainSelector
    ) external view returns (Domain memory);
}
