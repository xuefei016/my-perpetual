// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MetaNodeDealer} from "../src/MetaNodeDealer.sol";
import {MockPriceSource} from "../test/mocks/MockPriceSource.sol";
import {Perpetual} from "../src/Perpetual.sol";
import {console2} from "forge-std/console2.sol";
import {Types} from "../src/libraries/Types.sol";

contract DeployScript is Script {
    address constant ORDERSENDER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant FUNDINGKEEPER = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;
    address constant INSURANCE = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant TRADER = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;

    function run() external {
        uint256 pk = vm.envUint("MetaNode_DEPLOYER_PK");

        vm.startBroadcast(pk);

        MockERC20 mockERC20 = new MockERC20("USDC", "USDC", 6);
        mockERC20.mint(TRADER, 100000e6);
        MetaNodeDealer dealer = new MetaNodeDealer(address(mockERC20));

        dealer.setFundingRateKeeper(FUNDINGKEEPER);
        dealer.setInsurance(INSURANCE);
        dealer.setOrderSender(ORDERSENDER, true);
        dealer.setMaxPositionAmount(20);

        MockPriceSource pxBtc = new MockPriceSource(30_000e6);
        Perpetual perpBtc = new Perpetual(address(dealer));
        Types.RiskParams memory pBtc = Types.RiskParams({
            initialMarginRatio: 1e17,
            liquidationThreshold: 5e16,
            liquidationPriceOff: 1e16,
            insuranceFeeRate: 1e16,
            markPriceSource: address(pxBtc),
            name: "BTC-USDC",
            isRegistered: true
        });

        dealer.setPerpRiskParams(address(perpBtc), pBtc);
        vm.stopBroadcast();

        console2.log("USDC", address(mockERC20));
        console2.log("MetaNodeDealer", address(dealer));
        console2.log("BTC price source", address(pxBtc));
        console2.log("Perp BTC-USDC", address(perpBtc));
    }
}