// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {CCIPReceiver} from "./CCIPReceiver.sol";
import {Client} from "./libraries/Client.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {IRouterClient} from "./interfaces/chainlink/IRouterClient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract DestinationStrategy is CCIPReceiver {
    using SafeERC20 for ERC20;

    address public immutable asset;
    uint64 public immutable destChainSelector;
    address public immutable yieldStrategy; // ERC4626 yield strategy to earn yield from

    uint256 public bridgedAssets;
    mapping(address => bool) public keepers;
    uint256 public gasLimitExtraArgs;
    bool public allowOutOfOrderExecutionExtraArgs;
    address public feeToken;
    address public owner;
    address public originStrategy;
    uint256 public maxLossForEmergencyWithdraw;

    modifier onlyKeepers() {
        require(keepers[msg.sender], "NOT_KEEPER");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(
        address _router,
        address _yieldStrategy,
        address _asset,
        uint64 _destChainSelector,
        address _owner
    ) CCIPReceiver(_router) {
        yieldStrategy = _yieldStrategy;
        asset = _asset;
        destChainSelector = _destChainSelector;
        owner = _owner;

        ERC20(_asset).forceApprove(_yieldStrategy, type(uint256).max);
        ERC20(_asset).forceApprove(_router, type(uint256).max);

        // default for arbitrum. Remove in prod
        gasLimitExtraArgs = 2_000_000; // 2 million gas
        feeToken = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        allowOutOfOrderExecutionExtraArgs = true;
    }

    function setOriginStrategy(address _originStrategy) external onlyOwner {
        require(originStrategy == address(0), "ALREADY_SET");
        originStrategy = _originStrategy;
    }

    function getTotalAssets() public view returns (uint256) {
        return
            IStrategyInterface(yieldStrategy).convertToAssets(
                ERC20(yieldStrategy).balanceOf(address(this))
            ) + ERC20(asset).balanceOf(address(this));
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        require(
            abi.decode(message.sender, (address)) == originStrategy,
            "INVALID_SENDER"
        ); // only the origin strategy can send messages to this contract

        if (message.destTokenAmounts.length == 1) {
            // this is a deposit, tokens arrived to this contract
            uint256 receivedAmount = message.destTokenAmounts[0].amount;
            // we could use availableDepositLimit too but we definitely dont want reverts here so try catch better
            try
                IStrategyInterface(yieldStrategy).deposit(
                    receivedAmount,
                    address(this)
                )
            {} catch {
                // if deposit fails then we just keep the amount in the contract
            }

            // increase the bridgeAssets regardless of try catch
            bridgedAssets += receivedAmount;
            return; // exit early
        }

        if (message.destTokenAmounts.length == 0) {
            // this is very rare to be called. Only called when we really want to trigger a withdraw from the origin strategy
            uint256 sendAmount = abi.decode(message.data, (uint256));

            IStrategyInterface _yieldStrategy = IStrategyInterface(
                yieldStrategy
            );

            uint256 shares = _yieldStrategy.convertToShares(sendAmount);
            shares = Math.min(shares, _yieldStrategy.balanceOf(address(this))); // just to make sure

            // we could use availableWithdrawalLimit too but we definitely dont want reverts here so try catch better
            // NOTE: We don't decrease the bridgeAssets since we are not sending back the assets to the origin strategy
            try
                _yieldStrategy.redeem(
                    shares,
                    address(this),
                    address(this),
                    maxLossForEmergencyWithdraw
                )
            {} catch {}
        }
    }

    function withdraw(uint256 _amount, uint256 _maxLoss) external onlyKeepers {
        uint256 idleBalance = ERC20(asset).balanceOf(address(this));
        Client.EVM2AnyMessage memory ccipMessage;
        if (idleBalance > _amount) {
            // there can be idle assets if the deposit failed from the origin strategy
            bridgedAssets -= _amount;
            ccipMessage = _buildCCIPMessage(
                IStrategyInterface.CallType.WITHDRAW,
                _amount,
                0,
                false
            );
            IRouterClient(i_ccipRouter).ccipSend(
                destChainSelector,
                ccipMessage
            );
            return; // exit we are done
        }
        // adjust the amount to withdraw since there are idle assets
        _amount = _amount - idleBalance;

        IStrategyInterface _yieldStrategy = IStrategyInterface(yieldStrategy);

        uint256 shares = _yieldStrategy.convertToShares(_amount);
        shares = Math.min(shares, _yieldStrategy.balanceOf(address(this))); // just to make sure
        uint256 actualWithdrawn = _yieldStrategy.redeem(
            shares,
            address(this),
            address(this),
            _maxLoss
        );

        // dont care about the loss we asssume if losses there then harvest should be called
        // NOTE: We are sending back the assets to the origin strategy so we decrease the bridgedAssets
        bridgedAssets -= actualWithdrawn;

        // build the CCIP message only the withdrawn amount is cared about
        ccipMessage = _buildCCIPMessage(
            IStrategyInterface.CallType.WITHDRAW,
            actualWithdrawn,
            0,
            false
        );

        // send the message
        IRouterClient(i_ccipRouter).ccipSend(destChainSelector, ccipMessage);
    }

    /// @dev Just harvests and reports to origin strategy
    function harvest() external onlyKeepers {
        (uint256 deltaAmount, bool isProfit) = _calculateDeltaAmount();
        Client.EVM2AnyMessage memory ccipMessage = _buildCCIPMessage(
            IStrategyInterface.CallType.HARVEST,
            0,
            deltaAmount,
            isProfit
        );
        IRouterClient(i_ccipRouter).ccipSend(destChainSelector, ccipMessage);

        // NOTE: We are not sending any assets back but we are realizing profits as new bridgedAssets
        // so that origin strategy can withdraw more if needed
        bridgedAssets = getTotalAssets();
    }

    /// @dev Withdraws, harvests and reports to origin strategy. Ideal for realizing losses with withdrawals
    function harvestAndWithdraw(
        uint256 _amount,
        uint256 _maxLoss
    ) external onlyKeepers {
        uint256 idleBalance = ERC20(asset).balanceOf(address(this));
        uint256 actualWithdrawn = _amount;
        if (idleBalance < _amount) {
            // there can be idle assets if the deposit failed from the origin strategy
            // adjust the amount to withdraw since there are idle assets
            _amount = _amount - idleBalance;

            IStrategyInterface _yieldStrategy = IStrategyInterface(
                yieldStrategy
            );

            uint256 shares = _yieldStrategy.convertToShares(_amount);
            shares = Math.min(shares, _yieldStrategy.balanceOf(address(this))); // just to make sure
            uint256 withdrawn = _yieldStrategy.redeem(
                shares,
                address(this),
                address(this),
                _maxLoss
            );
            actualWithdrawn = idleBalance + withdrawn;
        }

        // calculate this after the withdraw to capture the potential withdraw loss
        (uint256 deltaAmount, bool isProfit) = _calculateDeltaAmount();

        Client.EVM2AnyMessage memory ccipMessage = _buildCCIPMessage(
            IStrategyInterface.CallType.WITHDRAW_AND_HARVEST,
            actualWithdrawn,
            deltaAmount,
            isProfit
        );
        IRouterClient(i_ccipRouter).ccipSend(destChainSelector, ccipMessage);

        // NOTE: Withdrawn amount already left the contract and delta is correctly calculated so we are updating bridgedAssets
        bridgedAssets = getTotalAssets();
    }

    function _calculateDeltaAmount()
        internal
        view
        returns (uint256 deltaAmount, bool isProfit)
    {
        uint256 totalAssets = getTotalAssets();
        if (totalAssets > bridgedAssets) {
            // profit
            deltaAmount = totalAssets - bridgedAssets;
            isProfit = true;
        } else {
            // loss
            deltaAmount = bridgedAssets - totalAssets;
            isProfit = false; // for clarity
        }
    }

    // SETTER FUNCTIONS

    /// @dev set the fee token for the ccip. Note that it can't use the same asset as the fee token because
    /// the fee token has to be idle in the strategy balance and since asset can and should be idle in the strategy
    /// it can't be used as the fee token.
    function setFeeToken(address _feeToken) external onlyOwner {
        require(_feeToken != address(asset), "FEE_TOKEN_CANNOT_BE_ASSET");
        if (feeToken != address(0))
            ERC20(feeToken).forceApprove(i_ccipRouter, 0);
        ERC20(_feeToken).forceApprove(i_ccipRouter, type(uint256).max);
        feeToken = _feeToken;
    }

    /// @notice set the extra args parameters for CCIP.
    /// @param _gasLimitExtraArgs with how much gas our destination strategy ccipReceive will be called
    /// @param _allowOutOfOrderExecutionExtraArgs if yes, then there can be two messages in fly, if no then the message has to be in order
    function setCCIPExtraArgParameters(
        uint256 _gasLimitExtraArgs,
        bool _allowOutOfOrderExecutionExtraArgs
    ) external onlyOwner {
        gasLimitExtraArgs = _gasLimitExtraArgs;
        allowOutOfOrderExecutionExtraArgs = _allowOutOfOrderExecutionExtraArgs;
    }

    function setKeeper(address _account, bool _isKeeper) external onlyOwner {
        keepers[_account] = _isKeeper;
    }

    function setMaxLossForEmergencyWithdraw(
        uint256 _maxLossForEmergencyWithdraw
    ) external onlyOwner {
        maxLossForEmergencyWithdraw = _maxLossForEmergencyWithdraw;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
    }

    // CHAINLINK FUNCTIONS

    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _withdrawnAmount The amount of the token to be transferred.
    /// @param _deltaAmount Delta amount of assets to report back to the origin strategy
    /// @param _isProfit Whether the delta amount is a profit or loss
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        IStrategyInterface.CallType _callType,
        uint256 _withdrawnAmount,
        uint256 _deltaAmount,
        bool _isProfit
    ) internal view virtual returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVM2AnyMessage memory evm2AnyMessage;
        if (_withdrawnAmount > 0) {
            Client.EVMTokenAmount[]
                memory tokenAmounts = new Client.EVMTokenAmount[](1);
            Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
                token: address(asset),
                amount: _withdrawnAmount
            });
            tokenAmounts[0] = tokenAmount;
            evm2AnyMessage.tokenAmounts = tokenAmounts;
        }

        evm2AnyMessage.receiver = abi.encode(originStrategy);
        evm2AnyMessage.data = abi.encode(_callType, _deltaAmount, _isProfit);
        evm2AnyMessage.extraArgs = Client._argsToBytes(
            Client.EVMExtraArgsV2({
                gasLimit: gasLimitExtraArgs,
                allowOutOfOrderExecution: allowOutOfOrderExecutionExtraArgs
            })
        );
        evm2AnyMessage.feeToken = feeToken;
        return evm2AnyMessage;
    }

    // EMERGENCY AND MANUAL FUNCTIONS
    /// @dev Hopefully never to be used. Owner take the funds back and sends them to the origin strategy somehow.
    /// if its used, then owner has to call the repayEmergencyWithdrawal function in the origin strategy.
    function emergencyWithdraw(
        uint256 _shareAmount,
        uint256 _maxLoss
    ) external onlyOwner {
        if (_shareAmount != 0) {
            _shareAmount = Math.min(
                _shareAmount,
                ERC20(yieldStrategy).balanceOf(address(this))
            );
            IStrategyInterface(yieldStrategy).redeem(
                _shareAmount,
                address(this),
                address(this),
                _maxLoss
            );
        }

        // send the asset back to the owner
        ERC20(asset).safeTransfer(
            msg.sender,
            ERC20(asset).balanceOf(address(this))
        );
    }

    /// @dev Used when the deposit fails from the origin strategy.
    function manualDeposit(uint256 _amount) external onlyKeepers {
        // NOTE: No need to increase the bridgedAssets since it's already increased in the ccipReceive
        // if this is a donation then the next harvest will increase the bridgedAssets
        IStrategyInterface(yieldStrategy).deposit(_amount, address(this));
    }

    // Helpers
    function buildCCIPMessage(
        IStrategyInterface.CallType _callType,
        uint256 _withdrawnAmount,
        uint256 _deltaAmount,
        bool _isProfit
    ) external view returns (Client.EVM2AnyMessage memory) {
        return
            _buildCCIPMessage(
                _callType,
                _withdrawnAmount,
                _deltaAmount,
                _isProfit
            );
    }

    function getFeeWithMessage(
        Client.EVM2AnyMessage memory m
    ) external view returns (uint256) {
        return IRouterClient(i_ccipRouter).getFee(destChainSelector, m);
    }

    function getFeeGenerateMessage(
        IStrategyInterface.CallType _callType,
        uint256 _withdrawnAmount,
        uint256 _deltaAmount,
        bool _isProfit
    ) external view returns (uint256) {
        Client.EVM2AnyMessage memory m = _buildCCIPMessage(
            _callType,
            _withdrawnAmount,
            _deltaAmount,
            _isProfit
        );
        return IRouterClient(i_ccipRouter).getFee(destChainSelector, m);
    }
}
