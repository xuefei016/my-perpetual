// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IPerpetual {
    function balanceOf(address trader) external view returns (int256 paper, int256 credit);

    function trade(bytes calldata tradeData) external;

    function getFundingRate() external view returns (int256);

    function updateFundingRate(int256 newFundingRate) external;

    function liquidate(address liquidator, address liquidatedTrader, int256 requestPaper, int256 expectCredit)
    external returns (int256 liqtorPaperChange, int256 liqtorCreditChange);
}
