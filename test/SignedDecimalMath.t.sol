// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SignedDecimalMath} from "../src/libraries/SignedDecimalMath.sol";
import {Test} from "forge-std/Test.sol";

contract SignedDecimalMathTest is Test {
    using SignedDecimalMath for int256;
    using SignedDecimalMath for uint256;

    function testDecimalMulPositive() pure public {
        int256 a = 1.5e18;
        assertEq(a.decimalMul(2e18), 3e18);
    }

    function testDecimalMulTruncatesTowardZero() pure public {
        int256 a = - 1;
        int256 r = a.decimalMul(1);
        assertEq(r, 0);
    }

    function testDecimalMulNegative() pure public {
        assertEq(int256(- 1.5e18).decimalMul(2e18), - 3e18);
    }

    function testDecimalDivCut() pure public {
        assertEq(int256(1e18).decimalDiv(3e18), 333333333333333333);
    }

    function testDecimalDivNegative() pure public {
        assertEq(int256(- 1e18).decimalDiv(3e18), - 333333333333333333);
    }

    function testAbs() pure public {
        assertEq(SignedDecimalMath.abs(- 5), 5);
    }

    function testDecimalUnsignedMul() pure public {
        assertEq(uint256(1.5e18).decimalMul(uint256(2e18)), 3e18);
    }
}