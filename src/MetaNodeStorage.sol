// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Types} from "./libraries/Types.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract MetaNodeStorage is Ownable, ReentrancyGuard {
    Types.State public state;
}
