// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Types} from "../../src/libraries/Types.sol";

/// @notice 订单签名相关的测试辅助（D3）
/// 这里的哈希全部按 EIP-712 规范**独立重算**，不调用 src 里的 EIP712 / Trading 库：
/// 如果合约侧的 domainSeparator 或 structHash 写错一个字节，vm.sign 签出来的签名在链上就恢复不出 signer，测试会失败
abstract contract EIP712Test is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TEST_ORDER_TYPEHASH =
        keccak256("Order(address perp,address signer,int128 paperAmount,int128 creditAmount,bytes32 info)");

    /// 按 Types.Order.info 的布局打包：makerFeeRate | takerFeeRate | expiration | nonce（高位 → 低位，各 64 位）
    /// 费率是有符号数：先转成同宽的 uint64 取补码位，再放进 uint256 移位，避免负数符号扩展污染高位
    function _packInfo(int64 makerFeeRate, int64 takerFeeRate, uint64 expiration, uint64 nonce)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            // int64 → uint64 同宽转换只是按补码重新解读位，正是这里要的效果，不会丢数据
            // forge-lint: disable-next-line(unsafe-typecast)
            (uint256(uint64(makerFeeRate)) << 192) | (uint256(uint64(takerFeeRate)) << 128)
                | (uint256(expiration) << 64) | uint256(nonce)
        );
    }

    /// 链下视角的 domainSeparator：name "MetaNode"，version "1"，当前链，验证合约 = Dealer
    function _domainSeparator(address dealer) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("MetaNode"), keccak256("1"), block.chainid, dealer));
    }

    /// 链下视角的订单摘要：keccak256("\x19\x01" ‖ domainSeparator ‖ structHash)，钱包实际签的就是它
    function _orderDigest(address dealer, Types.Order memory o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(TEST_ORDER_TYPEHASH, o.perp, o.signer, o.paperAmount, o.creditAmount, o.info)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(dealer), structHash));
    }

    /// 用私钥签订单，返回 65 字节签名 r ‖ s ‖ v（ECDSA.tryRecover 接受的格式）
    function _signOrder(uint256 privateKey, address dealer, Types.Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, _orderDigest(dealer, o));
        return abi.encodePacked(r, s, v);
    }
}
