// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {GravityLaunchPassEscrow} from "../src/GravityLaunchPassEscrow.sol";

contract DeployGravityLaunchPassEscrow is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);

        GravityLaunchPassEscrow escrow = new GravityLaunchPassEscrow();

        vm.stopBroadcast();

        console2.log("GravityLaunchPassEscrow deployed at", address(escrow));
    }
}
