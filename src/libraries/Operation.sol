// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPerpetual} from "../interfaces/IPerpetual.sol";
import {Errors} from "./Errors.sol";
import {Types} from "./Types.sol";

library Operation {
    event UpdatePerpRiskParams(address indexed perp, Types.RiskParams params);
    event SetInsurance(address oldInsurance, address newInsurance);
    event SetOrderSender(address orderSender, bool isValid);
    event SetMaxPositionAmount(uint256 oldMaxPositionAmount, uint256 newMaxPositionAmount);
    event SetWithdrawTimeLock(uint256 oldWithdrawTimeLock, uint256 newWithdrawTimeLock);
    event SetFundingRateKeeper(address oldKeeper, address newKeeper);
    event UpdateFundingRate(address indexed perp, int256 oldRate, int256 newRate);

    function setPerpRiskParams(Types.State storage state, address perp, Types.RiskParams calldata newParams) external {
        // 折扣 + 保险费 > MM 时，清算这个动作本身就会把被清算人打穿仓
        require(newParams.liquidationPriceOff + newParams.insuranceFeeRate <= newParams.liquidationThreshold, Errors.INVALID_RISK_PARAM);
        state.perpRiskParams[perp] = newParams;
        emit UpdatePerpRiskParams(perp, newParams);
    }

    function setOrderSender(Types.State storage state, address orderSender, bool isValid) external {
        state.validOrderSender[orderSender] = isValid;
        emit SetOrderSender(orderSender, isValid);
    }

    function setMaxPositionAmount(Types.State storage state, uint256 newMaxPositionAmount) external {
        uint256 oldMaxPositionAmount = state.maxPositionAmount;
        state.maxPositionAmount = newMaxPositionAmount;
        emit SetMaxPositionAmount(oldMaxPositionAmount, newMaxPositionAmount);
    }

    function setWithdrawTimeLock(Types.State storage state, uint256 newTimeLock) external {
        uint256 oldTimeLock = state.withdrawTimeLock;
        state.withdrawTimeLock = newTimeLock;
        emit SetWithdrawTimeLock(oldTimeLock, newTimeLock);
    }

    function setInsurance(Types.State storage state, address newInsurance) external {
        address oldInsurance = state.insurance;
        state.insurance = newInsurance;
        emit SetInsurance(oldInsurance, newInsurance);
    }

    function setFundingRateKeeper(Types.State storage state, address newKeeper) external {
        address oldKeeper = state.fundingRateKeeper;
        state.fundingRateKeeper = newKeeper;
        emit SetFundingRateKeeper(oldKeeper, newKeeper);
    }

    function updateFundingRate(address[] calldata perpList, int256[] calldata rateList) external {
        require(perpList.length == rateList.length, Errors.ARRAY_LENGTH_NOT_SAME);
        for (uint256 i = 0; i < perpList.length;) {
            int256 oldRate = IPerpetual(perpList[i]).getFundingRate();
            IPerpetual(perpList[i]).updateFundingRate(rateList[i]);
            emit UpdateFundingRate(perpList[i], oldRate, rateList[i]);
            unchecked {
                ++i;
            }
        }
    }
}
