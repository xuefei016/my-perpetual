// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPerpetual} from "../interfaces/IPerpetual.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {SignedDecimalMath} from "./SignedDecimalMath.sol";
import {Types} from "./Types.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library Liquidation {
    using SignedDecimalMath for int256;

    function getTotalExposure(Types.State storage state, address trader) public view returns (int256 netValue, uint256 exposure, uint256 initialMargin, uint256 maintenanceMargin) {
        address[] storage positionList = state.openPositions[trader];
        int256 netPositionValue;
        for (uint256 i = 0; i < positionList.length;) {
            address position = positionList[i];
            (int256 paper, int256 credit) = IPerpetual(position).balanceOf(trader);
            Types.RiskParams storage params = state.perpRiskParams[position];
            uint256 markPrice = IPriceSource(params.markPriceSource).getMarkPrice();
            netPositionValue += (paper.decimalMul(SafeCast.toInt256(markPrice))) + credit;
            uint256 exposureChange = paper.decimalMul(SafeCast.toInt256(markPrice)).abs();
            exposure += exposureChange;
            initialMargin += (exposureChange * params.initialMarginRatio) / Types.ONE;
            maintenanceMargin += (exposureChange * params.liquidationThreshold) / Types.ONE;
            unchecked {
                ++i;
            }
        }

        netValue = netPositionValue + state.primaryCredit[trader] + SafeCast.toInt256(state.secondaryCredit[trader]);
    }

    function _isMMSafe(Types.State storage state, address trader) internal view returns (bool){
        (int256 netValue,,,uint256 maintenanceMargin) = getTotalExposure(state, trader);
        return netValue >= SafeCast.toInt256(maintenanceMargin);
    }

    function _isIMSafe(Types.State storage state, address trader) internal view returns (bool){
        (int256 netValue,,uint256 initialMargin,) = getTotalExposure(state, trader);
        return netValue >= SafeCast.toInt256(initialMargin);
    }

    function _isAllMMSafe(Types.State storage state, address[] calldata traderList) internal view returns (bool){
        for (uint256 i = 0; i < traderList.length;) {
            address trade = traderList[i];
            bool isMMSafe = _isMMSafe(state, trade);
            if (!isMMSafe) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function _isSolidIMSafe(Types.State storage state, address trader) internal view returns (bool){
        (int256 netValue,,uint256 initialMargin,) = getTotalExposure(state, trader);
        return netValue - SafeCast.toInt256(state.secondaryCredit[trader]) >= 0 && netValue >= SafeCast.toInt256(initialMargin);
    }
}
