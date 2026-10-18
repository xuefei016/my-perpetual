// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "../src/libraries/Liquidation.sol";
import {IDealer} from "../src/interfaces/IDealer.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {Test} from "forge-std/Test.sol";

contract PerpetualTest is Test, IDealer {
    Perpetual perp;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    mapping(address => uint256) openCount;
    mapping(address => int256) realized;

    function setUp() public {
        perp = new Perpetual(address(this));
    }

    function _trade(address a, int256 aPage, int256 aCredit, address b, int256 bPage, int256 bCredit) internal {
        address[] memory addressList = new address[](2);
        int256[] memory pageList = new int256[](2);
        int256[] memory creditList = new int256[](2);

        addressList[0] = a;
        pageList[0] = aPage;
        creditList[0] = aCredit;
        addressList[1] = b;
        pageList[1] = bPage;
        creditList[1] = bCredit;
        perp.trade(abi.encode(addressList, pageList, creditList));
    }

    function testFundingRateChangeBalance() public {
        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6);

        perp.updateFundingRate(10e6);

        (int256 paperA, int256 creditA) = perp.balanceOf(alice);
        (, int256 creditB) = perp.balanceOf(bob);

        assertEq(paperA, 1e18);
        assertEq(creditA, - 29990e6);
        assertEq(creditB, 29990e6);
    }

    function testRebuyBalanceChange() public {
        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6);

        perp.updateFundingRate(10e6);

        (int256 paperA, int256 creditA) = perp.balanceOf(alice);
        (, int256 creditB) = perp.balanceOf(bob);

        assertEq(paperA, 1e18);
        assertEq(creditA, - 29990e6);
        assertEq(creditB, 29990e6);

        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6);
        (int256 paperA2, int256 creditA2) = perp.balanceOf(alice);
        (, int256 creditB2) = perp.balanceOf(bob);

        assertEq(paperA2, 2e18);
        assertEq(creditA2, - 59990e6);
        assertEq(creditB2, 59990e6);
    }

    function testNotOwnerCallUpdateFunding() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        perp.updateFundingRate(10e6);
    }

    // 开仓只通知一次：仓位 0 → 非 0 才回调 openPosition，加仓不回调
    function testOpenPositionCalledOnce() public {
        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6); // alice 0 → 1，bob 0 → -1
        assertEq(openCount[alice], 1);
        assertEq(openCount[bob], 1);

        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6); // 加仓：1 → 2，不应再通知
        assertEq(openCount[alice], 1);
        assertEq(openCount[bob], 1);
    }

    // 平仓结算：仓位归零时把盈亏交给 Dealer，并清空 Perpetual 里的账
    function testClosePositionRealizePnl() public {
        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6); // alice 30000 买 1 张
        _trade(alice, - 1e18, 32000e6, bob, 1e18, - 32000e6); // alice 32000 卖 1 张

        assertEq(realized[alice], 2000e6); // 多头赚 2000
        assertEq(realized[bob], - 2000e6); // 空头亏 2000，零和

        (int256 paperA, int256 creditA) = perp.balanceOf(alice);
        assertEq(paperA, 0);
        assertEq(creditA, 0); // 为 0 才说明 reducedCredit 被清零，盈亏没有被记两遍
    }

    // 平仓后再开仓算新仓位，应再次通知 Dealer
    function testReopenAfterCloseNotifiesAgain() public {
        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6);
        _trade(alice, - 1e18, 32000e6, bob, 1e18, - 32000e6);
        _trade(alice, 1e18, - 31000e6, bob, - 1e18, 31000e6);

        assertEq(openCount[alice], 2);
    }

    // ==================== 以下 4 个函数：测试合约扮演 Dealer（perp 的 owner 就是本合约） ====================

    // 假 Dealer：不做任何检查，把 _trade 编码的数据原样解码还回去
    function approveTrade(address, bytes calldata tradeData)
    external pure returns (address[] memory, int256[] memory, int256[] memory)
    {
        return abi.decode(tradeData, (address[], int256[], int256[]));
    }

    function isAllSafe(address[] calldata) external pure returns (bool) {
        return true;
    }

    function openPosition(address trader) external {
        openCount[trader] += 1;
    }

    function realizePnl(address trader, int256 pnl) external {
        realized[trader] = pnl;
    }

    function requestLiquidation(address, address, address, int256)
    external
    pure
    returns (int256, int256, int256, int256)
    {
        return (0, 0, 0, 0);
    }

    function isIMSafe(address) external pure returns (bool) {
        return true;
    }

    function handleBadDebt(address) external {}
}