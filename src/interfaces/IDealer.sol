// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IDealer {
    function approveTrade(address orderSender, bytes calldata tradeData)
    external returns (address[] memory traderList, int256[] memory paperChangeList, int256[] memory creditChangeList);

    function isAllSafe(address[] calldata traderList) external view returns (bool);

    function openPosition(address trader) external;

    function realizePnl(address trader, int256 pnl) external;

    function requestLiquidation(
        address executor,
        address liquidator,
        address liquidatedTrader,
        int256 requestPaperAmount
    ) external returns (int256 liqtorPaperChange, int256 liqtorCreditChange, int256 liqedPaperChange, int256 liqedCreditChange);

    function isIMSafe(address trader) external view returns (bool);

    function handleBadDebt(address liquidatedTrader) external;
}
