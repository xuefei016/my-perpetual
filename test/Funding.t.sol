// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MetaNodeDealer} from "../src/MetaNodeDealer.sol";

contract FundingTest is Test {
    MockERC20 usdc;
    MetaNodeDealer dealer;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant TIME_LOCK = 1 hours;
    uint256 constant AMOUNT = 1000e6;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        dealer = new MetaNodeDealer(address(usdc)); // 本测试合约是 owner
        dealer.setWithdrawTimeLock(TIME_LOCK);
        _mintAndDeposit(alice);
        _mintAndDeposit(bob); // bob 的钱让合约里有"别人的存款"，用例 ③ 才有意义
    }

    function _mintAndDeposit(address user) internal {
        usdc.mint(user, AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(dealer), type(uint256).max);
        dealer.deposit(AMOUNT, 0, user);
        vm.stopPrank();
    }

    // ① 验收点：时间锁未到期就执行提现 → revert
    function testExecuteWithdrawBeforeTimeLockReverts() public {
        vm.startPrank(alice);
        dealer.requestWithdraw(AMOUNT, 0);
        vm.expectRevert(bytes(Errors.WITHDRAW_PENDING));
        dealer.executeWithdraw(alice);
        vm.stopPrank();
    }

    // ② 时间锁到期后全额提现成功（同时覆盖 `>= 0` 的边界）
    function testExecuteWithdrawAfterTimeLock() public {
        vm.startPrank(alice);
        dealer.requestWithdraw(AMOUNT, 0);
        vm.warp(block.timestamp + TIME_LOCK);
        dealer.executeWithdraw(alice);
        vm.stopPrank();

        assertEq(dealer.getPrimaryCredit(alice), 0);
        assertEq(usdc.balanceOf(alice), AMOUNT);
        assertEq(usdc.balanceOf(address(dealer)), AMOUNT); // 只剩 bob 的钱
    }

    // ③ 取超过自己存款的钱 → revert（防止偷走 bob 的存款）
    function testFastWithdrawOverBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes(Errors.ACCOUNT_NOT_SAFE));
        dealer.fastWithdraw(alice, AMOUNT + 1, 0);
    }
}
