// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "./Test.sol";

abstract contract Script {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
}
