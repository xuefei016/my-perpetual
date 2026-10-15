// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

/// @notice 订单签名相关的测试辅助（D3）
abstract contract EIP712Test is Test {
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
}
