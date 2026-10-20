// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Liquidation} from "./libraries/Liquidation.sol";
import {MetaNodeStorage} from "./MetaNodeStorage.sol";
import {Types} from "./libraries/Types.sol";

abstract contract MetaNodeView is MetaNodeStorage {
    function getPositions(address trader) external view returns (address[] memory) {
        return state.openPositions[trader];
    }

    function getPrimaryCredit(address trader) external view returns (int256) {
        return state.primaryCredit[trader];
    }

    function getTraderRisk(address trader) external view returns (int256 netValue, uint256 exposure, uint256 initialMargin, uint256 maintenanceMargin) {
        return Liquidation.getTotalExposure(state, trader);
    }

    function getLiquidationPrice(address trader, address perp) external view returns (uint256) {
        return Liquidation.getLiquidationPrice(state, trader, perp);
    }

    function getLiquidationCost(address perp, address liquidatedTrader, int256 requestPaperAmount)
    external view returns (int256 liqtorPaperChange, int256 liqtorCreditChange) {
        (liqtorPaperChange, liqtorCreditChange,) = Liquidation.getLiquidateCreditAmount(state, perp, liquidatedTrader, requestPaperAmount);
    }

    function getOrderFilledAmount(bytes32 orderHash) external view returns (uint256) {
        return state.orderFilledPaperAmount[orderHash];
    }

    function isOperatorValid(address client, address operator) external view returns (bool) {
        return state.operatorRegistry[client][operator];
    }

    function getRiskParams(address perp) external view returns (Types.RiskParams memory) {
        return state.perpRiskParams[perp];
    }
}
