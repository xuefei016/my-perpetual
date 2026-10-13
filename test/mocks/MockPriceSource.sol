// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// @notice 测试用价格源：可以随时改价，用来模拟"价格下跌"
contract MockPriceSource {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setMarkPrice(uint256 _price) external {
        price = _price;
    }

    function getMarkPrice() external view returns (uint256) {
        return price;
    }
}
