// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Errors} from "./Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Liquidation} from "./Liquidation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Types} from "./Types.sol";

library Funding {
    using SafeERC20 for IERC20;

    event Deposit(address indexed to, address indexed payer, uint256 primaryAmount, uint256 secondaryAmount);
    event RequestWithdraw(address indexed payer, uint256 primaryAmount, uint256 secondaryAmount, uint256 executionTimestamp);
    event Withdraw(address indexed to, address indexed payer, uint256 primaryAmount, uint256 secondaryAmount);

    function deposit(Types.State storage state, uint256 primaryAmount, uint256 secondaryAmount, address to) external {
        if (primaryAmount > 0) {
            IERC20(state.primaryAsset).safeTransferFrom(msg.sender, address(this), primaryAmount);
            state.primaryCredit[to] += SafeCast.toInt256(primaryAmount);
        }
        if (secondaryAmount > 0) {
            IERC20(state.secondaryAsset).safeTransferFrom(msg.sender, address(this), secondaryAmount);
            state.secondaryCredit[to] += secondaryAmount;
        }
        emit Deposit(to, msg.sender, primaryAmount, secondaryAmount);
    }

    function requestWithdraw(Types.State storage state, uint256 primaryAmount, uint256 secondaryAmount) external {
        state.pendingPrimaryWithdraw[msg.sender] = primaryAmount;
        state.pendingSecondaryWithdraw[msg.sender] = secondaryAmount;
        state.withdrawExecutionTimestamp[msg.sender] = state.withdrawTimeLock + block.timestamp;
        emit RequestWithdraw(msg.sender, primaryAmount, secondaryAmount, state.withdrawExecutionTimestamp[msg.sender]);
    }

    function executeWithdraw(Types.State storage state, address to) external {
        // 时间锁以分钟计，验证者几秒的时间戳偏差可忽略
        // forge-lint: disable-next-line(block-timestamp)
        require(state.withdrawExecutionTimestamp[msg.sender] <= block.timestamp, Errors.WITHDRAW_PENDING);
        uint256 pendingPrimaryWithdraw = state.pendingPrimaryWithdraw[msg.sender];
        uint256 pendingSecondaryWithdraw = state.pendingSecondaryWithdraw[msg.sender];
        state.pendingPrimaryWithdraw[msg.sender] = 0;
        state.pendingSecondaryWithdraw[msg.sender] = 0;

        _withdraw(state, msg.sender, to, pendingPrimaryWithdraw, pendingSecondaryWithdraw);
    }

    function fastWithdraw(Types.State storage state, address to, uint256 primaryAmount, uint256 secondaryAmount) external {
        require(!state.fastWithdrawDisabled || state.fastWithdrawalWhitelist[msg.sender], Errors.FAST_WITHDRAW_NOT_ALLOWED);
        _withdraw(state, msg.sender, to, primaryAmount, secondaryAmount);
    }

    function _withdraw(Types.State storage state, address from, address to, uint256 primaryAmount, uint256 secondaryAmount) private {
        if (primaryAmount > 0) {
            state.primaryCredit[from] -= SafeCast.toInt256(primaryAmount);
            IERC20(state.primaryAsset).safeTransfer(to, primaryAmount);
        }

        if (secondaryAmount > 0) {
            state.secondaryCredit[from] -= secondaryAmount;
            IERC20(state.secondaryAsset).safeTransfer(to, secondaryAmount);
        }

        require(Liquidation._isSolidIMSafe(state, from), Errors.ACCOUNT_NOT_SAFE);
        emit Withdraw(to, from, primaryAmount, secondaryAmount);
    }
}
