// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeStorage} from "../../src/MetaNodeStorage.sol";
import {Funding} from "../../src/libraries/Funding.sol";

/// @notice D1 测试用：持有 state 并把 Funding 库暴露成 external 函数（D2 的 MetaNodeDealer 雏形）
contract FundingHarness is MetaNodeStorage {
    constructor(address primary, address secondary, uint256 timeLock) {
        state.primaryAsset = primary;
        state.secondaryAsset = secondary;
        state.withdrawTimeLock = timeLock;
    }

    // ==================== 转发给 Funding（DELEGATECALL，msg.sender 保持为原始调用者） ====================

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

    // ==================== 查询（public state 的 getter 查不到 mapping 字段） ====================

    function primaryCredit(address user) external view returns (int256) {
        return state.primaryCredit[user];
    }
}
