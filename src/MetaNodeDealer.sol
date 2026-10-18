// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeExternal} from "./MetaNodeExternal.sol";
import {Types} from "./libraries/Types.sol";
import {Liquidation} from "./libraries/Liquidation.sol";

contract MetaNodeDealer is MetaNodeExternal {
    constructor(address _primaryAsset) {
        state.primaryAsset = _primaryAsset;
    }

    function setPerpRiskParams(address perp, Types.RiskParams calldata params) external onlyOwner {
        state.perpRiskParams[perp] = params;
    }

    function setOrderSender(address orderSender, bool isValid) external onlyOwner {
        state.validOrderSender[orderSender] = isValid;
    }

    function setMaxPositionAmount(uint256 amount) external onlyOwner {
        state.maxPositionAmount = amount;
    }

    function setWithdrawTimeLock(uint256 timeLock) external onlyOwner {
        state.withdrawTimeLock = timeLock;
    }

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
}
