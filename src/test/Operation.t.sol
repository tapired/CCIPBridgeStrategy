// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Client} from "../libraries/Client.sol";
import {IRouterClient} from "../interfaces/chainlink/IRouterClient.sol";

contract OperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), address(strategy));
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // first to a tend
        uint256 feeAmount = strategy.getFeeGenerateMessage();
        address feeToken = strategy.feeToken();
        tendWithKeeper(feeToken, keeper, feeAmount, strategy);

        vm.selectFork(arbFork);
        uint256 limitBefore = IStrategyInterface(
            destinationStrategy.yieldStrategy()
        ).maxDeposit(address(destinationStrategy));

        forwardTendMessageFromOrigin(_amount);
        // all bridged
        assertEq(destinationStrategy.bridgedAssets(), _amount);
        // round down
        assertApproxEqRel(
            destinationStrategy.getTotalAssets(),
            _amount,
            0.00001e18
        );

        // then funds are idle
        if (limitBefore < _amount) {
            assertEq(
                ERC20(destinationAsset).balanceOf(address(destinationStrategy)),
                _amount
            );
        } else {
            // all deposited
            assertEq(
                ERC20(destinationAsset).balanceOf(address(destinationStrategy)),
                0
            );
        }
        // skip some time in destination chain
        uint256 profitAm = _amount / 100 > 0 ? _amount / 100 : 1;
        airdrop(
            ERC20(destinationAsset),
            address(destinationStrategy),
            profitAm
        );
        // must see the profit in destination strategy
        uint deltaAmount = destinationStrategy.getTotalAssets() -
            destinationStrategy.bridgedAssets();
        assertTrue(deltaAmount > 0);

        // report the harvest
        harvestDestinationStrategy(
            destinationStrategy.feeToken(),
            keeper,
            100e18,
            destinationStrategy
        );

        // Report profit
        uint256 totalAssetsOnDestination = destinationStrategy.getTotalAssets();
        vm.selectFork(maticFork);

        // withdraw all and harvest!
        forwardHarvestAndWithdrawMessageFromDestination(
            totalAssetsOnDestination,
            deltaAmount,
            true,
            IStrategyInterface.CallType.WITHDRAW_AND_HARVEST
        );
        assertEq(
            asset.balanceOf(address(strategy)),
            totalAssetsOnDestination,
            "!strategy balance"
        );

        // all withdrawn
        assertEq(strategy.bridgedAssets(), 0, "!bridgedAssets");

        skip(strategy.profitMaxUnlockTime());
        assertEq(
            strategy.totalAssets(),
            totalAssetsOnDestination,
            "!strategy total assets"
        );

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // first to a tend
        uint256 feeAmount = strategy.getFeeGenerateMessage();
        address feeToken = strategy.feeToken();
        tendWithKeeper(feeToken, keeper, feeAmount, strategy);

        vm.selectFork(arbFork);
        uint256 limitBefore = IStrategyInterface(
            destinationStrategy.yieldStrategy()
        ).maxDeposit(address(destinationStrategy));

        forwardTendMessageFromOrigin(_amount);
        // all bridged
        assertEq(destinationStrategy.bridgedAssets(), _amount);
        // round down
        assertApproxEqRel(
            destinationStrategy.getTotalAssets(),
            _amount,
            0.00001e18
        );

        // then funds are idle
        if (limitBefore < _amount) {
            assertEq(
                ERC20(destinationAsset).balanceOf(address(destinationStrategy)),
                _amount
            );
        } else {
            // all deposited
            assertEq(
                ERC20(destinationAsset).balanceOf(address(destinationStrategy)),
                0
            );
        }
        // skip some time in destination chain
        uint256 profitAm = _amount / 100 > 0 ? _amount / 100 : 1;
        airdrop(
            ERC20(destinationAsset),
            address(destinationStrategy),
            profitAm
        );
        // must see the profit in destination strategy
        uint deltaAmount = destinationStrategy.getTotalAssets() -
            destinationStrategy.bridgedAssets();
        assertTrue(deltaAmount > 0);

        harvestDestinationStrategy(
            destinationStrategy.feeToken(),
            keeper,
            100e18,
            destinationStrategy
        );

        vm.selectFork(maticFork);

        // Just harvest!
        forwardHarvestAndWithdrawMessageFromDestination(
            0,
            deltaAmount,
            true,
            IStrategyInterface.CallType.HARVEST
        );

        skip(strategy.profitMaxUnlockTime());
        assertEq(
            strategy.totalAssets(),
            _amount + deltaAmount,
            "!strategy total assets"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // first to a tend
        uint256 feeAmount = strategy.getFeeGenerateMessage();
        address feeToken = strategy.feeToken();
        tendWithKeeper(feeToken, keeper, feeAmount, strategy);

        vm.selectFork(arbFork);
        uint256 limitBefore = IStrategyInterface(
            destinationStrategy.yieldStrategy()
        ).maxDeposit(address(destinationStrategy));

        forwardTendMessageFromOrigin(_amount);
        // all bridged
        assertEq(destinationStrategy.bridgedAssets(), _amount);
        // round down
        assertApproxEqRel(
            destinationStrategy.getTotalAssets(),
            _amount,
            0.00001e18
        );

        // then funds are idle
        if (limitBefore < _amount) {
            assertEq(
                ERC20(destinationAsset).balanceOf(address(destinationStrategy)),
                _amount
            );
        } else {
            // all deposited
            assertEq(
                ERC20(destinationAsset).balanceOf(address(destinationStrategy)),
                0
            );
        }
        // skip some time in destination chain
        uint256 profitAm = _amount / 100 > 0 ? _amount / 100 : 1;
        airdrop(
            ERC20(destinationAsset),
            address(destinationStrategy),
            profitAm
        );
        // must see the profit in destination strategy
        uint deltaAmount = destinationStrategy.getTotalAssets() -
            destinationStrategy.bridgedAssets();
        assertTrue(deltaAmount > 0);

        harvestDestinationStrategy(
            destinationStrategy.feeToken(),
            keeper,
            100e18,
            destinationStrategy
        );

        vm.selectFork(maticFork);

        // Just harvest!
        forwardHarvestAndWithdrawMessageFromDestination(
            0,
            deltaAmount,
            true,
            IStrategyInterface.CallType.HARVEST
        );

        skip(strategy.profitMaxUnlockTime());
        assertEq(
            strategy.totalAssets(),
            _amount + deltaAmount,
            "!strategy total assets"
        );

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (deltaAmount * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);
    }

    function test_tend() public {
        uint256 _amount = 1000e6;
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        Client.EVM2AnyMessage memory m = strategy.buildCCIPMessage(
            _amount,
            true
        );
        uint256 fee = strategy.getFeeGenerateMessage();
        address feeToken = strategy.feeToken();

        deal(feeToken, keeper, fee);

        vm.prank(keeper);
        ERC20(feeToken).transfer(address(strategy), fee);
        vm.prank(keeper);
        strategy.tend();

        assertEq(asset.balanceOf(address(strategy)), 0, "!all_bridged");
    }

    // function test_tendTrigger(uint256 _amount) public {
    //     vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

    //     (bool trigger, ) = strategy.tendTrigger();
    //     assertTrue(!trigger);

    //     // Deposit into strategy
    //     mintAndDepositIntoStrategy(strategy, user, _amount);

    //     (trigger, ) = strategy.tendTrigger();
    //     assertTrue(trigger);

    //     // Skip some time
    //     skip(1 days);

    //     (trigger, ) = strategy.tendTrigger();
    //     assertTrue(trigger);

    //     vm.prank(keeper);
    //     strategy.report();

    //     (trigger, ) = strategy.tendTrigger();
    //     assertTrue(trigger);

    //     // Unlock Profits
    //     skip(strategy.profitMaxUnlockTime());

    //     (trigger, ) = strategy.tendTrigger();
    //     assertTrue(trigger);

    //     vm.prank(user);
    //     strategy.redeem(_amount, user, user);

    //     (trigger, ) = strategy.tendTrigger();
    //     assertTrue(!trigger);
    // }
}
