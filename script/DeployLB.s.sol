//SPDX-License-Identifer: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {LendingBorrowing} from "../src/LendingBorrowing.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployLB is Script {
    LendingBorrowing lb;
    HelperConfig config;

    function run() external returns (LendingBorrowing, HelperConfig) {
        config = new HelperConfig();

        (address wethUsdPriceFeed, address weth, address usdc,) = config.activeNetworkConfig();

        vm.startBroadcast();
        lb = new LendingBorrowing(weth, usdc, wethUsdPriceFeed);
        vm.stopBroadcast();
        return (lb, config);
    }
}
