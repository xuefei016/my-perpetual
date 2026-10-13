// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPriceSource} from "./interfaces/IPriceSource.sol";

contract ConstOracle is IPriceSource {
    uint256 public immutable price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getMarkPrice() external view returns (uint256 _price) {
        return price;
    }
}
