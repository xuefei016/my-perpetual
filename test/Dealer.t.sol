// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Perpetual} from "../src/Perpetual.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Types} from "../src/libraries/Types.sol";
import {DealerFixture} from "./utils/DealerFixture.sol";

/// @notice D2 集成测试：真 Dealer + 真 Perpetual + 可改价的价格源
/// D3 起成交改为签名订单：环境和 _trade 辅助搬到 DealerFixture（alice 当 taker 买、bob 当 maker 卖，各自签名）
contract DealerTest is DealerFixture {
    // ==================== 验收场景 ====================

    // ① D2 验收：存款 → 开仓 → 价格下跌 → isSafe 从 true 变 false
    function testScenarioPriceDropMakesLongUnsafe() public {
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);

        // 开仓后：Dealer 登记了持仓市场
        address[] memory positions = dealer.getPositions(alice);
        assertEq(positions.length, 1);
        assertEq(positions[0], address(btc));

        // 价格 30000：净值 5000，敞口 30000，IM 3000，MM 1500
        (int256 netValue, uint256 exposure, uint256 im, uint256 mm) = dealer.getTraderRisk(alice);
        assertEq(netValue, 5000e6);
        assertEq(exposure, 30000e6);
        assertEq(im, 3000e6);
        assertEq(mm, 1500e6);
        assertTrue(dealer.isSafe(alice));

        // 价格跌到 26000：净值 5000 - 4000 = 1000 < MM 1300
        btcPrice.setMarkPrice(26000e6);
        (netValue, exposure,, mm) = dealer.getTraderRisk(alice);
        assertEq(netValue, 1000e6);
        assertEq(exposure, 26000e6);
        assertEq(mm, 1300e6);
        assertFalse(dealer.isSafe(alice));

        // 空头 bob 在下跌中赚钱：净值 5000 + 4000 = 9000，仍然安全
        (netValue,,,) = dealer.getTraderRisk(bob);
        assertEq(netValue, 9000e6);
        assertTrue(dealer.isSafe(bob));
    }

    // ② 反方向：价格上涨，空头变得不安全
    function testPriceRiseMakesShortUnsafe() public {
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);

        btcPrice.setMarkPrice(34000e6); // bob 净值 5000 - 4000 = 1000 < MM 1700
        assertFalse(dealer.isSafe(bob));
        assertTrue(dealer.isSafe(alice));
    }

    // ③ 边界：净值恰好等于维持保证金算安全，少一点就不安全（>= 而不是 >）
    function testMMSafeBoundary() public {
        _deposit(alice, 3400e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);

        btcPrice.setMarkPrice(28000e6); // 净值 3400 - 2000 = 1400，MM = 28000 * 5% = 1400
        assertTrue(dealer.isSafe(alice));

        btcPrice.setMarkPrice(27999e6); // 净值 1399，MM = 1399.95
        assertFalse(dealer.isSafe(alice));
    }

    // ④ 多市场：敞口和保证金按各市场自己的比例累加
    function testExposureSumsAcrossMarkets() public {
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, 2e17, 1e17); // ETH 更严：IM 20%，MM 10%
        _deposit(alice, 10000e6);
        _deposit(bob, 10000e6);
        _trade(btc, alice, bob, 1e18, 30000e6); // alice 多 1 BTC
        _trade(eth, bob, alice, 5e18, 2000e6); // alice 空 5 ETH（敞口 10000）

        (int256 netValue, uint256 exposure, uint256 im, uint256 mm) = dealer.getTraderRisk(alice);
        assertEq(netValue, 10000e6); // 刚开仓，两边都没有盈亏
        assertEq(exposure, 40000e6); // 30000 + |-10000|，空头也算敞口
        assertEq(im, 5000e6); // 30000*10% + 10000*20%
        assertEq(mm, 2500e6); // 30000*5% + 10000*10%
        assertEq(dealer.getPositions(alice).length, 2);
    }

    // ==================== 成交把关 ====================

    // ⑤ 成交后不满足维持保证金 → 整笔回滚（Perpetual.trade 结尾的 isAllSafe）
    function testTradeRevertsWhenTraderNotSafe() public {
        _deposit(alice, 1000e6); // MM 需要 1500
        _deposit(bob, 5000e6);

        bytes memory data = _tradeData(btc, alice, bob, 1e18, 30000e6);

        vm.prank(sender);
        vm.expectRevert("TRADER_NOT_SAFE");
        btc.trade(data);

        assertEq(dealer.getPositions(alice).length, 0); // 回滚后没有留下持仓记录
    }

    // ⑥ 不在白名单的人提交成交 → revert（trade 去掉 onlyOwner 后的把关点）
    function testTradeRevertsForInvalidOrderSender() public {
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        bytes memory data = _tradeData(btc, alice, bob, 1e18, 30000e6); // 签名完全合法，只是提交人不对

        vm.prank(alice);
        vm.expectRevert(bytes(Errors.INVALID_ORDER_SENDER));
        btc.trade(data);
    }

    // ==================== Position：开仓登记 / 平仓结算 ====================

    // ⑦ 平仓：盈亏结回 primaryCredit，持仓列表清空，序列号 +1 之后可重新开仓
    function testClosePositionRealizesPnl() public {
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6); // alice 30000 买
        btcPrice.setMarkPrice(32000e6);
        _trade(btc, bob, alice, 1e18, 32000e6); // alice 32000 卖（bob 买回）

        assertEq(dealer.getPrimaryCredit(alice), 7000e6);
        assertEq(dealer.getPrimaryCredit(bob), 3000e6);
        assertEq(dealer.getPositions(alice).length, 0);
        assertEq(dealer.getPositions(bob).length, 0);

        (int256 paper, int256 credit) = btc.balanceOf(alice);
        assertEq(paper, 0);
        assertEq(credit, 0);

        // 净值只剩保证金，不再有敞口
        (int256 netValue, uint256 exposure,,) = dealer.getTraderRisk(alice);
        assertEq(netValue, 7000e6);
        assertEq(exposure, 0);
    }

    // ⑧ swap-and-pop：三个市场平掉第一个，最后一个补到它的位置
    function testClosePositionSwapAndPop() public {
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO);
        (Perpetual sol,) = _newMarket("SOL-USDC", 100e6, IM_RATIO, MM_RATIO);
        _deposit(alice, 10000e6);
        _deposit(bob, 10000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);
        _trade(eth, alice, bob, 1e18, 2000e6);
        _trade(sol, alice, bob, 1e18, 100e6);

        _trade(btc, bob, alice, 1e18, 30000e6); // alice 平掉 BTC

        address[] memory positions = dealer.getPositions(alice);
        assertEq(positions.length, 2);
        assertEq(positions[0], address(sol)); // [BTC, ETH, SOL] → [SOL, ETH]
        assertEq(positions[1], address(eth));
    }

    // ⑨ 持仓市场数达到上限后不能再开新市场
    function testOpenPositionRevertsAtMaxPositionAmount() public {
        dealer.setMaxPositionAmount(1);
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO);
        _deposit(alice, 10000e6);
        _deposit(bob, 10000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);

        bytes memory data = _tradeData(eth, alice, bob, 1e18, 2000e6);

        vm.prank(sender);
        vm.expectRevert(bytes(Errors.POSITION_AMOUNT_REACH_UPPER_LIMIT));
        eth.trade(data);
    }

    // ==================== 取款与持仓联动（_isSolidIMSafe） ====================

    // ⑩ 有持仓时取款：取完净值必须仍 >= 初始保证金
    function testWithdrawWithPositionChecksInitialMargin() public {
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6); // IM = 3000

        vm.prank(alice);
        vm.expectRevert(bytes(Errors.ACCOUNT_NOT_SAFE));
        dealer.fastWithdraw(alice, 2000e6 + 1, 0); // 剩 2999.999999 < 3000

        vm.prank(alice);
        dealer.fastWithdraw(alice, 2000e6, 0); // 剩 3000，恰好够
        assertEq(dealer.getPrimaryCredit(alice), 3000e6);
        assertEq(usdc.balanceOf(alice), 2000e6);
    }

    // ==================== 权限 ====================

    // ⑪ 回调入口只允许注册过的 Perpetual 调用，否则任何人都能给自己加钱
    function testCallbacksRevertForUnregisteredCaller() public {
        vm.startPrank(alice);

        vm.expectRevert(bytes(Errors.PERP_NOT_REGISTERED));
        dealer.realizePnl(alice, 1_000_000e6);

        vm.expectRevert(bytes(Errors.PERP_NOT_REGISTERED));
        dealer.openPosition(alice);

        vm.expectRevert(bytes(Errors.PERP_NOT_REGISTERED));
        dealer.approveTrade(sender, "");

        vm.stopPrank();
        assertEq(dealer.getPrimaryCredit(alice), 0);
    }

    // ⑫ 管理函数只有 owner 能调
    function testAdminFunctionsOnlyOwner() public {
        Types.RiskParams memory params;
        params.isRegistered = true;

        vm.startPrank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        dealer.setPerpRiskParams(alice, params);
        vm.expectRevert("Ownable: caller is not the owner");
        dealer.setOrderSender(alice, true);
        vm.expectRevert("Ownable: caller is not the owner");
        dealer.setMaxPositionAmount(100);
        vm.expectRevert("Ownable: caller is not the owner");
        dealer.setWithdrawTimeLock(0);
        vm.stopPrank();
    }
}
