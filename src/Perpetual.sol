// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IPerpetual} from "./interfaces/IPerpetual.sol";
import {SignedDecimalMath} from "./libraries/SignedDecimalMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IDealer} from "./interfaces/IDealer.sol";

contract Perpetual is Ownable, IPerpetual {
    using SignedDecimalMath for int256;
    int256 fundingRate;

    struct balance {
        int128 paper;
        int128 reducedCredit;
    }

    mapping(address => balance) balanceMap;

    event UpdateFundingRate(int256 oldFundingRate, int256 newFundingRate);
    event BalanceChange(address indexed trader, int256 paperChange, int256 creditChange);

    constructor(address _owner) {
        transferOwnership(_owner);
    }

    function balanceOf(address trader) external view returns (int256 paper, int256 credit) {
        paper = int256(balanceMap[trader].paper);
        credit = paper.decimalMul(fundingRate) + int256(balanceMap[trader].reducedCredit);
    }

    function trade(bytes calldata tradeData) external {
        (address[] memory traderList, int256[] memory paperChangeList, int256[] memory creditChangeList) = IDealer(owner()).approveTrade(msg.sender, tradeData);

        require(traderList.length == paperChangeList.length && traderList.length == creditChangeList.length, "LENGTH_MISMATCH");
        for (uint256 i = 0; i < traderList.length;) {
            _settle(traderList[i], paperChangeList[i], creditChangeList[i]);
            unchecked{
                i++;
            }
        }
        require(IDealer(owner()).isAllSafe(traderList), "TRADER_NOT_SAFE");
    }

    function getFundingRate() external view returns (int256) {
        return fundingRate;
    }

    function updateFundingRate(int256 newFundingRate) external onlyOwner {
        int256 oldFundingRate = fundingRate;
        fundingRate = newFundingRate;
        emit UpdateFundingRate(oldFundingRate, newFundingRate);
    }

    function _settle(address trader, int256 paperChange, int256 creditChange) internal {
        balance storage b = balanceMap[trader];
        int256 rate = fundingRate;
        int256 credit = int256(b.paper).decimalMul(rate) + int256(b.reducedCredit) + creditChange;
        bool isNewPosition = b.paper == 0;
        int128 newPaper = b.paper + SafeCast.toInt128(paperChange);
        int128 newReducedCredit = SafeCast.toInt128(credit - (int256(newPaper)).decimalMul(rate));

        b.paper = newPaper;
        b.reducedCredit = newReducedCredit;

        emit BalanceChange(trader, paperChange, creditChange);
        // 通知dealer记用户仓位
        if (isNewPosition) {
            IDealer(owner()).openPosition(trader);
        }

        if (newPaper == 0) {
            IDealer(owner()).realizePnl(trader, newReducedCredit);
            b.reducedCredit = 0;
        }
    }

    // 清算人调用
    function liquidate(address liquidator, address liquidatedTrader, int256 requestPaper, int256 expectCredit)
    external returns (int256 liqtorPaperChange, int256 liqtorCreditChange) {
        int256 liqedPaperChange;
        int256 liqedCreditChange;
        (liqtorPaperChange, liqtorCreditChange, liqedPaperChange, liqedCreditChange) = IDealer(owner()).requestLiquidation(msg.sender, liquidator, liquidatedTrader, requestPaper);

        // 价格保护，不要直接用expectCredit与liqtorCreditChange相比较，因为这个 expectCredit 是 requestPaper 的 credit，它有可能的 requestPaper 不一定全部被这个清算人吃掉，所以还是得用除法，但是除法的时候又容易丢失精度，所以要把除法转成乘法
        // 期望价格 = expectCredit / requestPaper * -1和liqtorCreditChange / liqtorPaperChange * -1，这里的负一很重要啊，它决定了这个方向，符号的方向
        if (liqtorPaperChange > 0) {
            require(expectCredit * liqtorPaperChange <= liqtorCreditChange * requestPaper, "LIQUIDATION_PRICE_PROTECTION");
        } else {
            require(expectCredit * liqtorPaperChange >= liqtorCreditChange * requestPaper, "LIQUIDATION_PRICE_PROTECTION");
        }

        _settle(liquidator, liqtorPaperChange, liqtorCreditChange);
        _settle(liquidatedTrader, liqedPaperChange, liqedCreditChange);

        require(IDealer(owner()).isIMSafe(liquidator), "LIQUIDATOR_NOT_SAFE");

        if (balanceMap[liquidatedTrader].paper == 0) {
            IDealer(owner()).handleBadDebt(liquidatedTrader);
        }
    }
}
