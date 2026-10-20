// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Perpetual} from "../src/Perpetual.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Types} from "../src/libraries/Types.sol";
import {DealerFixture} from "./utils/DealerFixture.sol";

/// @notice D5 管理函数（MetaNodeOperation / Operation 库）
contract OperationTest is DealerFixture {
    // 事件声明在 Operation 库里，测试要用 expectEmit 就得在这里声明一份同签名的
    event UpdatePerpRiskParams(address indexed perp, Types.RiskParams params);
    event SetInsurance(address oldInsurance, address newInsurance);
    event SetOrderSender(address orderSender, bool isValid);
    event SetMaxPositionAmount(uint256 oldMaxPositionAmount, uint256 newMaxPositionAmount);
    event SetWithdrawTimeLock(uint256 oldWithdrawTimeLock, uint256 newWithdrawTimeLock);
    event SetFundingRateKeeper(address oldKeeper, address newKeeper);
    event UpdateFundingRate(address indexed perp, int256 oldRate, int256 newRate);

    address keeper = makeAddr("keeper");

    function _params(uint256 mm, uint256 off, uint256 fee) internal view returns (Types.RiskParams memory p) {
        p = Types.RiskParams({
            initialMarginRatio: IM_RATIO,
            liquidationThreshold: mm,
            liquidationPriceOff: off,
            insuranceFeeRate: fee,
            markPriceSource: address(btcPrice),
            name: "BTC-USDC",
            isRegistered: true
        });
    }

    /// 读 state 的公开 getter：只返回值类型字段（mapping 全部被跳过），按 State 中的声明顺序
    function _stateValues()
        internal
        view
        returns (uint256 timeLock, uint256 maxPosition, address insurance, address fundingKeeper)
    {
        (,, timeLock,, maxPosition, insurance, fundingKeeper) = dealer.state();
    }

    // ==================== 权限 ====================

    /// setFundingRateKeeper 只有 owner 能调；updateFundingRate 只有 keeper 能调（owner 也不行）
    function testFundingRatePermissions() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        dealer.setFundingRateKeeper(alice);

        address[] memory perps = new address[](1);
        perps[0] = address(btc);
        int256[] memory rates = new int256[](1);
        rates[0] = 10e6;

        // keeper 还没设置（address(0)）时 owner 自己调也不行
        vm.expectRevert(bytes(Errors.INVALID_FUNDING_RATE_KEEPER));
        dealer.updateFundingRate(perps, rates);

        dealer.setFundingRateKeeper(keeper);
        vm.prank(alice);
        vm.expectRevert(bytes(Errors.INVALID_FUNDING_RATE_KEEPER));
        dealer.updateFundingRate(perps, rates);

        vm.prank(keeper);
        dealer.updateFundingRate(perps, rates);
        assertEq(btc.getFundingRate(), 10e6);
    }

    /// 任何人都不能绕过 Dealer 直接改 Perpetual 的资金费率（库里能改是因为 DELEGATECALL 后 msg.sender = Dealer）
    function testPerpetualFundingRateOnlyViaDealer() public {
        vm.prank(keeper);
        vm.expectRevert("Ownable: caller is not the owner");
        btc.updateFundingRate(10e6);
    }

    // ==================== 资金费 ====================

    /// 文档里的例子：rate 0 → 10e6，多 1 张 +10 USDC、空 1 张 -10 USDC；事件由 Dealer 地址发出
    function testUpdateFundingRateChangesCredit() public {
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
        _trade(btc, alice, bob, 1e18, 30000e6);
        (, int256 aliceBefore) = btc.balanceOf(alice);
        (, int256 bobBefore) = btc.balanceOf(bob);

        vm.expectEmit(address(dealer));
        emit SetFundingRateKeeper(address(0), keeper);
        dealer.setFundingRateKeeper(keeper);

        address[] memory perps = new address[](1);
        perps[0] = address(btc);
        int256[] memory rates = new int256[](1);
        rates[0] = 10e6;

        // 库函数是 DELEGATECALL 执行的，所以事件的发出地址是 Dealer，不是 Operation 库
        vm.expectEmit(address(dealer));
        emit UpdateFundingRate(address(btc), 0, 10e6);
        vm.prank(keeper);
        dealer.updateFundingRate(perps, rates);

        (, int256 aliceAfter) = btc.balanceOf(alice);
        (, int256 bobAfter) = btc.balanceOf(bob);
        assertEq(aliceAfter - aliceBefore, 10e6);
        assertEq(bobAfter - bobBefore, -10e6);

        // 第二次更新：oldRate 读的是上一次的值
        rates[0] = -5e6;
        vm.expectEmit(address(dealer));
        emit UpdateFundingRate(address(btc), 10e6, -5e6);
        vm.prank(keeper);
        dealer.updateFundingRate(perps, rates);
    }

    /// 一次更新多个市场，每个市场各拿自己的 rate；数组长度不同 revert
    function testUpdateFundingRateMultiMarketAndLength() public {
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO);
        dealer.setFundingRateKeeper(keeper);

        address[] memory perps = new address[](2);
        (perps[0], perps[1]) = (address(btc), address(eth));
        int256[] memory rates = new int256[](2);
        (rates[0], rates[1]) = (10e6, -3e6);

        vm.prank(keeper);
        dealer.updateFundingRate(perps, rates);
        assertEq(btc.getFundingRate(), 10e6);
        assertEq(eth.getFundingRate(), -3e6);

        int256[] memory shortRates = new int256[](1);
        shortRates[0] = 1;
        vm.prank(keeper);
        vm.expectRevert(bytes(Errors.ARRAY_LENGTH_NOT_SAME));
        dealer.updateFundingRate(perps, shortRates);
    }

    // ==================== 风控参数校验 ====================

    /// 折扣 + 保险费 ≤ MM：3% + 3% > 5% revert；2% + 3% = 5% 刚好通过；多 1 wei 就 revert
    function testRiskParamsValidation() public {
        vm.expectRevert(bytes(Errors.INVALID_RISK_PARAM));
        dealer.setPerpRiskParams(address(btc), _params(5e16, 3e16, 3e16));

        dealer.setPerpRiskParams(address(btc), _params(5e16, 2e16, 3e16));
        assertEq(dealer.getRiskParams(address(btc)).liquidationPriceOff, 2e16);

        vm.expectRevert(bytes(Errors.INVALID_RISK_PARAM));
        dealer.setPerpRiskParams(address(btc), _params(5e16, 2e16 + 1, 3e16));
    }

    // ==================== 事件（旧值 + 新值）====================

    function testSetterEventsAndValues() public {
        address ins1 = makeAddr("ins1");
        address ins2 = makeAddr("ins2");

        vm.expectEmit(address(dealer));
        emit SetInsurance(address(0), ins1);
        dealer.setInsurance(ins1);
        vm.expectEmit(address(dealer));
        emit SetInsurance(ins1, ins2);
        dealer.setInsurance(ins2);

        vm.expectEmit(address(dealer));
        emit SetMaxPositionAmount(10, 20); // 底座 setUp 已设为 10
        dealer.setMaxPositionAmount(20);

        vm.expectEmit(address(dealer));
        emit SetWithdrawTimeLock(0, 3600);
        dealer.setWithdrawTimeLock(3600);

        vm.expectEmit(address(dealer));
        emit SetOrderSender(alice, true);
        dealer.setOrderSender(alice, true);

        Types.RiskParams memory p = _params(5e16, 2e16, 1e16);
        vm.expectEmit(true, false, false, true, address(dealer));
        emit UpdatePerpRiskParams(address(btc), p);
        dealer.setPerpRiskParams(address(btc), p);

        dealer.setFundingRateKeeper(keeper);
        (uint256 timeLock, uint256 maxPosition, address insurance, address fundingKeeper) = _stateValues();
        assertEq(timeLock, 3600);
        assertEq(maxPosition, 20);
        assertEq(insurance, ins2);
        assertEq(fundingKeeper, keeper);
    }
}

