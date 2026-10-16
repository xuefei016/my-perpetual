// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice 最简合约钱包：只要签名是 owner 签的就认（真实多签会要求 N 个 owner 中 M 个签）
contract MockERC1271Wallet is IERC1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        (address recovered,) = ECDSA.tryRecover(hash, signature);
        return recovered == owner ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}
