// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

library Types {
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
    }
}
