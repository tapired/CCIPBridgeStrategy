// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {CCIPBridgerStrategy, ERC20} from "../../CCIPBridgerStrategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {Client} from "../../libraries/Client.sol";
import {IRouterClient} from "../../interfaces/chainlink/IRouterClient.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

//////////////////////////////// MY THINGS ////////////////////////////////
import {GHOCCIPBridgerStrategy} from "../../GHOCCIPBridgerStrategy.sol";
import {DestinationStrategyV1} from "../../DestinationStrategyV1.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;

    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1_000_000e6;
    uint256 public minFuzzAmount = 1e6;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    ////////////////////////////////
    //// SETUP VARIABLES ///////////
    ////////////////////////////////
    DestinationStrategyV1 public destinationStrategy;
    uint64 private arbitrumChainSelector = 4949039107694359620;
    uint64 private polygonChainSelector = 4051577828743386545;
    address private ccipRouterOrigin =
        0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe;
    address private ccipRouterDestination =
        0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
    address private yieldStrategy = 0x6FAF8b7fFeE3306EfcFc2BA9Fec912b4d49834C1; // usdc yvault ARBITRUM
    address private arbOfframpForPolygon =
        0x9bDA7c8DCda4E39aFeB483cc0B7E3C1f6E0D5AB1;
    address private polygonOfframpForArbitrum =
        0x60f2788225CeE4a94f8E7589931d5A14Cbc4367d;
    address private polygonWeth = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
    address private arbUsdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private arbWeth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /////// SET THESE ///////
    address public destinationAsset = arbUsdc;
    address public destinationOfframp = arbOfframpForPolygon;
    address public originOfframp = polygonOfframpForArbitrum;
    address public destinationFeeToken = arbWeth;
    address public originFeeToken = polygonWeth;
    uint64 public originChainSelector = polygonChainSelector;
    uint64 public destinationChainSelector = arbitrumChainSelector;
    /////////////////////////

    // FOUNDRY STUFF //
    uint256 public maticFork;
    uint256 public arbFork;
    string public MATIC_RPC_URL = vm.envString("MATIC_RPC_URL");
    string public ARBI_RPC_URL = vm.envString("ARBI_RPC_URL");

    // DUMMY
    bytes32 public message_id = keccak256("message_id");

    function setUp() public virtual {
        maticFork = vm.createFork(MATIC_RPC_URL);
        arbFork = vm.createFork(ARBI_RPC_URL);

        vm.selectFork(maticFork);

        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["USDC"]);

        // Set decimals
        decimals = asset.decimals();

        strategyFactory = new StrategyFactory(
            management,
            performanceFeeRecipient,
            keeper,
            emergencyAdmin
        );

        vm.selectFork(arbFork);
        destinationStrategy = _deployDestinationStrategy();

        // Deploy strategy and set variables
        vm.selectFork(maticFork);
        strategy = IStrategyInterface(setUpStrategy());

        vm.selectFork(arbFork);
        vm.startPrank(management);
        destinationStrategy.setOriginStrategy(address(strategy));
        destinationStrategy.setFeeToken(destinationFeeToken);
        destinationStrategy.setKeeper(keeper, true);
        vm.stopPrank();

        vm.selectFork(maticFork);
        _validateStrategyDeploymentAddresses(strategy);

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function _deployDestinationStrategy()
        internal
        returns (DestinationStrategyV1 s)
    {
        return
            new DestinationStrategyV1(
                ccipRouterDestination,
                yieldStrategy,
                destinationAsset,
                originChainSelector,
                management
            );
    }

    function _validateStrategyDeploymentAddresses(
        IStrategyInterface _strategy
    ) internal view {
        require(address(_strategy.ccipOnRamp()) != address(0), "!ON_RAMP");
        require(address(_strategy.ccipPool()) != address(0), "!POOL");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    address(asset),
                    "Tokenized Strategy",
                    destinationChainSelector,
                    ccipRouterOrigin,
                    address(destinationStrategy)
                )
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        vm.prank(management);
        _strategy.setFeeToken(originFeeToken);

        vm.prank(management);
        _strategy.setThisKeeper(keeper);

        return address(_strategy);
    }

    function _build_any2evm_message_from_origin(
        uint256 _amount,
        address _token,
        address _strategy
    ) internal returns (Client.Any2EVMMessage memory) {
        message_id = keccak256(abi.encodePacked(message_id, message_id));
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        return
            Client.Any2EVMMessage({
                messageId: message_id,
                sourceChainSelector: originChainSelector,
                sender: abi.encode(_strategy),
                data: abi.encode(_amount),
                destTokenAmounts: tokenAmounts
            });
    }

    function _build_any2evm_message_from_destination(
        uint256 _withdrawnAmount,
        uint256 _deltaAmount,
        bool _isProfit,
        IStrategyInterface.CallType _callType
    ) internal returns (Client.Any2EVMMessage memory) {
        message_id = keccak256(abi.encodePacked(message_id, message_id));
        uint l;
        if (_withdrawnAmount > 0) {
            l = 1;
        }

        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](l);

        if (_withdrawnAmount > 0) {
            Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
                token: address(asset),
                amount: _withdrawnAmount
            });
            tokenAmounts[0] = tokenAmount;
        }
        return
            Client.Any2EVMMessage({
                messageId: message_id,
                sourceChainSelector: destinationChainSelector,
                sender: abi.encode(address(destinationStrategy)),
                data: abi.encode(_callType, _deltaAmount, _isProfit),
                destTokenAmounts: tokenAmounts
            });
    }

    function forwardTendMessageFromOrigin(uint256 _amount) internal {
        Client.Any2EVMMessage
            memory message = _build_any2evm_message_from_origin(
                _amount,
                destinationAsset,
                address(strategy)
            );
        deal(destinationAsset, address(destinationStrategy), _amount); // airdrop
        vm.prank(destinationOfframp);
        // if the message succeeds I think its fair enough to think that the funds are also transferred
        (bool s, , ) = IRouterClient(ccipRouterDestination).routeMessage(
            message,
            0,
            2_000_000,
            address(destinationStrategy)
        );
        require(s, "!message failed");
    }

    function forwardHarvestAndWithdrawMessageFromDestination(
        uint256 _withdrawnAmount,
        uint256 _deltaAmount,
        bool _isProfit,
        IStrategyInterface.CallType _callType
    ) internal {
        Client.Any2EVMMessage
            memory message = _build_any2evm_message_from_destination(
                _withdrawnAmount,
                _deltaAmount,
                _isProfit,
                _callType
            );
        deal(address(asset), address(strategy), _withdrawnAmount); // airdrop
        vm.prank(originOfframp);
        // if the message succeeds I think its fair enough to think that the funds are also transferred
        (bool s, , ) = IRouterClient(ccipRouterOrigin).routeMessage(
            message,
            0,
            2_000_000,
            address(strategy)
        );
        require(s, "!message failed");
    }

    function tendWithKeeper(
        address _feeToken,
        address _keeper,
        uint256 _feeAmount,
        IStrategyInterface _strategy
    ) public {
        deal(_feeToken, _keeper, _feeAmount);

        vm.prank(_keeper);
        ERC20(_feeToken).transfer(address(strategy), _feeAmount);
        vm.prank(_keeper);
        _strategy.tend();
    }

    function harvestDestinationStrategy(
        address _feeToken,
        address _keeper,
        uint256 _feeAmount,
        DestinationStrategyV1 _strategy
    ) public {
        deal(_feeToken, _keeper, _feeAmount);

        vm.prank(_keeper);
        ERC20(_feeToken).transfer(address(_strategy), _feeAmount);
        vm.prank(_keeper);
        _strategy.harvest();
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(
            address(_strategy)
        );
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        // tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        // tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        // tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        // tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        // tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        // tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    }
}
