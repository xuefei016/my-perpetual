// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {EIP712} from "./libraries/EIP712.sol";
import {Errors} from "./libraries/Errors.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Types} from "./libraries/Types.sol";

abstract contract MetaNodeStorage is Ownable, ReentrancyGuard {
    bytes32 public immutable domainSeparator;
    constructor() {
        domainSeparator = EIP712._buildDomainSeparator("MetaNode", "1", address(this));
    }

    Types.State public state;
    modifier onlyRegisteredPerp() {
        require(state.perpRiskParams[msg.sender].isRegistered, Errors.PERP_NOT_REGISTERED);
        _;
    }

    modifier onlyFundingRateKeeper() {
        require(state.fundingRateKeeper == msg.sender, Errors.INVALID_FUNDING_RATE_KEEPER);
        _;
    }
}
