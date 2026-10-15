// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Errors} from "../src/libraries/Errors.sol";
import {Trading} from "../src/libraries/Trading.sol";
import {Types} from "../src/libraries/Types.sol";
import {EIP712Test} from "./utils/EIP712Test.sol";

/// @notice Trading 库的单元测试（D3）
/// library 的 internal 函数会被内联进调用方，所以测试合约可以直接调用，不需要 harness
contract TradingTest is EIP712Test {
    // ==================== info 解码 ====================

    /// alice 的例子：maker 0.01%，taker 0.05%，过期 1700000000，nonce 1
    function testInfoDecode() public pure {
        bytes32 info = _packInfo(1e14, 5e14, 1700000000, 1);
        assertEq(Trading._info2MakerFeeRate(info), 1e14);
        assertEq(Trading._info2TakerFeeRate(info), 5e14);
        assertEq(Trading._info2Expiration(info), 1700000000);
    }

    /// maker 返佣（负费率）必须按有符号数解出负数，不能变成 ~1.8e19 的巨大正数
    function testInfoDecodeNegativeMakerFee() public pure {
        bytes32 info = _packInfo(-1e14, 5e14, 1700000000, 1);
        assertEq(Trading._info2MakerFeeRate(info), -1e14);
        assertEq(Trading._info2TakerFeeRate(info), 5e14);
    }

    /// 相邻字段互不干扰：每个字段都取 64 位里能放下的最大值时，解码仍各自正确
    function testInfoDecodeFieldsIsolated() public pure {
        bytes32 info = _packInfo(-1, -1, type(uint64).max, type(uint64).max);
        assertEq(Trading._info2MakerFeeRate(info), -1);
        assertEq(Trading._info2TakerFeeRate(info), -1);
        assertEq(Trading._info2Expiration(info), type(uint64).max);
    }

    // ==================== 价格匹配 ====================

    /// vm.expectRevert 只能捕获"下一次外部调用"的 revert，所以包一层 external，用 this.xxx() 调
    function priceMatchCheck(Types.Order memory taker, Types.Order memory maker) external pure {
        Trading._priceMatchCheck(taker, maker);
    }

    /// 只关心 paper / credit，其他字段留空
    function _order(int128 paper, int128 credit) internal pure returns (Types.Order memory o) {
        o.paperAmount = paper;
        o.creditAmount = credit;
    }

    /// taker 买（上限 30100），maker 卖 30000：能成交
    function testPriceMatchTakerBuy() public view {
        this.priceMatchCheck(_order(1e18, -30100e6), _order(-1e18, 30000e6));
    }

    /// 边界：maker 卖价正好等于 taker 上限，也能成交（<= 不是 <）
    function testPriceMatchTakerBuyEqualPrice() public view {
        this.priceMatchCheck(_order(1e18, -30000e6), _order(-1e18, 30000e6));
    }

    /// taker 买，maker 卖价 30200 高于上限 30100：revert
    function testPriceMatchTakerBuyTooExpensive() public {
        vm.expectRevert(bytes(Errors.ORDER_PRICE_NOT_MATCH));
        this.priceMatchCheck(_order(1e18, -30100e6), _order(-1e18, 30200e6));
    }

    /// taker 买，maker 也是买单：方向相同，revert
    function testPriceMatchTakerBuySameSide() public {
        vm.expectRevert(bytes(Errors.ORDER_PRICE_NOT_MATCH));
        this.priceMatchCheck(_order(1e18, -30100e6), _order(1e18, -30000e6));
    }

    /// taker 卖（下限 29900，1 张），maker 买 2 张出价 30000：能成交，数量不同不影响比单价
    function testPriceMatchTakerSell() public view {
        this.priceMatchCheck(_order(-1e18, 29900e6), _order(2e18, -60000e6));
    }

    /// 边界：maker 买价正好等于 taker 下限，也能成交
    function testPriceMatchTakerSellEqualPrice() public view {
        this.priceMatchCheck(_order(-1e18, 30000e6), _order(2e18, -60000e6));
    }

    /// taker 卖（下限 29900），maker 只出 29800：revert
    function testPriceMatchTakerSellTooCheap() public {
        vm.expectRevert(bytes(Errors.ORDER_PRICE_NOT_MATCH));
        this.priceMatchCheck(_order(-1e18, 29900e6), _order(1e18, -29800e6));
    }

    /// taker 卖，maker 也是卖单：方向相同，revert
    function testPriceMatchTakerSellSameSide() public {
        vm.expectRevert(bytes(Errors.ORDER_PRICE_NOT_MATCH));
        this.priceMatchCheck(_order(-1e18, 29900e6), _order(-1e18, 29800e6));
    }

    // ==================== 撮合 _matchOrders ====================

    /// 测试合约自己持有一份 State，直接传给 library（internal 函数可以接收 storage 引用）
    Types.State internal state;

    // 地址固定，保证 maker 按地址升序：bob < carol，erin < frank
    address constant ALICE = address(0x9000);
    address constant BOB = address(0x1000);
    address constant CAROL = address(0x2000);
    address constant DAVE = address(0x9100);
    address constant ERIN = address(0x3000);
    address constant FRANK = address(0x4000);
    address constant PERP = address(0xBEEF);

    /// 和 Trading.OrderFilled 签名完全相同，用于 vm.expectEmit 比对
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed trader,
        address indexed perp,
        int256 orderFilledPaperAmount,
        int256 filledCreditAmount,
        uint256 positionSerialNum,
        int256 fee
    );

    function _mkOrder(address signer, int128 paper, int128 credit, int64 makerFee, int64 takerFee)
        internal
        pure
        returns (Types.Order memory o)
    {
        o.perp = PERP;
        o.signer = signer;
        o.paperAmount = paper;
        o.creditAmount = credit;
        o.info = _packInfo(makerFee, takerFee, type(uint64).max, 0);
    }

    function _match(Types.Order[] memory orders, uint256[] memory amounts)
        internal
        returns (Types.MatchResult memory)
    {
        return Trading._matchOrders(state, new bytes32[](orders.length), orders, amounts);
    }

    /// 包一层 external，给 vm.expectRevert 用
    function matchOrders(Types.Order[] memory orders, uint256[] memory amounts)
        external
        returns (Types.MatchResult memory)
    {
        return _match(orders, amounts);
    }

    /// 贯穿例子：alice 买 1.5（上限 30100），吃 bob 两张（30000 / 30050）+ carol 一张（30080）
    /// maker 费率 0.01%，taker 费率设 0，只验 5a/5b 的部分
    function _exampleOrders() internal pure returns (Types.Order[] memory orders, uint256[] memory amounts) {
        orders = new Types.Order[](4);
        orders[0] = _mkOrder(ALICE, 15e17, -45150e6, 0, 0);
        orders[1] = _mkOrder(BOB, -1e18, 30000e6, 1e14, 0);
        orders[2] = _mkOrder(BOB, -1e18, 30050e6, 1e14, 0);
        orders[3] = _mkOrder(CAROL, -1e18, 30080e6, 1e14, 0);
        amounts = new uint256[](4);
        amounts[0] = 15e17;
        amounts[1] = 5e17;
        amounts[2] = 6e17;
        amounts[3] = 4e17;
    }

    /// 同一个 maker 的两张单合并成一格；每张都按 maker 自己的价格成交；maker 手续费从 maker 的 credit 扣
    function testMatchOrdersExample() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        Types.MatchResult memory r = _match(orders, amounts);

        assertEq(r.traderList.length, 3);
        assertEq(r.traderList[0], ALICE);
        assertEq(r.traderList[1], BOB);
        assertEq(r.traderList[2], CAROL);

        assertEq(r.paperChangeList[0], 15e17);
        assertEq(r.paperChangeList[1], -11e17);
        assertEq(r.paperChangeList[2], -4e17);

        // alice 按 30000/30050/30080 成交，共付 45062，不是按她的上限 30100 付 45150
        assertEq(r.creditChangeList[0], -45062e6);
        assertEq(r.creditChangeList[1], 33026697000); // 15000 + 18030 - 1.5 - 1.803
        assertEq(r.creditChangeList[2], 12030796800); // 12032 - 1.2032
        assertEq(r.orderSenderFee, 4506200); // 1.5 + 1.803 + 1.2032
    }

    /// 守恒：paper 多空相抵；所有人 credit 变化 + orderSender 手续费 = 0（钱不会凭空产生或消失）
    function testMatchOrdersConservation() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        Types.MatchResult memory r = _match(orders, amounts);
        int256 paperSum;
        int256 creditSum;
        for (uint256 i = 0; i < r.traderList.length; ++i) {
            paperSum += r.paperChangeList[i];
            creditSum += r.creditChangeList[i];
        }
        assertEq(paperSum, 0);
        assertEq(creditSum + r.orderSenderFee, 0);
    }

    /// taker 卖：dave 卖 1（下限 29900），erin 买 0.3 价30000、frank 买 0.7 价29950，费率 0
    function testMatchOrdersTakerSell() public {
        Types.Order[] memory orders = new Types.Order[](3);
        orders[0] = _mkOrder(DAVE, -1e18, 29900e6, 0, 0);
        orders[1] = _mkOrder(ERIN, 1e18, -30000e6, 0, 0);
        orders[2] = _mkOrder(FRANK, 1e18, -29950e6, 0, 0);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 3e17;
        amounts[2] = 7e17;

        Types.MatchResult memory r = _match(orders, amounts);
        assertEq(r.paperChangeList[0], -1e18);
        assertEq(r.creditChangeList[0], 29965e6); // 9000 + 20965
        assertEq(r.paperChangeList[1], 3e17);
        assertEq(r.creditChangeList[1], -9000e6);
        assertEq(r.paperChangeList[2], 7e17);
        assertEq(r.creditChangeList[2], -20965e6);
    }

    /// maker 费率为负（返佣）：maker 多拿钱，orderSender 倒贴，不能 revert
    function testMatchOrdersMakerRebate() public {
        Types.Order[] memory orders = new Types.Order[](2);
        orders[0] = _mkOrder(ALICE, 1e18, -30000e6, 0, 0);
        orders[1] = _mkOrder(BOB, -1e18, 30000e6, -1e14, 0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;

        Types.MatchResult memory r = _match(orders, amounts);
        assertEq(r.creditChangeList[1], 30003e6);
        assertEq(r.orderSenderFee, -3e6);
    }

    /// 每张 maker 单发一次 OrderFilled，perp = msg.sender，金额是扣完手续费的
    /// 这里是测试合约内部直接调用 library，所以 msg.sender 是调用测试函数的外部账户（真实场景里是 Perpetual）
    function testMatchOrdersMakerEvent() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        vm.expectEmit(true, true, true, true);
        emit OrderFilled(bytes32(0), BOB, msg.sender, -5e17, 14998500000, 0, 1500000);
        _match(orders, amounts);
    }

    function testMatchOrdersRevertSingleOrder() public {
        Types.Order[] memory orders = new Types.Order[](1);
        orders[0] = _mkOrder(ALICE, 1e18, -30000e6, 0, 0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e18;
        vm.expectRevert(bytes(Errors.INVALID_TRADER_NUMBER));
        this.matchOrders(orders, amounts);
    }

    /// maker 顺序 bob, carol, bob：carol → bob 地址变小，revert
    function testMatchOrdersRevertWrongSorting() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        (orders[2], orders[3]) = (orders[3], orders[2]);
        vm.expectRevert(bytes(Errors.ORDER_WRONG_SORTING));
        this.matchOrders(orders, amounts);
    }

    /// 引擎声称 alice 只成交 0.1，但 maker 一共成交 1.5：revert
    function testMatchOrdersRevertTakerAmountWrong() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        amounts[0] = 1e17;
        vm.expectRevert(bytes(Errors.TAKER_TRADE_AMOUNT_WRONG));
        this.matchOrders(orders, amounts);
    }

    /// carol 那张改成 30200，超过 alice 上限：撮合里的比价会拦下
    function testMatchOrdersRevertPriceNotMatch() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        orders[3] = _mkOrder(CAROL, -1e18, 30200e6, 1e14, 0);
        vm.expectRevert(bytes(Errors.ORDER_PRICE_NOT_MATCH));
        this.matchOrders(orders, amounts);
    }

    // ==================== taker 手续费（5c） ====================

    /// 贯穿例子加上 taker 费率 0.05%：alice 多付 45062 × 0.05% = 22.531，orderSender 共收 27.0372
    function testMatchOrdersTakerFeeBuy() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        orders[0] = _mkOrder(ALICE, 15e17, -45150e6, 0, 5e14);
        Types.MatchResult memory r = _match(orders, amounts);
        assertEq(r.creditChangeList[0], -45084531000);
        assertEq(r.orderSenderFee, 27037200);
    }

    /// taker 卖也一样要付手续费：dave 收 29965，扣 0.05% = 14.9825 后实收 29950.0175
    function testMatchOrdersTakerFeeSell() public {
        Types.Order[] memory orders = new Types.Order[](2);
        orders[0] = _mkOrder(DAVE, -1e18, 29900e6, 0, 5e14);
        orders[1] = _mkOrder(ERIN, 1e18, -29965e6, 0, 0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        Types.MatchResult memory r = _match(orders, amounts);
        assertEq(r.creditChangeList[0], 29950017500);
        assertEq(r.orderSenderFee, 14982500);
    }

    /// 加上 taker 手续费后仍然守恒，taker 那条汇总事件的金额是扣完手续费的
    function testMatchOrdersTakerFeeConservationAndEvent() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _exampleOrders();
        orders[0] = _mkOrder(ALICE, 15e17, -45150e6, 0, 5e14);
        // taker 的事件是最后一条，只校验它：前三条 maker 事件按顺序先放进期望列表
        vm.expectEmit(true, true, true, true);
        emit OrderFilled(bytes32(0), BOB, msg.sender, -5e17, 14998500000, 0, 1500000);
        vm.expectEmit(true, true, true, true);
        emit OrderFilled(bytes32(0), BOB, msg.sender, -6e17, 18028197000, 0, 1803000);
        vm.expectEmit(true, true, true, true);
        emit OrderFilled(bytes32(0), CAROL, msg.sender, -4e17, 12030796800, 0, 1203200);
        vm.expectEmit(true, true, true, true);
        emit OrderFilled(bytes32(0), ALICE, msg.sender, 15e17, -45084531000, 0, 22531000);
        Types.MatchResult memory r = _match(orders, amounts);

        int256 creditSum;
        for (uint256 i = 0; i < r.traderList.length; ++i) {
            creditSum += r.creditChangeList[i];
        }
        assertEq(creditSum + r.orderSenderFee, 0);
    }

    /// taker 费率为负（返佣）：和 maker 一样，正负号只由费率决定。alice 买 1 价 30000，费率 -0.01%，少付 3
    function testMatchOrdersTakerRebate() public {
        Types.Order[] memory orders = new Types.Order[](2);
        orders[0] = _mkOrder(ALICE, 1e18, -30000e6, 0, -1e14);
        orders[1] = _mkOrder(BOB, -1e18, 30000e6, 0, 0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        Types.MatchResult memory r = _match(orders, amounts);
        assertEq(r.creditChangeList[0], -29997e6);
        assertEq(r.orderSenderFee, -3e6);
    }
}
