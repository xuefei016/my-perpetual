// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MetaNodeExternal} from "./MetaNodeExternal.sol";
import {MetaNodeOperation} from "./MetaNodeOperation.sol";
import {MetaNodeView} from "./MetaNodeView.sol";

contract MetaNodeDealer is MetaNodeExternal, MetaNodeOperation, MetaNodeView {
    constructor(address _primaryAsset) {
        state.primaryAsset = _primaryAsset;
    }
}
