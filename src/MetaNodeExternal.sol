// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Position} from "./libraries/Position.sol";
import {MetaNodeStorage} from "./MetaNodeStorage.sol";
import {Liquidation} from "./libraries/Liquidation.sol";
import {Errors} from "./libraries/Errors.sol";
import {Funding} from "./libraries/Funding.sol";
import {IDealer} from "./interfaces/IDealer.sol";

abstract contract MetaNodeExternal is MetaNodeStorage, IDealer {
    function deposit(uint256 primaryAmount, uint256 secondaryAmount, address to) external nonReentrant {
        Funding.deposit(state, primaryAmount, secondaryAmount, to);
    }

    function requestWithdraw(uint256 primaryAmount, uint256 secondaryAmount) external nonReentrant {
        Funding.requestWithdraw(state, primaryAmount, secondaryAmount);
    }

    function executeWithdraw(address to) external nonReentrant {
        Funding.executeWithdraw(state, to);
    }

    function fastWithdraw(address to, uint256 primaryAmount, uint256 secondaryAmount) external nonReentrant {
        Funding.fastWithdraw(state, to, primaryAmount, secondaryAmount);
    }

    function openPosition(address trader) external onlyRegisteredPerp {
        Position._openPosition(state,trader);
    }

    function realizePnl(address trader, int256 pnl) external onlyRegisteredPerp {
        Position._realizePnl(state, trader, pnl);
    }

    function approveTrade(address orderSender, bytes calldata tradeData) external view onlyRegisteredPerp returns (address[] memory, int256[] memory, int256[] memory) {
        // 判断撮合合约是否在白名单中
        require(state.validOrderSender[orderSender], Errors.INVALID_ORDER_SENDER);

        return abi.decode(tradeData,(address[], int256[], int256[]));
    }

    function isSafe(address trader) external view returns (bool) {
        return Liquidation._isMMSafe(state, trader);
    }

    function isAllSafe(address[] calldata traderList) external view returns (bool) {
        return Liquidation._isAllMMSafe(state, traderList);
    }
}
