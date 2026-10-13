// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IPriceSource {
    function getMarkPrice() external view returns (uint256 price);
}
