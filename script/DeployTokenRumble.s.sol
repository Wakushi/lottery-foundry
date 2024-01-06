// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {TokenRumble} from "../src/TokenRumble.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "./Interaction.s.sol";

contract DeployTokenRumble is Script {
    function run() external returns (TokenRumble, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address vrfCoordinator,
            bytes32 gasLane,
            uint64 subscriptionId,
            uint32 callbackGasLimit,
            address link,
            uint256 deployerKey,
            address priceFeed,
            ,

        ) = helperConfig.activeNetworkConfig();

        if (subscriptionId == 0) {
            CreateSubscription createSubscription = new CreateSubscription();
            subscriptionId = createSubscription.createSubscription(
                vrfCoordinator,
                deployerKey
            );
            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(
                vrfCoordinator,
                subscriptionId,
                link,
                deployerKey
            );
        }

        TokenRumble.RumbleConfig memory config = TokenRumble.RumbleConfig({
            vrfCoordinator: vrfCoordinator,
            priceFeed: priceFeed,
            gasLane: gasLane,
            subscriptionId: subscriptionId,
            callbackGasLimit: callbackGasLimit
        });

        vm.startBroadcast();
        TokenRumble tokenRumble = new TokenRumble(config);
        vm.stopBroadcast();

        AddConsumer addConsumer = new AddConsumer();
        addConsumer.addConsumer(
            address(tokenRumble),
            vrfCoordinator,
            subscriptionId,
            deployerKey
        );
        return (tokenRumble, helperConfig);
    }
}
