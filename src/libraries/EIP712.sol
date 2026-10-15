// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library EIP712 {
    // 防止被其他合约，链，用相同的签名重放
    function _buildDomainSeparator(string memory _name, string memory _version, address verifyContract) internal view returns(bytes32) {
        bytes32 hashedName = keccak256(bytes(_name));
        bytes32 hashedVersion = keccak256(bytes(_version));
        bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        return keccak256(abi.encode(typeHash, hashedName, hashedVersion, block.chainid, verifyContract));
    }

    // orderHash，也是用户私钥需要签的内容
    function _hashTypedDataV4(bytes32 domainSeparator, bytes32 structHash) internal pure returns(bytes32) {
        return ECDSA.toTypedDataHash(domainSeparator, structHash);
    }
}
