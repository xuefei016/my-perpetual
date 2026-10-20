// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeStorage} from "./MetaNodeStorage.sol";
import {Operation} from "./libraries/Operation.sol";
import {Types} from "./libraries/Types.sol";

abstract contract MetaNodeOperation is MetaNodeStorage {
    function setPerpRiskParams(address perp, Types.RiskParams calldata params) external onlyOwner {
        Operation.setPerpRiskParams(state, perp, params);
    }

    function setOrderSender(address orderSender, bool isValid) external onlyOwner {
        Operation.setOrderSender(state, orderSender, isValid);
    }

    function setMaxPositionAmount(uint256 amount) external onlyOwner {
        Operation.setMaxPositionAmount(state, amount);
    }

    function setWithdrawTimeLock(uint256 timeLock) external onlyOwner {
        Operation.setWithdrawTimeLock(state, timeLock);
    }

    function setInsurance(address _insurance) external onlyOwner {
        Operation.setInsurance(state, _insurance);
    }

    function setFundingRateKeeper(address newKeeper) external onlyOwner {
        Operation.setFundingRateKeeper(state, newKeeper);
    }

    function updateFundingRate(address[] calldata perpList, int256[] calldata rateList) external onlyFundingRateKeeper {
        Operation.updateFundingRate(perpList, rateList);
    }
}
