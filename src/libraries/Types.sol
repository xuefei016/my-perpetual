// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

library Types {
    uint256 constant ONE = 1e18;

    struct Order {
        address perp;
        address signer;
        int128 paperAmount;
        int128 creditAmount;
        bytes32 info; // MakerFeeRate|TakerFeeRate|Expiration|nonce
    }

    struct State {
        address primaryAsset;
        address secondaryAsset;
        mapping(address => int256) primaryCredit;
        mapping(address => uint256) secondaryCredit;
        uint256 withdrawTimeLock;
        mapping(address => uint256) pendingPrimaryWithdraw;
        mapping(address => uint256) pendingSecondaryWithdraw;
        mapping(address => uint256) withdrawExecutionTimestamp;
        mapping(address => bool) fastWithdrawalWhitelist;
        bool fastWithdrawDisabled;

        mapping(address => RiskParams) perpRiskParams; // [BTC永续地址] = {10%, 5%, ..., 已注册}
        mapping(address => address[]) openPositions; // [alice] = [BTC永续地址], alice 在哪些市场有仓位
        mapping(address => mapping(address => uint256)) positionSerialNum; // [alice][BTC永续地址] = 0 记录平仓的数量
        uint256 maxPositionAmount; // 比如 10，限制每个人最多有多少个仓位
        mapping(address => bool) validOrderSender; //[撮合引擎地址] = true，谁有资格去调 trade，其实存的就是撮合地址
        mapping(bytes32 => uint256) orderFilledPaperAmount; // 记录每一笔订单对应的撮合成功的paper数量
        mapping(address => mapping(address => bool)) operatorRegistry; // 记录用户授权机器人帮他发布订单
    }

    /**
     * 有这么一个场景：他有保证金大概是 5000，然后做多 1 个 BTC，成交价是 3 万。
     */
    struct RiskParams {
        uint256 initialMarginRatio; // 开仓门槛，它的净值就需要大于等于 3 万 × 10%（也就是 3000）。所以它的 5000 大于 3000，它是可以开仓的，可以开这个 3 万的 1 个 BTC
        uint256 liquidationThreshold; // 清算线，但是当 BTC 的价格从 3 万跌到 26,000 的时候，它本身就亏了 4,000，所以 5,000 减去 4,000 等于 1,000。然后我再用当前的价格 26,000 乘以清算线（比如 5%），26,000 × 5% 约等于 1,300。如果这个 1,300 大于它的这个 1,000 的话，需要触发清算了。
        uint256 liquidationPriceOff; // 清算人接手仓位能拿的折扣（按标记价打 99 折买），是给清算人的激励，这个是给清算人的
        uint256 insuranceFeeRate; // 被清算时额外扣一笔交给保险账户，用来以后填坏账，这个相当于是给协议的
        address markPriceSource; // 这个相当于就是币价的合约地址，你从哪个合约地址里获取币价
        string name; // "BTC-USDC"	纯展示，给前端和后端看
        bool isRegistered; // 这个 Perpetual 是不是被管理员登记过的正规市场
    }

    bytes32 constant ORDER_TYPEHASH =
    keccak256("Order(address perp,address signer,int128 paperAmount,int128 creditAmount,bytes32 info)");

    struct MatchResult {
        address[] traderList;
        int256[] paperChangeList;
        int256[] creditChangeList;
        int256 orderSenderFee;
    }



}
