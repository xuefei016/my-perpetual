// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Errors} from "./libraries/Errors.sol";
import {Types} from "./libraries/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract MetaNodeStorage is Ownable, ReentrancyGuard {
    Types.State public state;
    modifier onlyRegisteredPerp() {
        require(state.perpRiskParams[msg.sender].isRegistered, Errors.PERP_NOT_REGISTERED);
        _;
    }
}