/// @notice D5 只读查询（MetaNodeView），数字沿用 D4 场景 A：alice 存 5000，多 1 BTC @ 30000，跌到 26000
contract ViewTest is DealerFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 5000e6);
        _deposit(bob, 5000e6);
    }

    function testRiskParamsMatchesRegistration() public view {
        Types.RiskParams memory p = dealer.getRiskParams(address(btc));
        assertEq(p.initialMarginRatio, IM_RATIO);
        assertEq(p.liquidationThreshold, MM_RATIO);
        assertEq(p.liquidationPriceOff, 1e16);
        assertEq(p.insuranceFeeRate, 1e16);
        assertEq(p.markPriceSource, address(btcPrice));
        assertEq(p.name, "BTC-USDC");
        assertTrue(p.isRegistered);

        // 没注册的地址返回全零
        assertFalse(dealer.getRiskParams(alice).isRegistered);
    }

    function testScenarioAViews() public {
        _trade(btc, alice, bob, 1e18, 30000e6);
        btcPrice.setMarkPrice(26000e6);

        address[] memory positions = dealer.getPositions(alice);
        assertEq(positions.length, 1);
        assertEq(positions[0], address(btc));
        assertEq(dealer.getPositions(carol).length, 0);

        assertEq(dealer.getPrimaryCredit(alice), 5000e6);

        (int256 netValue, uint256 exposure, uint256 im, uint256 mm) = dealer.getTraderRisk(alice);
        assertEq(netValue, 1000e6);
        assertEq(exposure, 26000e6);
        assertEq(im, 2600e6);
        assertEq(mm, 1300e6);

        // 5000 + (P - 30000) = 5% × P → P = 25000 / 0.95 ≈ 26315.789473
        assertApproxEqAbs(dealer.getLiquidationPrice(alice, address(btc)), 26315_789473, 1);
    }

    /// 清算人视角的成本：全部、部分、超额截断；反号与安全账户 revert
    function testLiquidationCost() public {
        _trade(btc, alice, bob, 1e18, 30000e6);
        btcPrice.setMarkPrice(26000e6);

        (int256 paper, int256 credit) = dealer.getLiquidationCost(address(btc), alice, 1e18);
        assertEq(paper, 1e18);
        assertEq(credit, -25740e6); // 26000 × 99%，清算人付钱为负

        (paper, credit) = dealer.getLiquidationCost(address(btc), alice, 0.5e18);
        assertEq(paper, 0.5e18);
        assertEq(credit, -12870e6);

        (paper, credit) = dealer.getLiquidationCost(address(btc), alice, 2e18); // 超过仓位，截断到 1 张
        assertEq(paper, 1e18);
        assertEq(credit, -25740e6);

        vm.expectRevert(bytes(Errors.LIQUIDATION_REQUEST_AMOUNT_WRONG));
        dealer.getLiquidationCost(address(btc), alice, -1e18);

        vm.expectRevert(bytes(Errors.ACCOUNT_IS_SAFE)); // bob 是空头，跌价时盈利
        dealer.getLiquidationCost(address(btc), bob, -1e18);
    }

    /// 空头被清算：清算人接空仓（paper 为负），按 1.01 倍标记价卖出，收到钱为正
    function testLiquidationCostShort() public {
        _trade(btc, alice, bob, 1e18, 30000e6);
        btcPrice.setMarkPrice(33500e6); // bob 净值 5000 - 3500 = 1500 < 33500 × 5% = 1675

        (int256 paper, int256 credit) = dealer.getLiquidationCost(address(btc), bob, -1e18);
        assertEq(paper, -1e18);
        assertEq(credit, 33835e6); // 33500 × 101%
    }

    /// 订单已成交量：taker 单挂 2 张只成交 1 张 → 1e18；maker 单 1 张全成交 → 1e18；没成交的单 → 0
    function testOrderFilledAmount() public {
        Types.Order memory taker = _newOrder(btc, alice, 2e18, -60000e6, 0, 0);
        Types.Order memory maker = _newOrder(btc, bob, -1e18, 30000e6, 0, 0);
        (Types.Order[] memory orders, uint256[] memory amounts) = _pair(taker, maker, 1e18);
        bytes memory data = _encodeSigned(orders, amounts);
        vm.prank(sender);
        btc.trade(data);

        assertEq(dealer.getOrderFilledAmount(_orderDigest(address(dealer), taker)), 1e18);
        assertEq(dealer.getOrderFilledAmount(_orderDigest(address(dealer), maker)), 1e18);

        Types.Order memory unused = _newOrder(btc, carol, 1e18, -30000e6, 0, 0);
        assertEq(dealer.getOrderFilledAmount(_orderDigest(address(dealer), unused)), 0);
    }

    /// operator 授权：键序是 [client][operator]，授权后可查到、撤销后查不到
    function testIsOperatorValid() public {
        address bot = makeAddr("bot");
        assertFalse(dealer.isOperatorValid(alice, bot));

        vm.prank(alice);
        dealer.setOperator(bot, true);
        assertTrue(dealer.isOperatorValid(alice, bot));
        assertFalse(dealer.isOperatorValid(bot, alice)); // 键序反了查不到
        assertFalse(dealer.isOperatorValid(bob, bot)); // 只授权给了 alice

        vm.prank(alice);
        dealer.setOperator(bot, false);
        assertFalse(dealer.isOperatorValid(alice, bot));
    }
}
