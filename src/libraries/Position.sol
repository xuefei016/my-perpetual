// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Errors} from "./Errors.sol";
import {Types} from "./Types.sol";

library Position {
    function _openPosition(Types.State storage state, address trader) internal {
        require(state.openPositions[trader].length < state.maxPositionAmount, Errors.POSITION_AMOUNT_REACH_UPPER_LIMIT);
        state.openPositions[trader].push(msg.sender);
    }

    function _realizePnl(Types.State storage state, address trader, int256 pnl) internal {
        state.primaryCredit[trader] += pnl;
        state.positionSerialNum[trader][msg.sender] += 1;
        address[] storage addressList = state.openPositions[trader];
        for (uint256 i = 0; i < addressList.length;) {
            if (addressList[i] == msg.sender) {
                addressList[i] = addressList[addressList.length - 1];
                addressList.pop();
                break;
            }
            unchecked {
                i++;
            }
        }
    }
}
