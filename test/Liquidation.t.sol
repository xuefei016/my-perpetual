// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeDealer} from "../src/MetaNodeDealer.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Liquidation} from "../src/libraries/Liquidation.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {DealerFixture} from "./utils/DealerFixture.sol";

/// @notice 测试用 Dealer：把库函数 getLiquidateCreditAmount 暴露出来（D5 的 View 会有正式的 getLiquidationCost）
contract LiquidationHarness is MetaNodeDealer {
    constructor(address primaryAsset) MetaNodeDealer(primaryAsset) {}

    function exposedGetLiquidateCreditAmount(address perp, address liquidatedTrader, int256 requestPaperAmount)
        external
        view
        returns (int256, int256, uint256)
    {
        return Liquidation.getLiquidateCreditAmount(state, perp, liquidatedTrader, requestPaperAmount);
    }
}

/// @notice D4 清算：参数沿用底座 IM 10% / MM 5% / 清算折扣 1% / 保险费率 1%
/// 场景：alice 存 5000、bob 存 5000，alice 以 30000 做多 1 BTC，bob 做空 1 BTC
contract LiquidationTest is DealerFixture {
    LiquidationHarness harness;
    address insurance = makeAddr("insurance");
    address carolBot = makeAddr("carolBot");

    function _deployDealer() internal override returns (MetaNodeDealer) {
        harness = new LiquidationHarness(address(usdc));
        return harness;
    }

    function setUp() public override {
        super.setUp();
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);
        dealer.setInsurance(insurance);
    }

    // ==================== getLiquidateCreditAmount ====================

    // ① 全部清算多头：价格 26000，alice 净值 1000 < 维持保证金 1300
    //    接手价 26000 × 0.99 = 25740，清算人付 25740，保险费 257.4
    function testCreditAmountFullLong() public {
        btcPrice.setMarkPrice(26000e6);
        (int256 paper, int256 credit, uint256 fee) = harness.exposedGetLiquidateCreditAmount(address(btc), alice, 1e18);
        assertEq(paper, 1e18);
        assertEq(credit, -25740e6);
        assertEq(fee, 257.4e6);
    }

    // ② 部分清算：只接 0.4 张
    function testCreditAmountPartial() public {
        btcPrice.setMarkPrice(26000e6);
        (int256 paper, int256 credit, uint256 fee) =
            harness.exposedGetLiquidateCreditAmount(address(btc), alice, 0.4e18);
        assertEq(paper, 0.4e18);
        assertEq(credit, -10296e6);
        assertEq(fee, 102.96e6);
    }

    // ③ 请求过量：要 2 张，只截断到 alice 实际的 1 张（否则会把 alice 清成空头）
    function testCreditAmountClampedToPosition() public {
        btcPrice.setMarkPrice(26000e6);
        (int256 paper, int256 credit, uint256 fee) = harness.exposedGetLiquidateCreditAmount(address(btc), alice, 2e18);
        assertEq(paper, 1e18);
        assertEq(credit, -25740e6);
        assertEq(fee, 257.4e6);
    }

    // ④ 空头方向：价格涨到 34000，bob 净值 1000 < 1700
    //    清算人接空头 = 卖出，要加价：34000 × 1.01 = 34340，清算人收 34340，保险费 343.4
    function testCreditAmountShort() public {
        btcPrice.setMarkPrice(34000e6);
        (int256 paper, int256 credit, uint256 fee) = harness.exposedGetLiquidateCreditAmount(address(btc), bob, -1e18);
        assertEq(paper, -1e18);
        assertEq(credit, 34340e6);
        assertEq(fee, 343.4e6);
    }

    // ⑤ 空头请求过量也要截断（截断后保持空头的符号）
    function testCreditAmountShortClamped() public {
        btcPrice.setMarkPrice(34000e6);
        (int256 paper, int256 credit,) = harness.exposedGetLiquidateCreditAmount(address(btc), bob, -3e18);
        assertEq(paper, -1e18);
        assertEq(credit, 34340e6);
    }

    // ⑤b 保险费用的是 insuranceFeeRate：把它调成 2%（折扣仍 1%），两个参数不同值才能区分用错字段
    //     保险费 = 25740 × 2% = 514.8
    function testCreditAmountUsesInsuranceFeeRate() public {
        dealer.setPerpRiskParams(
            address(btc),
            Types.RiskParams({
                initialMarginRatio: IM_RATIO,
                liquidationThreshold: MM_RATIO,
                liquidationPriceOff: 1e16,
                insuranceFeeRate: 2e16,
                markPriceSource: address(btcPrice),
                name: "BTC-USDC",
                isRegistered: true
            })
        );
        btcPrice.setMarkPrice(26000e6);
        (, int256 credit, uint256 fee) = harness.exposedGetLiquidateCreditAmount(address(btc), alice, 1e18);
        assertEq(credit, -25740e6);
        assertEq(fee, 514.8e6);
    }

    // ⑥ 还安全的人不能被清算
    function testCreditAmountRevertsWhenSafe() public {
        btcPrice.setMarkPrice(26500e6); // alice 净值 1500 >= 维持保证金 1325，仍安全
        vm.expectRevert(bytes(Errors.ACCOUNT_IS_SAFE));
        harness.exposedGetLiquidateCreditAmount(address(btc), alice, 1e18);
    }

    // ⑦ 方向反了：alice 是多头，清算人却请求 -1（会让 alice 加仓）
    function testCreditAmountRevertsWrongDirection() public {
        btcPrice.setMarkPrice(26000e6);
        vm.expectRevert(bytes(Errors.LIQUIDATION_REQUEST_AMOUNT_WRONG));
        harness.exposedGetLiquidateCreditAmount(address(btc), alice, -1e18);
    }

    // ⑧ 请求 0 张也算方向不对
    function testCreditAmountRevertsZeroRequest() public {
        btcPrice.setMarkPrice(26000e6);
        vm.expectRevert(bytes(Errors.LIQUIDATION_REQUEST_AMOUNT_WRONG));
        harness.exposedGetLiquidateCreditAmount(address(btc), alice, 0);
    }

    // ⑨ alice 因为 BTC 亏损而不安全，但在 ETH 市场没有仓位，ETH 市场没东西可清
    function testCreditAmountRevertsNoPosition() public {
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO);
        btcPrice.setMarkPrice(26000e6);
        vm.expectRevert(bytes(Errors.TRADER_HAS_NO_POSITION));
        harness.exposedGetLiquidateCreditAmount(address(eth), alice, 1e18);
    }

    // ==================== requestLiquidation（第 3 步：冒充 BTC 市场直接调 Dealer） ====================

    function _requestAsBtc(address executor, address liquidator, address liquidated, int256 paper)
        internal
        returns (int256, int256, int256, int256)
    {
        vm.prank(address(btc));
        return dealer.requestLiquidation(executor, liquidator, liquidated, paper);
    }

    // ⑩ 场景 A 的数字：四个返回值 + 保险账户 257.4 + 守恒（清算人付的 = 被清算人收的 + 保险费）
    function testRequestLiquidationAmounts() public {
        btcPrice.setMarkPrice(26000e6);
        (int256 tPaper, int256 tCredit, int256 dPaper, int256 dCredit) = _requestAsBtc(carol, carol, alice, 1e18);
        assertEq(tPaper, 1e18);
        assertEq(tCredit, -25740e6);
        assertEq(dPaper, -1e18);
        assertEq(dCredit, 25482.6e6);
        assertEq(dealer.getPrimaryCredit(insurance), 257.4e6);
        assertEq(tCredit + dCredit + dealer.getPrimaryCredit(insurance), 0);
    }

    // ⑪ 空头方向：被清算人 bob 付出 credit（-34340），再扣保险费 343.4
    function testRequestLiquidationShort() public {
        btcPrice.setMarkPrice(34000e6);
        (int256 tPaper, int256 tCredit, int256 dPaper, int256 dCredit) = _requestAsBtc(carol, carol, bob, -1e18);
        assertEq(tPaper, -1e18);
        assertEq(tCredit, 34340e6);
        assertEq(dPaper, 1e18);
        assertEq(dCredit, -34683.4e6);
        assertEq(dealer.getPrimaryCredit(insurance), 343.4e6);
    }

    // ⑫ 三个事件：数字与返回值一致，序号取各自的 positionSerialNum
    //    carol 先在 BTC 开 0.1 再平掉 → 她的序号是 1；alice 没平过仓 → 0（两人不同才能抓到"取错人"）
    function testRequestLiquidationEvents() public {
        _deposit(carol, 10000e6);
        _trade(btc, carol, bob, 0.1e18, 30000e6);
        _trade(btc, bob, carol, 0.1e18, 30000e6);

        btcPrice.setMarkPrice(26000e6);
        vm.expectEmit(true, true, false, true, address(dealer));
        emit Liquidation.BeingLiquidated(address(btc), alice, -1e18, 25482.6e6, 0);
        vm.expectEmit(true, true, true, true, address(dealer));
        emit Liquidation.JoinLiquidation(address(btc), carol, alice, 1e18, -25740e6, 1);
        vm.expectEmit(true, true, false, true, address(dealer));
        emit Liquidation.ChargeInsurance(address(btc), alice, 257.4e6);
        _requestAsBtc(carol, carol, alice, 1e18);
    }

    // ⑬ bob 想让 carol 出保证金接 alice 的烂仓位：不行
    function testRequestLiquidationRevertsForeignExecutor() public {
        btcPrice.setMarkPrice(26000e6);
        vm.prank(address(btc));
        vm.expectRevert(bytes(Errors.INVALID_LIQUIDATION_EXECUTOR));
        dealer.requestLiquidation(bob, carol, alice, 1e18);
    }

    // ⑭ carol 授权机器人后，机器人可以代 carol 清算；取消授权后又不行
    function testRequestLiquidationByOperator() public {
        btcPrice.setMarkPrice(26000e6);
        vm.prank(carol);
        dealer.setOperator(carolBot, true);
        (int256 tPaper,,,) = _requestAsBtc(carolBot, carol, alice, 0.5e18);
        assertEq(tPaper, 0.5e18);

        vm.prank(carol);
        dealer.setOperator(carolBot, false);
        vm.prank(address(btc));
        vm.expectRevert(bytes(Errors.INVALID_LIQUIDATION_EXECUTOR));
        dealer.requestLiquidation(carolBot, carol, alice, 0.5e18);
    }

    // ⑮ operatorRegistry 的键序：第一层是主人、第二层是 operator
    //    bot 授权 carol（方向反了）不能让 bot 代 carol 清算
    function testRequestLiquidationOperatorKeyOrder() public {
        btcPrice.setMarkPrice(26000e6);
        vm.prank(carolBot);
        dealer.setOperator(carol, true);
        vm.prank(address(btc));
        vm.expectRevert(bytes(Errors.INVALID_LIQUIDATION_EXECUTOR));
        dealer.requestLiquidation(carolBot, carol, alice, 1e18);
    }

    // ⑯ 自己清算自己：不行
    function testRequestLiquidationRevertsSelf() public {
        btcPrice.setMarkPrice(26000e6);
        vm.prank(address(btc));
        vm.expectRevert(bytes(Errors.SELF_LIQUIDATION_NOT_ALLOWED));
        dealer.requestLiquidation(alice, alice, alice, 1e18);
    }

    // ⑰ 只有注册过的市场能请求清算
    function testRequestLiquidationOnlyRegisteredPerp() public {
        btcPrice.setMarkPrice(26000e6);
        vm.prank(carol);
        vm.expectRevert(bytes(Errors.PERP_NOT_REGISTERED));
        dealer.requestLiquidation(carol, carol, alice, 1e18);
    }

    // ==================== Perpetual.liquidate（第 4 步：端到端，从清算人调 Perpetual 开始） ====================

    function _liquidate(address executor, address liquidator, address liquidated, int256 paper, int256 expectCredit)
        internal
        returns (int256, int256)
    {
        vm.prank(executor);
        return btc.liquidate(liquidator, liquidated, paper, expectCredit);
    }

    function _netValue(address trader) internal view returns (int256 netValue) {
        (netValue,,,) = dealer.getTraderRisk(trader);
    }

    // ⑱ 场景 A 全流程：26000 时 carol 以 25740 接手 alice 的 1 BTC
    //    alice 仓位清零、主账户 482.6；carol 持多 1、credit -25740、净值 10260；保险 257.4
    //    守恒：alice 亏 4517.4 = bob 浮盈 4000 + carol 赚 260 + 保险 257.4
    function testLiquidateScenarioA() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(26000e6);
        (int256 tPaper, int256 tCredit) = _liquidate(carol, carol, alice, 1e18, -25800e6);
        assertEq(tPaper, 1e18);
        assertEq(tCredit, -25740e6);

        (int256 aPaper, int256 aCredit) = btc.balanceOf(alice);
        assertEq(aPaper, 0);
        assertEq(aCredit, 0);
        assertEq(dealer.getPositions(alice).length, 0);
        assertEq(dealer.getPrimaryCredit(alice), 482.6e6);

        (int256 cPaper, int256 cCredit) = btc.balanceOf(carol);
        assertEq(cPaper, 1e18);
        assertEq(cCredit, -25740e6);
        assertEq(dealer.getPositions(carol).length, 1);
        assertEq(_netValue(carol), 10260e6);

        assertEq(dealer.getPrimaryCredit(insurance), 257.4e6);
        assertEq(_netValue(bob), 9000e6);
        int256 aliceLoss = 5000e6 - dealer.getPrimaryCredit(alice);
        int256 othersGain = (_netValue(bob) - 5000e6) + (_netValue(carol) - 10000e6) + dealer.getPrimaryCredit(insurance);
        assertEq(aliceLoss, othersGain);
    }

    // ⑲ 空头全流程：34000 时 carol 以 34340 接手 bob 的空 1 BTC
    //    bob credit 30000 - 34340 - 343.4 = -4683.4 → 主账户 316.6
    function testLiquidateShortScenario() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(34000e6);
        _liquidate(carol, carol, bob, -1e18, 34300e6);

        assertEq(dealer.getPositions(bob).length, 0);
        assertEq(dealer.getPrimaryCredit(bob), 316.6e6);
        (int256 cPaper, int256 cCredit) = btc.balanceOf(carol);
        assertEq(cPaper, -1e18);
        assertEq(cCredit, 34340e6);
        assertEq(dealer.getPrimaryCredit(insurance), 343.4e6);
    }

    // ⑳ 部分清算让 alice 回到安全：清 0.4 后 alice 剩 0.6
    //    净值 5000 + 0.6×26000 - (30000 - 10296 + 102.96) = 793.04 >= 维持保证金 780 → 安全，不能再清
    function testPartialLiquidationRestoresSafety() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(26000e6);
        _liquidate(carol, carol, alice, 0.4e18, -10320e6);

        (int256 aPaper, int256 aCredit) = btc.balanceOf(alice);
        assertEq(aPaper, 0.6e18);
        assertEq(aCredit, -19806.96e6);
        assertEq(dealer.getPositions(alice).length, 1);
        assertEq(_netValue(alice), 793.04e6);
        assertTrue(dealer.isSafe(alice));

        vm.prank(carol);
        vm.expectRevert(bytes(Errors.ACCOUNT_IS_SAFE));
        btc.liquidate(carol, alice, 0.6e18, -15500e6);
    }

    // ㉑ 价格保护要比"单价"：请求 2 张、预期 -51600（每张 25800），截断成 1 张 -25740
    //    -25740 × 2 >= -51600 × 1 → 通过（直接比 credit：-25740 vs -51600 没有意义）
    //     反例：请求 2 张、预期 -51000（每张最多 25500），截断成 1 张要 25740 → 单价超了，必须 revert
    //     （直接比 credit：-25740 >= -51000 会错误放行）
    function testLiquidatePriceProtectionComparesUnitPrice() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(26000e6);
        vm.prank(carol);
        vm.expectRevert("LIQUIDATION_PRICE_PROTECTION");
        btc.liquidate(carol, alice, 2e18, -51000e6);

        (int256 tPaper, int256 tCredit) = _liquidate(carol, carol, alice, 2e18, -51600e6);
        assertEq(tPaper, 1e18);
        assertEq(tCredit, -25740e6);
    }

    // ㉒ 接多头的价格保护：预期每张最多付 25700，实际要 25740 → revert；预期正好 25740 → 通过
    function testLiquidatePriceProtectionLong() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(26000e6);
        vm.prank(carol);
        vm.expectRevert("LIQUIDATION_PRICE_PROTECTION");
        btc.liquidate(carol, alice, 1e18, -25700e6);

        _liquidate(carol, carol, alice, 1e18, -25740e6);
    }

    // ㉓ 接空头的价格保护：预期每张至少收 34400，实际只给 34340 → revert；预期正好 34340 → 通过
    function testLiquidatePriceProtectionShort() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(34000e6);
        vm.prank(carol);
        vm.expectRevert("LIQUIDATION_PRICE_PROTECTION");
        btc.liquidate(carol, bob, -1e18, 34400e6);

        _liquidate(carol, carol, bob, -1e18, 34340e6);
    }

    // ㉔ 清算人必须 IM safe（D4 选 B）：carol 接完净值 = 存款 + 260，IM = 2600
    //    存 2000 → 2260 < 2600 revert（若用 MM 1300 会通过，这个测试区分 IM/MM）；存 2340 → 正好 2600 通过
    function testLiquidatorMustBeIMSafe() public {
        _deposit(carol, 2000e6);
        btcPrice.setMarkPrice(26000e6);
        vm.prank(carol);
        vm.expectRevert("LIQUIDATOR_NOT_SAFE");
        btc.liquidate(carol, alice, 1e18, -25800e6);

        _deposit(carol, 340e6);
        _liquidate(carol, carol, alice, 1e18, -25800e6);
        assertEq(_netValue(carol), 2600e6);
    }

    // ㉕ 端到端的执行人权限：bob 不能让 carol 接仓；carol 的机器人可以
    function testLiquidateExecutorIsMsgSender() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(26000e6);
        vm.prank(bob);
        vm.expectRevert(bytes(Errors.INVALID_LIQUIDATION_EXECUTOR));
        btc.liquidate(carol, alice, 1e18, -25800e6);

        vm.prank(carol);
        dealer.setOperator(carolBot, true);
        (int256 tPaper,) = _liquidate(carolBot, carol, alice, 1e18, -25800e6);
        assertEq(tPaper, 1e18);
        (int256 cPaper,) = btc.balanceOf(carol);
        assertEq(cPaper, 1e18);
        (int256 botPaper,) = btc.balanceOf(carolBot);
        assertEq(botPaper, 0);
    }

    // ==================== handleBadDebt（第 5 步：场景 B，价格跳水到 24000） ====================

    // ㉖ 场景 B：alice 净值 -1000 已穿仓；carol 以 23760 接手，保险费 237.6
    //    alice 主账户 5000 - 6477.6 = -1477.6 → 坏账转给保险：alice 归零，保险 237.6 - 1477.6 = -1240
    //    守恒：alice 亏掉的 5000 = bob 浮盈 6000 + carol 赚 240 + 保险 -1240
    function testBadDebtScenarioB() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(24000e6);
        assertEq(_netValue(alice), -1000e6);

        vm.expectEmit(true, false, false, true, address(dealer));
        emit Liquidation.HandleBadDebt(alice, -1477.6e6, 0);
        _liquidate(carol, carol, alice, 1e18, -23760e6);

        assertEq(dealer.getPrimaryCredit(alice), 0);
        assertEq(_netValue(alice), 0);
        assertEq(dealer.getPrimaryCredit(insurance), -1240e6);
        assertEq(_netValue(bob), 11000e6);
        assertEq(_netValue(carol), 10240e6);
        int256 others = (_netValue(bob) - 5000e6) + (_netValue(carol) - 10000e6) + dealer.getPrimaryCredit(insurance);
        assertEq(others, 5000e6);
    }

    // ㉗ 保险基金事先注资 2000：2000 + 237.6 - 1477.6 = 760，保险没被击穿
    function testBadDebtAbsorbedByFundedInsurance() public {
        _deposit(insurance, 2000e6);
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(24000e6);
        _liquidate(carol, carol, alice, 1e18, -23760e6);
        assertEq(dealer.getPrimaryCredit(alice), 0);
        assertEq(dealer.getPrimaryCredit(insurance), 760e6);
    }

    // ㉘ 还有别的市场的仓位就先不处理：alice 另有 1 ETH 多单
    //    清完 BTC 后 alice 主账户 -1477.6，但 ETH 仓位还在 → 不动账（保险只有 237.6）
    //    再清 ETH（1980 接手、保险费 19.8，alice 再亏 39.8）→ 仓位全清，坏账 -1517.4 一次性转给保险
    function testBadDebtWaitsUntilAllPositionsClosed() public {
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO); // ETH 价格保持 2000
        _trade(eth, alice, bob, 1e18, 2000e6);
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(24000e6);

        _liquidate(carol, carol, alice, 1e18, -23760e6);
        assertEq(dealer.getPositions(alice).length, 1);
        assertEq(dealer.getPrimaryCredit(alice), -1477.6e6);
        assertEq(dealer.getPrimaryCredit(insurance), 237.6e6);

        vm.prank(carol);
        eth.liquidate(carol, alice, 1e18, -1980e6);
        assertEq(dealer.getPositions(alice).length, 0);
        assertEq(dealer.getPrimaryCredit(alice), 0);
        assertEq(dealer.getPrimaryCredit(insurance), 237.6e6 + 19.8e6 - 1517.4e6);
    }

    // ㉙ 部分清算不触发坏账处理：清 0.5 后 alice 仍有仓位、仍穿仓，余额不动
    function testNoBadDebtOnPartialLiquidation() public {
        _deposit(carol, 10000e6);
        btcPrice.setMarkPrice(24000e6);
        _liquidate(carol, carol, alice, 0.5e18, -11880e6);
        assertEq(dealer.getPositions(alice).length, 1);
        assertEq(dealer.getPrimaryCredit(alice), 5000e6);
        assertEq(dealer.getPrimaryCredit(insurance), 118.8e6);
    }

    // ㉚ 谁都能调 handleBadDebt，但条件不满足时什么都不做（不 revert）
    //    有仓位且穿仓：不动；健康账户：不动；坏账处理完再调一次：净值 0 >= 0，不动
    function testHandleBadDebtIsNoopWhenConditionsFail() public {
        btcPrice.setMarkPrice(24000e6);
        vm.prank(bob);
        dealer.handleBadDebt(alice);
        assertEq(dealer.getPrimaryCredit(alice), 5000e6);
        assertEq(dealer.getPrimaryCredit(insurance), 0);

        _deposit(carol, 10000e6);
        vm.prank(bob);
        dealer.handleBadDebt(carol);
        assertEq(dealer.getPrimaryCredit(carol), 10000e6);

        _liquidate(carol, carol, alice, 1e18, -23760e6);
        vm.prank(bob);
        dealer.handleBadDebt(alice);
        assertEq(dealer.getPrimaryCredit(insurance), -1240e6);
    }

    // ==================== getLiquidationPrice（第 6 步：强平价） ====================

    function _liqPrice(address trader, Perpetual perp) internal view returns (uint256) {
        return dealer.getLiquidationPrice(trader, address(perp));
    }

    // ㉛ alice 多 1、主账户 5000：(0 - 5000 + 30000) / 1 / 0.95 = 26315.789473
    function testLiquidationPriceLong() public view {
        assertEq(_liqPrice(alice, btc), 26315789473);
    }

    // ㉜ bob 空 1、主账户 5000：(0 - 5000 - 30000) / (-1) / 1.05 = 33333.333333
    function testLiquidationPriceShort() public view {
        assertEq(_liqPrice(bob, btc), 33333333333);
    }

    // ㉝ 性质测试：标记价 = 强平价时仍安全，再往不利方向走一点就不安全（多空各一次）
    //    多头精确到 1 个最小单位；空头真实边界 = 33333.3333… 被 decimalDiv 截断成 …333，
    //    再加上维持保证金计算也向下取整，实际要再高 2 个单位才不安全，所以空头留 0.01 USDC 的容差
    function testLiquidationPriceIsTheBoundary() public {
        uint256 longLiq = _liqPrice(alice, btc);
        btcPrice.setMarkPrice(longLiq);
        assertTrue(dealer.isSafe(alice));
        btcPrice.setMarkPrice(longLiq - 1);
        assertFalse(dealer.isSafe(alice));

        uint256 shortLiq = _liqPrice(bob, btc);
        btcPrice.setMarkPrice(shortLiq);
        assertTrue(dealer.isSafe(bob));
        btcPrice.setMarkPrice(shortLiq + 0.01e6);
        assertFalse(dealer.isSafe(bob));
    }

    // ㉞ 全仓：alice 另有 ETH 多 1（价格 2000 不变），ETH 占维持保证金 100
    //    (100 - 5000 + 30000) / 0.95 = 26421.052631；ETH 浮亏也会抬高 BTC 强平价
    function testLiquidationPriceCountsOtherMarkets() public {
        (Perpetual eth, MockPriceSource ethPrice) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO);
        _trade(eth, alice, bob, 1e18, 2000e6);
        assertEq(_liqPrice(alice, btc), 26421052631);

        // ETH 跌到 1800：NV' 少 200，MM' = 90 → (90 - 4800 + 30000) / 0.95 = 26621.052631
        ethPrice.setMarkPrice(1800e6);
        assertEq(_liqPrice(alice, btc), 26621052631);
    }

    // ㉟ 返回 0：没有仓位 / 保证金多到价格跌到 0 也不会被清算
    function testLiquidationPriceZeroCases() public {
        assertEq(_liqPrice(carol, btc), 0);

        _deposit(carol, 40000e6);
        _trade(btc, carol, bob, 1e18, 30000e6);
        assertEq(_liqPrice(carol, btc), 0);
    }

    // ㊱ 用的是 MM 比例 liquidationThreshold，不是清算折扣 liquidationPriceOff：把折扣改成 3%，强平价不变
    function testLiquidationPriceUsesThresholdNotPriceOff() public {
        dealer.setPerpRiskParams(
            address(btc),
            Types.RiskParams({
                initialMarginRatio: IM_RATIO,
                liquidationThreshold: MM_RATIO,
                liquidationPriceOff: 3e16,
                insuranceFeeRate: 1e16,
                markPriceSource: address(btcPrice),
                name: "BTC-USDC",
                isRegistered: true
            })
        );
        assertEq(_liqPrice(alice, btc), 26315789473);
    }
}
