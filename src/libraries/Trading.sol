// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Errors} from "./Errors.sol";
import {SignedDecimalMath} from "./SignedDecimalMath.sol";
import {Types} from "./Types.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

library Trading {
    using SignedDecimalMath for int256;
    using SignedDecimalMath for uint256;

    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed trader,
        address indexed perp,
        int256 orderFilledPaperAmount,
        int256 filledCreditAmount,
        uint256 positionSerialNum,
        int256 fee
    );

    function _structHash(Types.Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(Types.ORDER_TYPEHASH, order.perp, order.signer, order.paperAmount, order.creditAmount, order.info));
    }

    function _info2MakerFeeRate(bytes32 info) internal pure returns (int256) {
        return int256(int64(uint64(uint256(info) >> 192)));
    }

    function _info2TakerFeeRate(bytes32 info) internal pure returns (int256) {
        return int256(int64(uint64(uint256(info) >> 128)));
    }

    function _info2Expiration(bytes32 info) internal pure returns (uint256)  {
        return uint256(uint64(uint256(info) >> 64));
    }

    function _priceMatchCheck(Types.Order memory takerOrder, Types.Order memory makerOrder) internal pure {
        int256 temp1 = int256(takerOrder.paperAmount) * int256(makerOrder.creditAmount);
        int256 temp2 = int256(makerOrder.paperAmount) * int256(takerOrder.creditAmount);

        // take做多-买
        if (takerOrder.paperAmount > 0) {
            require(makerOrder.paperAmount < 0, Errors.ORDER_PRICE_NOT_MATCH);
            require(temp1 <= temp2, Errors.ORDER_PRICE_NOT_MATCH);
        } else { // take做空-卖
            require(makerOrder.paperAmount > 0, Errors.ORDER_PRICE_NOT_MATCH);
            require(temp2 <= temp1, Errors.ORDER_PRICE_NOT_MATCH);
        }
    }

    function _matchOrders(
        Types.State storage state,          // 5b 用：读 positionSerialNum，放进事件
        bytes32[] memory orderHashList,     // 5b/5c 用：事件里标明是哪张单成交了
        Types.Order[] memory orderList,     // [0] 是 taker，[1..] 是 maker
        uint256[] memory matchPaperAmount   // 每张单这次成交多少，取绝对值，和 orderList 一一对应
    ) internal returns (Types.MatchResult memory result) {
        {
            require(orderList.length >= 2, Errors.INVALID_TRADER_NUMBER);
            uint256 uniqueTraderNum = 2;
            uint256 totalMakerPaper = matchPaperAmount[1];
            for (uint256 i = 2; i < orderList.length;) {
                totalMakerPaper += matchPaperAmount[i];
                if (orderList[i - 1].signer < orderList[i].signer) {
                    uniqueTraderNum += 1;
                } else {
                    require(orderList[i - 1].signer == orderList[i].signer, Errors.ORDER_WRONG_SORTING);
                }
                unchecked {
                    ++i;
                }
            }

            require(matchPaperAmount[0] == totalMakerPaper, Errors.TAKER_TRADE_AMOUNT_WRONG);

            result.traderList = new address[](uniqueTraderNum);
            result.paperChangeList = new int256[](uniqueTraderNum);
            result.creditChangeList = new int256[](uniqueTraderNum);
            result.traderList[0] = orderList[0].signer;
//            result.paperChangeList[0] = orderList[0].paperAmount > 0
//                ? SafeCast.toInt256(matchPaperAmount[0])
//                : - 1 * SafeCast.toInt256(matchPaperAmount[0]);
            // 这是个大坑，taker的价格要有maker决定，不是他自己决定的
//            result.creditChangeList[0] = result.paperChangeList[0] * orderList[0].creditAmount / orderList[0].paperAmount;
        }
        {
            uint256 resultUniqueIndex = 0;
            for (uint256 i = 1; i < orderList.length;) {
                _priceMatchCheck(orderList[0], orderList[i]);

                int256 paperChange = orderList[i].paperAmount > 0
                    ? SafeCast.toInt256(matchPaperAmount[i])
                    : - 1 * SafeCast.toInt256(matchPaperAmount[i]);

                int256 creditChange = paperChange * orderList[i].creditAmount / orderList[i].paperAmount;
                int256 fee = SafeCast.toInt256(creditChange.abs()).decimalMul(_info2MakerFeeRate(orderList[i].info));
                if (i >= 2 && orderList[i].signer == orderList[i - 1].signer) {
                    result.paperChangeList[resultUniqueIndex] += paperChange;
                    result.creditChangeList[resultUniqueIndex] += (creditChange - fee);
                } else {
                    resultUniqueIndex += 1;
                    result.paperChangeList[resultUniqueIndex] = paperChange;
                    result.creditChangeList[resultUniqueIndex] = (creditChange - fee);
                    result.traderList[resultUniqueIndex] = orderList[i].signer;
                }
                result.orderSenderFee += fee;

                result.paperChangeList[0] -= paperChange;
                result.creditChangeList[0] -= creditChange;

                emit OrderFilled(
                    orderHashList[i], orderList[i].signer, msg.sender, paperChange,
                    creditChange - fee, state.positionSerialNum[orderList[i].signer][msg.sender], fee
                );
                unchecked {
                    ++i;
                }
            }
        }

        {
            int256 takerFee = SafeCast.toInt256(result.creditChangeList[0].abs()).decimalMul(_info2TakerFeeRate(orderList[0].info));
            result.creditChangeList[0] -= takerFee;
            result.orderSenderFee += takerFee;
            emit OrderFilled(
                orderHashList[0], orderList[0].signer, msg.sender, result.paperChangeList[0],
                result.creditChangeList[0], state.positionSerialNum[orderList[0].signer][msg.sender], takerFee
            );
        }
    }


}
