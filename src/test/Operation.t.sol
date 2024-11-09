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
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_single_deposit() public {
        uint256 _amount = 1_000e6;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        console2.log(
            "available deposti limit",
            strategy.availableDepositLimit(user)
        );

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

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

    function _build_any2evm_message(uint256 _amount, address _token, address _strategy) internal returns (Client.Any2EVMMessage memory) {
        message_id = keccak256(abi.encodePacked(message_id, message_id));
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        return Client.Any2EVMMessage({
            messageId: message_id,
            sourceChainSelector: ethereumChainSelector,
            sender: abi.encode(_strategy),
            data: abi.encode(_amount),
            destTokenAmounts: tokenAmounts
        });
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // first to a tend
        uint256 feeAmount = strategy.getFeeGenerateMessage();
        address feeToken = strategy.feeToken();
        tendWithKeeper(feeToken, keeper, feeAmount, strategy);

        vm.selectFork(arbFork);
        Client.Any2EVMMessage memory message = _build_any2evm_message(_amount, address(asset), address(strategy));
        vm.prank(arbOfframpForPolygon);
        IRouterClient(ccipArbRouter).routeMessage(message, 0, 2_000_000, address(destinationStrategyArbitrum));
        // assertEq(ERC20(arbUsdc).balanceOf(address(destinationStrategyArbitrum)), _amount);

        // // Report profit
        // vm.selectFork(maticFork);
        // vm.prank(keeper);
        // (uint256 profit, uint256 loss) = strategy.report();

        // // Check return Values
        // assertGe(profit, 0, "!profit");
        // assertEq(loss, 0, "!loss");

        // skip(strategy.profitMaxUnlockTime());

        // uint256 balanceBefore = asset.balanceOf(user);

        // // Withdraw all funds
        // vm.prank(user);
        // strategy.redeem(_amount, user, user);

        // assertGe(
        //     asset.balanceOf(user),
        //     balanceBefore + _amount,
        //     "!final balance"
        // );
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

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

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

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        strategy.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tend() public {
        uint256 _amount = 1000e6;
        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        Client.EVM2AnyMessage memory m = strategy.buildCCIPMessage(_amount, true);
        uint256 fee = strategy.getFeeGenerateMessage();
        address feeToken = strategy.feeToken();

        deal(feeToken, keeper, fee);
        console2.log("Fee", fee);

        vm.prank(keeper);
        ERC20(feeToken).transfer(address(strategy), fee);
        vm.prank(keeper);
        strategy.tend();
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
