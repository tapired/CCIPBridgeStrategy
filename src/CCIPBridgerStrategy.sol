// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Client} from "./libraries/Client.sol";
import {IPool} from "./interfaces/chainlink/IPool.sol";
import {IEVM2AnyOnRampClient} from "./interfaces/chainlink/IEVM2AnyOnRampClient.sol";
import {IRouterClient} from "./interfaces/chainlink/IRouterClient.sol";
import {CCIPReceiver} from "./CCIPReceiver.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract CCIPBridgerStrategy is BaseStrategy, CCIPReceiver {
    using SafeERC20 for ERC20;

    address public immutable destinationStrategy;
    uint64 public immutable destChainSelector; // 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D is router

    uint256 public gasLimitExtraArgs;
    IEVM2AnyOnRampClient public ccipOnRamp; // not immutable since it can be changed by the chainlink
    IPool public ccipPool; // not immutable since it can be changed by the chainlink

    uint256 public bridgedAssets;
    address public feeToken;
    bool public allowOutOfOrderExecutionExtraArgs;
    bool public open = true; // if false, no deposits or allowed
    bool public areWeAllowed; // if false, we are not allowed to deposit in CCIP pool level
    mapping(address => bool) public allowed; // if false, no deposits from the address allowed

    // tend stuff
    uint256 public maxTendBaseFee;
    uint256 public maxFeeAmount;

    constructor(
        address _asset,
        string memory _name,
        uint64 _destChainSelector,
        address _ccipRouter,
        address _destinationStrategy
    ) BaseStrategy(_asset, _name) CCIPReceiver(_ccipRouter) {
        //  set onramp address
        address onRamp = IRouterClient(_ccipRouter).getOnRamp(
            _destChainSelector
        );
        ccipOnRamp = IEVM2AnyOnRampClient(onRamp);

        //  set pool address
        ccipPool = ccipOnRamp.getPoolBySourceToken(_destChainSelector, asset);

        require(
            address(ccipPool.getToken()) == address(asset),
            "POOL_ASSET_MISMATCH"
        );

        destChainSelector = _destChainSelector;
        destinationStrategy = _destinationStrategy;
        ERC20(_asset).forceApprove(address(_ccipRouter), type(uint256).max);

        // TEST
        gasLimitExtraArgs = 2_000_000; // 2 million gas
        feeToken = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270; // wmatic
        ERC20(feeToken).forceApprove(_ccipRouter, type(uint256).max);
        maxFeeAmount = 100e18;
        maxTendBaseFee = 1e18; //its polygon 
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // dev do nothing
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // dev: do nothing
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        _totalAssets = asset.balanceOf(address(this)) + bridgedAssets;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // NOTE: Withdraw limit is only the liquid balance of the strategy
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        // if its not open then only allowed addresses can deposit
        if (!open) {
            if (!allowed[_owner]) return 0;
        }

        // address rmnProxy = ccipPool.getRmnProxy();
        // if (rmnProxy != address(0)) {
        //     // if cursed then no deposits allowed
        //     if (IRMN(rmnProxy).isCursed(bytes16(uint128(destChainSelector)))) return 0;
        // }

        // if allow list is enabled then we need to check if we are in the allow list
        // However, allow list is too long and can only be copied to memory which can be gas expensive or impossible
        // so we check if allow list is enabled if it is and we are indeed in the allow list then areWeAllowed have to be true
        bool allowListEnabled = ccipPool.getAllowListEnabled();
        if (allowListEnabled) {
            // we are not in the allow list, if we are set areWeAllowed to true
            if (!areWeAllowed) return 0;
        }

        return type(uint256).max;
    }

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     */
    function _tend(uint256 _totalIdle) internal override {
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            _totalIdle,
            true
        );
        IRouterClient(i_ccipRouter).ccipSend(destChainSelector, message);

        bridgedAssets += _totalIdle;
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view virtual override returns (bool) {
        uint256 idleBalance = asset.balanceOf(address(this));
        if (idleBalance == 0) return false;
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            idleBalance,
            true
        );
        uint256 feeAmount = IRouterClient(i_ccipRouter).getFee(
            destChainSelector,
            message
        );

        if (feeAmount < maxFeeAmount && block.basefee < maxTendBaseFee)
            return true;
        return false;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // ideally never to be used. We can always initiate a withdraw from destination strategy
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            _amount,
            false
        );
        IRouterClient(i_ccipRouter).ccipSend(destChainSelector, message);
    }

    // EMERGENCY AND MANUAL FUNCTIONS

    /// @notice manually trigger a tend with a specific amount in case of emergency
    function manualTend(uint256 _amount) external onlyKeepers {
        Client.EVM2AnyMessage memory message = _buildCCIPMessage(_amount, true);
        IRouterClient(i_ccipRouter).ccipSend(destChainSelector, message);

        bridgedAssets += _amount;
    }

    /// @dev Called in an emergency where destination strategy withdrew funds manually then bridged back to origin chain
    /// and funds are retrieved to repay the emergency withdrawal by this function
    function repayEmergencyWithdrawal(
        uint256 _amount,
        address _from
    ) external onlyManagement {
        ERC20(asset).safeTransferFrom(_from, address(this), _amount);

        if (bridgedAssets > _amount) {
            // can be losses
            bridgedAssets -= _amount;
        } else {
            // no losses
            bridgedAssets = 0;
        }
    }

    /// @dev in case fee tokens stuck in the contract
    function sweep(address _token) external onlyManagement {
        require(_token != address(asset), "SWEEP_CANNOT_BE_ASSET");
        ERC20(_token).safeTransfer(
            msg.sender,
            ERC20(_token).balanceOf(address(this))
        );
    }

    // SETTER FUNCTIONS

    /// @notice set the fee token for the ccip. Note that it can't use the same asset as the fee token because
    /// the fee token has to be idle in the strategy balance and since asset can and should be idle in the strategy
    /// it can't be used as the fee token.
    function setFeeToken(address _feeToken) external onlyKeepers {
        require(_feeToken != address(asset), "FEE_TOKEN_CANNOT_BE_ASSET");
        if (feeToken != address(0)) ERC20(feeToken).forceApprove(i_ccipRouter, 0);
        ERC20(_feeToken).forceApprove(i_ccipRouter, type(uint256).max);
        feeToken = _feeToken;
    }

    /// @notice set the extra args parameters for CCIP.
    /// @param _gasLimitExtraArgs with how much gas our destination strategy ccipReceive will be called
    /// @param _allowOutOfOrderExecutionExtraArgs if yes, then there can be two messages in fly, if no then the message has to be in order
    function setCCIPExtraArgParameters(
        uint256 _gasLimitExtraArgs,
        bool _allowOutOfOrderExecutionExtraArgs
    ) external onlyKeepers {
        gasLimitExtraArgs = _gasLimitExtraArgs;
        allowOutOfOrderExecutionExtraArgs = _allowOutOfOrderExecutionExtraArgs;
    }

    /// @notice set the open and are we allowed parameters
    /// @param _open if true, then deposits are allowed, if false then deposits are not allowed
    /// @param _areWeAllowed if true, then we can deposit if not, then not. Check the availableDepositLimit function for more details
    function setOpenAndAreWeAllowed(
        bool _open,
        bool _areWeAllowed
    ) external onlyKeepers {
        open = _open;
        areWeAllowed = _areWeAllowed;
    }

    /// @notice set the onramp and pool addresses
    /// NOTE: This function supposed to be never called. In case the addresses changes then we can call this to update the onramp and pool addresses
    /// However, it is not expected to change.
    function setOnRampAndPool() external onlyManagement {
        address onRamp = IRouterClient(i_ccipRouter).getOnRamp(
            destChainSelector
        );
        ccipOnRamp = IEVM2AnyOnRampClient(onRamp);
        ccipPool = ccipOnRamp.getPoolBySourceToken(destChainSelector, asset);
    }

    /// @notice set the tend parameters
    /// @param _maxFeeAmount the maximum fee amount that we are willing to pay for the tend
    /// @param _maxTendBaseFee the maximum base fee that we are willing to pay for the tend
    function setTendParameters(
        uint256 _maxFeeAmount,
        uint256 _maxTendBaseFee
    ) external onlyKeepers {
        maxFeeAmount = _maxFeeAmount;
        maxTendBaseFee = _maxTendBaseFee;
    }

    // CHAINLINK CCIP FUNCTIONS

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        require(
            abi.decode(message.sender, (address)) == destinationStrategy,
            "INVALID_SENDER"
        ); // this is very important!

        (
            IStrategyInterface.CallType callType,
            uint256 deltaAmount,
            bool isProfit
        ) = abi.decode(
                message.data,
                (IStrategyInterface.CallType, uint256, bool)
            );

        // if we bridged back some assets then its for withdrawals
        if (callType == IStrategyInterface.CallType.WITHDRAW) {
            // this is a withdrawal
            require(
                message.destTokenAmounts.length == 1,
                "WITHDRAW_INVALID_LENGTH"
            );
            require(
                message.destTokenAmounts[0].token == address(asset),
                "WITHDRAW_INVALID_TOKEN"
            );
            uint256 bridgedBackAmount = message.destTokenAmounts[0].amount;

            // we should have bridgedBackAmount as idle in strategy
            bridgedAssets -= bridgedBackAmount;
            return;
        }
        if (callType == IStrategyInterface.CallType.HARVEST) {
            // this is a harvest
            // no idle tokens in strategy, just reporting the destination strategy profit/loss
            if (isProfit) {
                bridgedAssets += deltaAmount;
            } else {
                bridgedAssets -= deltaAmount;
            }

            _harvestAndReport();
            return;
        }
        if (callType == IStrategyInterface.CallType.WITHDRAW_AND_HARVEST) {
            // this is a withdraw and harvest
            uint256 bridgedBackAmount = message.destTokenAmounts[0].amount;

            // first account the profit/loss
            if (isProfit) {
                bridgedAssets += deltaAmount;
            } else {
                bridgedAssets -= deltaAmount;
            }

            // then account the bridged back amount, note that this is idle in strategy
            bridgedAssets -= bridgedBackAmount;
            _harvestAndReport();
            return;
        }
    }

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _amount The amount of the token to be transferred.
    /// @param _isDeposit if true, then we are depositing, if false then we are withdrawing from destination strategy
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        uint256 _amount,
        bool _isDeposit
    ) internal view virtual returns (Client.EVM2AnyMessage memory) {
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
        evm2AnyMessage.extraArgs = Client._argsToBytes(
            Client.EVMExtraArgsV2({
                gasLimit: gasLimitExtraArgs,
                allowOutOfOrderExecution: allowOutOfOrderExecutionExtraArgs
            })
        );
        evm2AnyMessage.feeToken = feeToken;
        return evm2AnyMessage;
    }

    // HELPER
    function buildCCIPMessage(uint256 _amount, bool _isDeposit) external view returns (Client.EVM2AnyMessage memory) {
        return _buildCCIPMessage(_amount, _isDeposit);
    }

    function getFeeWithMessage(Client.EVM2AnyMessage memory m) external view returns (uint256) {
        return IRouterClient(i_ccipRouter).getFee(destChainSelector, m);
    }

    function getFeeGenerateMessage() external view returns (uint256) {
        uint256 amount = asset.balanceOf(address(this));
        Client.EVM2AnyMessage memory m = _buildCCIPMessage(amount, true);

       return IRouterClient(i_ccipRouter).getFee(destChainSelector, m);
    }
}
