// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IDealer {
    function approveTrade(address orderSender, bytes calldata tradeData)
    external returns (address[] memory traderList, int256[] memory paperChangeList, int256[] memory creditChangeList);

    function isAllSafe(address[] calldata traderList) external view returns (bool);

    function openPosition(address trader) external;

    function realizePnl(address trader, int256 pnl) external;
}
