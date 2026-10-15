// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

library Errors {
    string constant WITHDRAW_PENDING = "META_WITHDRAW_PENDING";
    string constant WITHDRAW_INVALID = "META_WITHDRAW_INVALID";
    string constant FAST_WITHDRAW_NOT_ALLOWED = "META_FAST_WITHDRAW_NOT_ALLOWED";
    string constant ACCOUNT_NOT_SAFE = "META_ACCOUNT_NOT_SAFE";

    string constant PERP_NOT_REGISTERED = "META_PERP_NOT_REGISTERED";
    string constant POSITION_AMOUNT_REACH_UPPER_LIMIT = "META_POSITION_AMOUNT_REACH_UPPER_LIMIT";
    string constant INVALID_ORDER_SENDER = "META_INVALID_ORDER_SENDER";

    string constant ORDER_PRICE_NOT_MATCH = "META_ORDER_PRICE_NOT_MATCH";
    /// @notice 交易者数量不足（至少需要2个）
    string constant INVALID_TRADER_NUMBER = "META_AT_LEAST_TWO_TRADERS";
    /// @notice 订单排序错误（maker 订单应按地址升序排列）
    string constant ORDER_WRONG_SORTING = "META_ORDER_WRONG_SORTING";
    /// @notice Taker 成交数量错误
    string constant TAKER_TRADE_AMOUNT_WRONG = "META_TAKER_TRADE_AMOUNT_WRONG";
}
