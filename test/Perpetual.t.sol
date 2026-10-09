// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Perpetual} from "../src/Perpetual.sol";
import {Test} from "forge-std/Test.sol";

contract PerpetualTest is Test {
    Perpetual perp;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

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

    function testNotOwnerCallTrade() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        _trade(alice, 1e18, - 30000e6, bob, - 1e18, 30000e6);
    }
}