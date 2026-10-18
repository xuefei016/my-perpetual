// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeStorage} from "./MetaNodeStorage.sol";
import {IDealer} from "./interfaces/IDealer.sol";
import {EIP712} from "./libraries/EIP712.sol";
import {Errors} from "./libraries/Errors.sol";
import {Funding} from "./libraries/Funding.sol";
import {Liquidation} from "./libraries/Liquidation.sol";
import {Position} from "./libraries/Position.sol";
import {SignedDecimalMath} from "./libraries/SignedDecimalMath.sol";
import {Trading} from "./libraries/Trading.sol";
import {Types} from "./libraries/Types.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

abstract contract MetaNodeExternal is MetaNodeStorage, IDealer {
    using SignedDecimalMath for int256;
    function deposit(uint256 primaryAmount, uint256 secondaryAmount, address to) external nonReentrant {
        Funding.deposit(state, primaryAmount, secondaryAmount, to);
    }

    function requestWithdraw(uint256 primaryAmount, uint256 secondaryAmount) external nonReentrant {
        Funding.requestWithdraw(state, primaryAmount, secondaryAmount);
    }

    function executeWithdraw(address to) external nonReentrant {
        Funding.executeWithdraw(state, to);
    }

    function fastWithdraw(address to, uint256 primaryAmount, uint256 secondaryAmount) external nonReentrant {
        Funding.fastWithdraw(state, to, primaryAmount, secondaryAmount);
    }

    function openPosition(address trader) external onlyRegisteredPerp {
        Position._openPosition(state, trader);
    }

    function realizePnl(address trader, int256 pnl) external onlyRegisteredPerp {
        Position._realizePnl(state, trader, pnl);
    }

    function approveTrade(address orderSender, bytes calldata tradeData) external onlyRegisteredPerp returns (address[] memory, int256[] memory, int256[] memory) {
        // 判断撮合合约是否在白名单中
        require(state.validOrderSender[orderSender], Errors.INVALID_ORDER_SENDER);
        (Types.Order[] memory orderList, bytes[] memory signatureList, uint256[] memory matchPaperAmount)
        = abi.decode(tradeData, (Types.Order[], bytes[], uint256[]));
        bytes32[] memory orderHashList = new bytes32[](orderList.length);
        for (uint256 i = 0; i < orderList.length;) {
            Types.Order memory order = orderList[i];
            bytes32 orderHash = EIP712._hashTypedDataV4(domainSeparator, Trading._structHash(order));
            orderHashList[i] = orderHash;
            // 验签，三种身份都算合法
            (address recoverSigner,) = ECDSA.tryRecover(orderHash, signatureList[i]);
            if (recoverSigner != order.signer && !state.operatorRegistry[order.signer][recoverSigner]) {
                if (Address.isContract(order.signer)) {
                    require(IERC1271(order.signer).isValidSignature(orderHash, signatureList[i]) == 0x1626ba7e, Errors.INVALID_ORDER_SIGNATURE);
                } else {
                    revert(Errors.INVALID_ORDER_SIGNATURE);
                }
            }

            // 没过期
            // 订单过期以秒计，验证者只能把时间戳挪几秒，可接受
            // forge-lint: disable-next-line(block-timestamp)
            require(Trading._info2Expiration(order.info) >= block.timestamp, Errors.ORDER_EXPIRED);
            // paper 和 credit 必须异号
            require(
                (order.paperAmount < 0 && order.creditAmount > 0) || (order.paperAmount > 0 && order.creditAmount < 0),
                Errors.ORDER_PRICE_NEGATIVE
            );
            // 这张单属于当前这个市场
            require(order.perp == msg.sender, Errors.PERP_MISMATCH);
            // 不能自成交
            if (i > 0) {
                require(order.signer != orderList[0].signer, Errors.ORDER_SELF_MATCH);
            }

            // 防超额成交
            state.orderFilledPaperAmount[orderHash] += matchPaperAmount[i];
            require(state.orderFilledPaperAmount[orderHash] <= int256(orderList[i].paperAmount).abs(), Errors.ORDER_FILLED_OVERFLOW);
            unchecked{
                ++i;
            }
        }

        Types.MatchResult memory matchResult = Trading._matchOrders(state, orderHashList, orderList, matchPaperAmount);
        state.primaryCredit[orderSender] += matchResult.orderSenderFee;
        // <0代表是补贴，确定保证金足够补贴
        if (matchResult.orderSenderFee < 0) {
            require(Liquidation._isSolidIMSafe(state, orderSender), Errors.ORDER_SENDER_NOT_SAFE);
        }


        return (matchResult.traderList, matchResult.paperChangeList, matchResult.creditChangeList);
    }

    function isSafe(address trader) external view returns (bool) {
        return Liquidation._isMMSafe(state, trader);
    }

    function isAllSafe(address[] calldata traderList) external view returns (bool) {
        return Liquidation._isAllMMSafe(state, traderList);
    }

    function setOperator(address operator, bool isValid) external {
        state.operatorRegistry[msg.sender][operator] = isValid;
    }

    function setInsurance(address _insurance) external onlyOwner {
        state.insurance = _insurance;
    }

    function requestLiquidation(address executor, address liquidator, address liquidatedTrader, int256 requestPaperAmount) external onlyRegisteredPerp returns (int256 liqtorPaperChange, int256 liqtorCreditChange, int256 liqedPaperChange, int256 liqedCreditChange) {
        return Liquidation.requestLiquidation(state, msg.sender, executor, liquidator, liquidatedTrader, requestPaperAmount);
    }

    function isIMSafe(address trader) external view returns (bool) {
        return Liquidation._isIMSafe(state, trader);
    }

    function handleBadDebt(address liquidatedTrader) external {
        Liquidation.handleBadDebt(state, liquidatedTrader);
    }
}
