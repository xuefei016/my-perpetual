// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPerpetual} from "../interfaces/IPerpetual.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {SignedDecimalMath} from "./SignedDecimalMath.sol";
import {Types} from "./Types.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "./Errors.sol";

library Liquidation {
    using SignedDecimalMath for int256;
    using SignedDecimalMath for uint256;

    /// @notice 被清算事件
    /// @param perp 永续合约地址
    /// @param liquidatedTrader 被清算者
    /// @param paperChange paper 变化
    /// @param creditChange credit 变化
    /// @param positionSerialNum 仓位序列号
    event BeingLiquidated(
        address indexed perp,
        address indexed liquidatedTrader,
        int256 paperChange,
        int256 creditChange,
        uint256 positionSerialNum
    );

    /// @notice 执行清算事件
    /// @param perp 永续合约地址
    /// @param liquidator 清算者
    /// @param liquidatedTrader 被清算者
    /// @param paperChange 清算者的 paper 变化
    /// @param creditChange 清算者的 credit 变化
    /// @param positionSerialNum 仓位序列号
    event JoinLiquidation(
        address indexed perp,
        address indexed liquidator,
        address indexed liquidatedTrader,
        int256 paperChange,
        int256 creditChange,
        uint256 positionSerialNum
    );

    /// @notice 收取保险费事件
    /// @param perp 永续合约地址
    /// @param liquidatedTrader 被清算者
    /// @param fee 保险费金额
    event ChargeInsurance(address indexed perp, address indexed liquidatedTrader, uint256 fee);

    /// @notice 处理坏账事件
    /// @param liquidatedTrader 被清算者
    /// @param primaryCredit 主资产余额（负数表示坏账）
    /// @param secondaryCredit 次级资产余额
    event HandleBadDebt(address indexed liquidatedTrader, int256 primaryCredit, uint256 secondaryCredit);

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

    function getLiquidateCreditAmount(
        Types.State storage state,
        address perp,
        address liquidatedTrader,
        int256 requestPaperAmount
    ) public view returns (int256 liqtorPaperChange, int256 liqtorCreditChange, uint256 insuranceFee) {
        require(!_isMMSafe(state, liquidatedTrader), Errors.ACCOUNT_IS_SAFE);
        (int256 paper,) = IPerpetual(perp).balanceOf(liquidatedTrader);
        require(paper.abs() > 0, Errors.TRADER_HAS_NO_POSITION);
        require(paper * requestPaperAmount > 0, Errors.LIQUIDATION_REQUEST_AMOUNT_WRONG);
        liqtorPaperChange = requestPaperAmount.abs() > paper.abs() ? paper : requestPaperAmount;
        Types.RiskParams storage params = state.perpRiskParams[perp];

        // 一个坑，只考虑了多单的清算，没考虑空单的清算。
        //多单清算相当于我作为清算人要买他的 BTC，所以我买得便宜才有得赚；对于空单的空头，相当于我卖他的 BTC，我肯定要卖得多、卖得贵才有得赚，对吧？所以是要加上它的 price off
        uint256 multiplier = liqtorPaperChange > 0 ? Types.ONE - params.liquidationPriceOff : Types.ONE + params.liquidationPriceOff;
        uint256 markPrice = IPriceSource(params.markPriceSource).getMarkPrice();
        uint256 liquidationPrice = markPrice.decimalMul(multiplier);
        liqtorCreditChange = (- 1) * liqtorPaperChange.decimalMul(SafeCast.toInt256(liquidationPrice));
        insuranceFee = liqtorCreditChange.abs().decimalMul(params.insuranceFeeRate);
    }

    function requestLiquidation(
        Types.State storage state,
        address perp,
        address executor,
        address liquidator,
        address liquidatedTrader,
        int256 requestPaperAmount
    ) external returns (int256 liqtorPaperChange, int256 liqtorCreditChange, int256 liqedPaperChange, int256 liqedCreditChange) {
        require(executor == liquidator || state.operatorRegistry[liquidator][executor], Errors.INVALID_LIQUIDATION_EXECUTOR);
        require(liquidatedTrader != liquidator, Errors.SELF_LIQUIDATION_NOT_ALLOWED);

        uint256 insuranceFee;
        (liqtorPaperChange, liqtorCreditChange, insuranceFee) = getLiquidateCreditAmount(state, perp, liquidatedTrader, requestPaperAmount);
        state.primaryCredit[state.insurance] += SafeCast.toInt256(insuranceFee);

        liqedPaperChange = liqtorPaperChange * - 1;
        liqedCreditChange = liqtorCreditChange * - 1 - SafeCast.toInt256(insuranceFee);

        uint256 ltSN = state.positionSerialNum[liquidatedTrader][perp];
        uint256 liquidatorSN = state.positionSerialNum[liquidator][perp];
        emit BeingLiquidated(perp, liquidatedTrader, liqedPaperChange, liqedCreditChange, ltSN);
        emit JoinLiquidation(perp, liquidator, liquidatedTrader, liqtorPaperChange, liqtorCreditChange, liquidatorSN);
        emit ChargeInsurance(perp, liquidatedTrader, insuranceFee);
    }

    function handleBadDebt(Types.State storage state, address liquidatedTrader) external {
        if (state.openPositions[liquidatedTrader].length == 0 && !Liquidation._isMMSafe(state, liquidatedTrader)) {
            int256 primaryCredit = state.primaryCredit[liquidatedTrader];
            uint256 secondCredit = state.secondaryCredit[liquidatedTrader];

            state.primaryCredit[liquidatedTrader] = 0;
            state.secondaryCredit[liquidatedTrader] = 0;

            state.primaryCredit[state.insurance] += primaryCredit;
            state.secondaryCredit[state.insurance] += secondCredit;

            emit HandleBadDebt(liquidatedTrader, primaryCredit, secondCredit);
        }
    }

    function getLiquidationPrice(Types.State storage state, address trader, address perp) external view returns (uint256 liquidationPrice) {
        int256 nv = state.primaryCredit[trader] + SafeCast.toInt256(state.secondaryCredit[trader]);
        int256 mm;
        for (uint256 i = 0; i < state.openPositions[trader].length;) {
            address p = state.openPositions[trader][i];
            if (p != perp) {
                (int256 paper, int256 credit) = IPerpetual(p).balanceOf(trader);
                uint256 markPrice = IPriceSource(state.perpRiskParams[p].markPriceSource).getMarkPrice();
                nv += paper.decimalMul(SafeCast.toInt256(markPrice)) + credit;
                mm += SafeCast.toInt256(paper.abs().decimalMul(markPrice).decimalMul(state.perpRiskParams[p].liquidationThreshold));
            }

            unchecked {
                ++i;
            }
        }

        (int256 paperAmount, int256 creditAmount) = IPerpetual(perp).balanceOf(trader);
        if (paperAmount == 0) {
            return 0;
        }
        // 就是当做多的时候，相当于它跌破这个会被清算；然后如果做空的话，它应该是涨破这个会被清算，所以一个减一个加
        int256 multiplier = paperAmount > 0
            ? SafeCast.toInt256(Types.ONE - state.perpRiskParams[perp].liquidationThreshold)
            : SafeCast.toInt256(Types.ONE + state.perpRiskParams[perp].liquidationThreshold);

        int256 liqPrice = (mm - nv - creditAmount).decimalDiv(paperAmount).decimalDiv(multiplier);
        return liqPrice < 0 ? 0 : SafeCast.toUint256(liqPrice);
    }
}
