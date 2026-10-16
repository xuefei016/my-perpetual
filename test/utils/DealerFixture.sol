// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeDealer} from "../../src/MetaNodeDealer.sol";
import {Perpetual} from "../../src/Perpetual.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceSource} from "../mocks/MockPriceSource.sol";
import {EIP712Test} from "./EIP712Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice 集成测试公共底座：真 Dealer + 真 Perpetual + 可改价价格源 + 能签名的用户
/// 角色：测试合约 = Dealer 的 owner（管理员）；sender = 白名单撮合引擎；alice / bob / carol 有私钥，可以签订单
abstract contract DealerFixture is EIP712Test {
    MockERC20 usdc;
    MetaNodeDealer dealer;
    Perpetual btc;
    MockPriceSource btcPrice;

    address alice;
    address bob;
    address carol;
    address sender = makeAddr("orderSender");
    mapping(address => uint256) internal keyOf; // 地址 → 私钥，签名时查

    uint64 internal nonce; // 每张订单递增，保证两张内容相同的单哈希也不同

    uint256 constant IM_RATIO = 1e17; // 初始保证金 10%
    uint256 constant MM_RATIO = 5e16; // 维持保证金 5%

    function setUp() public virtual {
        alice = _newUser("alice");
        bob = _newUser("bob");
        carol = _newUser("carol");

        usdc = new MockERC20("USDC", "USDC", 6);
        dealer = new MetaNodeDealer(address(usdc));
        dealer.setMaxPositionAmount(10);
        dealer.setOrderSender(sender, true);
        (btc, btcPrice) = _newMarket("BTC-USDC", 30000e6, IM_RATIO, MM_RATIO);
    }

    // ==================== 环境 ====================

    function _newUser(string memory name) internal returns (address user) {
        uint256 key;
        (user, key) = makeAddrAndKey(name);
        keyOf[user] = key;
    }

    /// 部署一个市场：Perpetual（owner = Dealer）+ 价格源，并在 Dealer 注册
    function _newMarket(string memory name, uint256 price, uint256 im, uint256 mm)
        internal
        returns (Perpetual perp, MockPriceSource source)
    {
        perp = new Perpetual(address(dealer));
        source = new MockPriceSource(price);
        dealer.setPerpRiskParams(
            address(perp),
            Types.RiskParams({
                initialMarginRatio: im,
                liquidationThreshold: mm,
                liquidationPriceOff: 1e16,
                insuranceFeeRate: 1e16,
                markPriceSource: address(source),
                name: name,
                isRegistered: true
            })
        );
    }

    function _deposit(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(dealer), amount);
        dealer.deposit(amount, 0, user);
        vm.stopPrank();
    }

    // ==================== 订单 ====================

    /// 造一张订单：永不过期，nonce 自增
    function _newOrder(Perpetual perp, address signer, int128 paper, int128 credit, int64 makerFee, int64 takerFee)
        internal
        returns (Types.Order memory o)
    {
        o.perp = address(perp);
        o.signer = signer;
        o.paperAmount = paper;
        o.creditAmount = credit;
        o.info = _packInfo(makerFee, takerFee, type(uint64).max, ++nonce);
    }

    /// 用每张单 signer 的私钥签名，编码成 Perpetual.trade 要的 tradeData
    function _encodeSigned(Types.Order[] memory orders, uint256[] memory amounts) internal view returns (bytes memory) {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i = 0; i < orders.length; ++i) {
            sigs[i] = _signOrder(keyOf[orders[i].signer], address(dealer), orders[i]);
        }
        return abi.encode(orders, sigs, amounts);
    }

    /// 最常见的一对一：taker 和 maker 各一张单
    function _pair(Types.Order memory taker, Types.Order memory maker, uint256 amount)
        internal
        pure
        returns (Types.Order[] memory orders, uint256[] memory amounts)
    {
        orders = new Types.Order[](2);
        (orders[0], orders[1]) = (taker, maker);
        amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (amount, amount);
    }

    /// long 以 price 买入 paper 张，short 是对手方：long 当 taker，short 当 maker，双方按同一价格签单，费率 0
    /// paper 精度 1e18，price 是"1 张值多少 USDC 最小单位"，所以 credit = paper * price / 1e18
    function _tradeData(Perpetual perp, address long, address short, int256 paper, int256 price)
        internal
        returns (bytes memory)
    {
        int128 p = SafeCast.toInt128(paper);
        int128 c = SafeCast.toInt128(paper * price / 1e18);
        (Types.Order[] memory orders, uint256[] memory amounts) =
            _pair(_newOrder(perp, long, p, -c, 0, 0), _newOrder(perp, short, -p, c, 0, 0), SafeCast.toUint256(paper));
        return _encodeSigned(orders, amounts);
    }

    /// 由撮合引擎提交一笔成交
    function _trade(Perpetual perp, address long, address short, int256 paper, int256 price) internal {
        bytes memory data = _tradeData(perp, long, short, paper, price);
        vm.prank(sender);
        perp.trade(data);
    }
}
