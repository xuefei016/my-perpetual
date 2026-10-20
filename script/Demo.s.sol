// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeDealer} from "../src/MetaNodeDealer.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {EIP712} from "../src/libraries/EIP712.sol";
import {Trading} from "../src/libraries/Trading.sol";
import {Types} from "../src/libraries/Types.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockPriceSource} from "../test/mocks/MockPriceSource.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @notice 在 Deploy.s.sol 部署好的 anvil 链上，把 D1–D4 的完整流程真实跑一遍（场景 A）：
///   存款 → 撮合引擎提交签名订单成交 → 价格下跌 → 清算人清算
/// 每个 startBroadcast(key) 段都是由该账户签名发出的真实交易；私钥全部是 anvil 公开的测试私钥，只能用于本地链
/// 运行：forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
/// 合约地址默认是"全新 anvil 上跑 Deploy.s.sol"得到的确定性地址，可用环境变量覆盖
contract DemoScript is Script {
    uint256 constant ORDER_SENDER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // anvil #1
    uint256 constant ALICE_KEY = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a; // anvil #4（Deploy 已 mint）
    uint256 constant BOB_KEY = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba; // anvil #5
    uint256 constant CAROL_KEY = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e; // anvil #6（清算人）

    MockERC20 usdc;
    MetaNodeDealer dealer;
    MockPriceSource btcPrice;
    Perpetual btc;
    address alice;
    address bob;
    address carol;

    function run() external {
        usdc = MockERC20(vm.envOr("USDC", 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9));
        dealer = MetaNodeDealer(vm.envOr("DEALER", 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707));
        btcPrice = MockPriceSource(vm.envOr("BTC_PRICE", 0x610178dA211FEF7D417bC0e6FeD39F05609AD788));
        btc = Perpetual(vm.envOr("BTC", 0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e));
        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);
        carol = vm.addr(CAROL_KEY);

        _stepDeposit();
        _stepTrade();
        _stepPriceDrop();
        _stepLiquidate();
    }

    /// ① 存款：alice 5000、bob 5000、carol 10000（bob / carol 自己 mint，MockERC20.mint 谁都能调）
    function _stepDeposit() internal {
        _deposit(ALICE_KEY, 5000e6, false);
        _deposit(BOB_KEY, 5000e6, true);
        _deposit(CAROL_KEY, 10000e6, true);
        console2.log("[1] primaryCredit alice", dealer.getPrimaryCredit(alice));
        console2.log("    primaryCredit bob  ", dealer.getPrimaryCredit(bob));
        console2.log("    primaryCredit carol", dealer.getPrimaryCredit(carol));
    }

    /// ② 成交：alice 签"以 30000 买 1 张"，bob 签"以 30000 卖 1 张"，撮合引擎（#1）调 btc.trade 提交
    function _stepTrade() internal {
        Types.Order memory taker = _order(alice, 1e18, -30000e6, 1);
        Types.Order memory maker = _order(bob, -1e18, 30000e6, 2);
        Types.Order[] memory orders = new Types.Order[](2);
        (orders[0], orders[1]) = (taker, maker);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_sign(ALICE_KEY, taker), _sign(BOB_KEY, maker));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (1e18, 1e18);

        vm.startBroadcast(ORDER_SENDER_KEY);
        btc.trade(abi.encode(orders, sigs, amounts));
        vm.stopBroadcast();

        (int256 paper, int256 credit) = btc.balanceOf(alice);
        console2.log("[2] alice BTC paper ", paper);
        console2.log("    alice BTC credit", credit);
    }

    /// ③ 价格跌到 26000（MockPriceSource 谁都能改；真实系统里是预言机）
    function _stepPriceDrop() internal {
        vm.startBroadcast(CAROL_KEY);
        btcPrice.setMarkPrice(26000e6);
        vm.stopBroadcast();
        (int256 netValue,,, uint256 mm) = dealer.getTraderRisk(alice);
        console2.log("[3] alice netValue        ", netValue);
        console2.log("    alice maintenanceMargin", mm);
    }

    /// ④ 清算：carol 先用 view 算成本当价格保护，再接 alice 的 1 张多仓
    function _stepLiquidate() internal {
        (, int256 cost) = dealer.getLiquidationCost(address(btc), alice, 1e18);
        console2.log("[4] carol liquidation cost", cost);
        vm.startBroadcast(CAROL_KEY);
        btc.liquidate(carol, alice, 1e18, cost);
        vm.stopBroadcast();

        (int256 alicePaper,) = btc.balanceOf(alice);
        (int256 carolPaper, int256 carolCredit) = btc.balanceOf(carol);
        console2.log("[5] alice BTC paper     ", alicePaper);
        console2.log("    alice primaryCredit ", dealer.getPrimaryCredit(alice));
        console2.log("    carol BTC paper     ", carolPaper);
        console2.log("    carol BTC credit    ", carolCredit);
    }

    function _deposit(uint256 key, uint256 amount, bool mint) internal {
        address user = vm.addr(key);
        vm.startBroadcast(key);
        if (mint) usdc.mint(user, amount);
        usdc.approve(address(dealer), amount);
        dealer.deposit(amount, 0, user);
        vm.stopBroadcast();
    }

    /// 费率 0、永不过期；nonce 用时间戳 + 序号，重复运行也不会撞哈希
    function _order(address signer, int128 paper, int128 credit, uint64 seq) internal view returns (Types.Order memory o) {
        o.perp = address(btc);
        o.signer = signer;
        o.paperAmount = paper;
        o.creditAmount = credit;
        // 64 位 nonce 打包：expiration 放 [64,128) 位，nonce 放低 64 位；费率位全 0
        o.info = bytes32((uint256(type(uint64).max) << 64) | uint256(uint64(block.timestamp) * 10 + seq));
    }

    /// 签名的就是合约 approveTrade 里验的那个摘要：EIP712(domainSeparator, structHash)
    function _sign(uint256 key, Types.Order memory o) internal view returns (bytes memory) {
        bytes32 digest = EIP712._hashTypedDataV4(dealer.domainSeparator(), Trading._structHash(o));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
