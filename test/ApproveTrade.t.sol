// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Perpetual} from "../src/Perpetual.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {DealerFixture} from "./utils/DealerFixture.sol";

/// @notice D3 集成测试：签名订单经 Perpetual.trade → Dealer.approveTrade 的完整链路
/// 默认场景：alice 是 taker（买，上限 30100），bob 是 maker（卖，价 30000）；三人各存 10000 USDC
contract ApproveTradeTest is DealerFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10000e6);
        _deposit(bob, 10000e6);
        _deposit(carol, 10000e6);
    }

    // ==================== 辅助 ====================

    function _submit(Perpetual perp, bytes memory data) internal {
        vm.prank(sender);
        perp.trade(data);
    }

    /// data 必须在 expectRevert 之前构造好：构造时的 vm.sign 也是一次调用，会把 expectRevert "用掉"
    function _submitExpectRevert(Perpetual perp, bytes memory data, string memory reason) internal {
        vm.prank(sender);
        vm.expectRevert(bytes(reason));
        perp.trade(data);
    }

    function _bobSell(int128 paper) internal returns (Types.Order memory) {
        return _newOrder(btc, bob, -paper, paper * 30000 / 1e12, 0, 0); // paper 1e18 精度 × 30000e6 / 1e18
    }

    function _aliceBuy(int128 paper) internal returns (Types.Order memory) {
        return _newOrder(btc, alice, paper, -paper * 30100 / 1e12, 0, 0);
    }

    /// alice 买 1、bob 卖 1 的标准一对一，返回可以再改动的两个数组
    function _defaultPair() internal returns (Types.Order[] memory orders, uint256[] memory amounts) {
        return _pair(_aliceBuy(1e18), _bobSell(1e18), 1e18);
    }

    // ==================== 正常成交 ====================

    /// 测试侧按 EIP-712 规范独立算出的 domainSeparator 必须和合约里的一致（D6 的 Go 后端也要对齐这个值）
    function testDomainSeparatorMatchesSpec() public view {
        assertEq(dealer.domainSeparator(), _domainSeparator(address(dealer)));
    }

    /// 一对一 + 双边手续费：按 maker 价 30000 成交；maker 0.01% = 3，taker 0.05% = 15，都记给 orderSender
    function testFillWithFees() public {
        Types.Order memory taker = _newOrder(btc, alice, 1e18, -30100e6, 0, 5e14);
        Types.Order memory maker = _newOrder(btc, bob, -1e18, 30000e6, 1e14, 0);
        (Types.Order[] memory orders, uint256[] memory amounts) = _pair(taker, maker, 1e18);
        _submit(btc, _encodeSigned(orders, amounts));

        (int256 paper, int256 credit) = btc.balanceOf(alice);
        assertEq(paper, 1e18);
        assertEq(credit, -30015e6);
        (paper, credit) = btc.balanceOf(bob);
        assertEq(paper, -1e18);
        assertEq(credit, 29997e6);
        assertEq(dealer.getPrimaryCredit(sender), 18e6);
    }

    /// 一个 taker 吃多个 maker：一人两张 + 另一人一张，maker 按地址升序；结算到 Perpetual 的是合并后的结果
    function testMultiMakerFill() public {
        (address m1, address m2) = bob < carol ? (bob, carol) : (carol, bob);
        Types.Order[] memory orders = new Types.Order[](4);
        orders[0] = _newOrder(btc, alice, 15e17, -45150e6, 0, 0);
        orders[1] = _newOrder(btc, m1, -1e18, 30000e6, 0, 0);
        orders[2] = _newOrder(btc, m1, -1e18, 30050e6, 0, 0);
        orders[3] = _newOrder(btc, m2, -1e18, 30080e6, 0, 0);
        uint256[] memory amounts = new uint256[](4);
        (amounts[0], amounts[1], amounts[2], amounts[3]) = (15e17, 5e17, 6e17, 4e17);
        _submit(btc, _encodeSigned(orders, amounts));

        (int256 paper, int256 credit) = btc.balanceOf(alice);
        assertEq(paper, 15e17);
        assertEq(credit, -45062e6);
        (paper, credit) = btc.balanceOf(m1);
        assertEq(paper, -11e17);
        assertEq(credit, 33030e6);
        (paper, credit) = btc.balanceOf(m2);
        assertEq(paper, -4e17);
        assertEq(credit, 12032e6);
    }

    // ==================== 防超额成交 / 重放 ====================

    /// 同一张"bob 卖 1"的签名单：0.4 + 0.6 正好成交完，再来 0.1 就超额
    function testPartialFillsUpToOrderAmount() public {
        Types.Order memory maker = _bobSell(1e18);

        (Types.Order[] memory orders, uint256[] memory amounts) = _pair(_aliceBuy(4e17), maker, 4e17);
        _submit(btc, _encodeSigned(orders, amounts));
        (orders, amounts) = _pair(_newOrder(btc, carol, 6e17, -18060e6, 0, 0), maker, 6e17);
        _submit(btc, _encodeSigned(orders, amounts));

        (int256 paper,) = btc.balanceOf(bob);
        assertEq(paper, -1e18);

        (orders, amounts) = _pair(_aliceBuy(1e17), maker, 1e17);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_FILLED_OVERFLOW);
    }

    /// 一次就要成交 1.1，超过订单的 1
    function testOverfillInOneTrade() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _pair(_aliceBuy(2e18), _bobSell(1e18), 11e17);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_FILLED_OVERFLOW);
    }

    /// 把同一份 tradeData 原样再提交一次（重放）：两张单都已成交完，第二次 revert
    function testReplaySameTradeData() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _defaultPair();
        bytes memory data = _encodeSigned(orders, amounts);
        _submit(btc, data);
        _submitExpectRevert(btc, data, Errors.ORDER_FILLED_OVERFLOW);
    }

    // ==================== 签名 ====================

    /// bob 的单被 carol 的私钥签了：恢复出 carol ≠ bob，carol 也不是 bob 的 operator
    function testRevertWrongSigner() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _defaultPair();
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signOrder(keyOf[alice], address(dealer), orders[0]);
        sigs[1] = _signOrder(keyOf[carol], address(dealer), orders[1]);
        _submitExpectRevert(btc, abi.encode(orders, sigs, amounts), Errors.INVALID_ORDER_SIGNATURE);
    }

    /// 签完之后篡改订单（bob 的卖价从 30000 改成 30100）：哈希变了，恢复出的是一个随机地址
    function testRevertTamperedOrder() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _defaultPair();
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signOrder(keyOf[alice], address(dealer), orders[0]);
        sigs[1] = _signOrder(keyOf[bob], address(dealer), orders[1]);
        orders[1].creditAmount = 30100e6;
        _submitExpectRevert(btc, abi.encode(orders, sigs, amounts), Errors.INVALID_ORDER_SIGNATURE);
    }

    /// 合约钱包（ERC-1271）当 maker：钱包没有私钥，由钱包合约自己判断签名有效（这里是 carol 签的就认）
    function testERC1271WalletCanTrade() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(carol);
        keyOf[address(wallet)] = keyOf[carol]; // _encodeSigned 会用 carol 的私钥替钱包签
        usdc.mint(carol, 10000e6);
        vm.startPrank(carol);
        usdc.approve(address(dealer), 10000e6);
        dealer.deposit(10000e6, 0, address(wallet)); // 存进钱包的账户
        vm.stopPrank();

        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_aliceBuy(1e18), _newOrder(btc, address(wallet), -1e18, 30000e6, 0, 0), 1e18);
        _submit(btc, _encodeSigned(orders, amounts));

        (int256 paper,) = btc.balanceOf(address(wallet));
        assertEq(paper, -1e18);
    }

    /// 合约钱包不认的签名（bob 签的，钱包 owner 是 carol）：isValidSignature 不返回魔数 → revert
    function testERC1271WalletRejectsOtherSigner() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(carol);
        keyOf[address(wallet)] = keyOf[bob];
        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_aliceBuy(1e18), _newOrder(btc, address(wallet), -1e18, 30000e6, 0, 0), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.INVALID_ORDER_SIGNATURE);
    }

    // ==================== 订单本身的检查 ====================

    /// 过期：expiration 正好等于当前时间还算有效，早 1 秒就过期
    function testRevertExpired() public {
        vm.warp(1000);
        (Types.Order[] memory orders, uint256[] memory amounts) = _defaultPair();

        orders[1].info = _packInfo(0, 0, 1000, 77);
        _submit(btc, _encodeSigned(orders, amounts)); // 1000 >= 1000，有效

        (orders, amounts) = _defaultPair();
        orders[1].info = _packInfo(0, 0, 999, 78);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_EXPIRED);
    }

    /// paper 和 credit 同号：bob "卖 1 还倒贴 30000"，是负价格
    function testRevertPriceNegative() public {
        (Types.Order[] memory orders, uint256[] memory amounts) = _defaultPair();
        orders[1].creditAmount = -30000e6;
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_PRICE_NEGATIVE);
    }

    /// bob 签的是 ETH 市场的单，被拿到 BTC 市场提交
    function testRevertPerpMismatch() public {
        (Perpetual eth,) = _newMarket("ETH-USDC", 2000e6, IM_RATIO, MM_RATIO);
        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_aliceBuy(1e18), _newOrder(eth, bob, -1e18, 30000e6, 0, 0), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.PERP_MISMATCH);
    }

    /// alice 自己吃自己的卖单
    function testRevertSelfMatch() public {
        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_aliceBuy(1e18), _newOrder(btc, alice, -1e18, 30000e6, 0, 0), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_SELF_MATCH);
    }

    /// bob 卖价 30200 高于 alice 上限 30100（走到 _matchOrders 里的比价）
    function testRevertPriceNotMatch() public {
        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_aliceBuy(1e18), _newOrder(btc, bob, -1e18, 30200e6, 0, 0), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_PRICE_NOT_MATCH);
    }

    // ==================== orderSender 手续费 ====================

    /// maker 返佣 0.01%（3 USDC）由 orderSender 倒贴：sender 没保证金 → 不安全 revert；存了钱就能成交
    function testOrderSenderRebateRequiresMargin() public {
        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_aliceBuy(1e18), _newOrder(btc, bob, -1e18, 30000e6, -1e14, 0), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.ORDER_SENDER_NOT_SAFE);

        _deposit(sender, 10e6);
        (orders, amounts) = _pair(_aliceBuy(1e18), _newOrder(btc, bob, -1e18, 30000e6, -1e14, 0), 1e18);
        _submit(btc, _encodeSigned(orders, amounts));
        assertEq(dealer.getPrimaryCredit(sender), 7e6);
        (, int256 credit) = btc.balanceOf(bob);
        assertEq(credit, 30003e6);
    }

    // ==================== operator 代签 ====================

    /// bob 的单由 carol 的私钥签：bob 授权 carol 为 operator 前不能成交，授权后能，取消授权后又不能
    function testOperatorSignLifecycle() public {
        keyOf[bob] = keyOf[carol]; // 之后所有 signer = bob 的单都用 carol 的私钥签

        (Types.Order[] memory orders, uint256[] memory amounts) = _pair(_aliceBuy(1e18), _bobSell(1e18), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.INVALID_ORDER_SIGNATURE);

        vm.prank(bob);
        dealer.setOperator(carol, true);
        (orders, amounts) = _pair(_aliceBuy(1e18), _bobSell(1e18), 1e18);
        _submit(btc, _encodeSigned(orders, amounts));
        (int256 paper,) = btc.balanceOf(bob);
        assertEq(paper, -1e18); // 成交记在 bob 账上，不是 carol
        (paper,) = btc.balanceOf(carol);
        assertEq(paper, 0);

        vm.prank(bob);
        dealer.setOperator(carol, false);
        (orders, amounts) = _pair(_aliceBuy(1e18), _bobSell(1e18), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.INVALID_ORDER_SIGNATURE);
    }

    /// 授权只对调用者自己生效：carol 声称自己是 bob 的 operator 没用（写进的是 operatorRegistry[carol][carol]）
    function testCannotSetOperatorForOthers() public {
        keyOf[bob] = keyOf[carol];
        vm.prank(carol);
        dealer.setOperator(carol, true);
        (Types.Order[] memory orders, uint256[] memory amounts) = _pair(_aliceBuy(1e18), _bobSell(1e18), 1e18);
        _submitExpectRevert(btc, _encodeSigned(orders, amounts), Errors.INVALID_ORDER_SIGNATURE);
    }
}
