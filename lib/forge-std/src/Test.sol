// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address who, uint256 newBalance) external;
    function warp(uint256) external;
    function expectRevert(bytes calldata) external;
    function expectRevert(bytes4) external;
    function expectEmit(bool, bool, bool, bool) external;
    function envUint(string calldata) external returns (uint256);
    function envString(string calldata) external returns (string memory);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

abstract contract Test {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition) internal {
        if (!condition) {
            revert AssertionFailed();
        }
    }

    function assertEq(uint256 a, uint256 b) internal {
        if (a != b) {
            revert AssertionFailed();
        }
    }

    function assertEq(address a, address b) internal {
        if (a != b) {
            revert AssertionFailed();
        }
    }

    function assertEq(bytes32 a, bytes32 b) internal {
        if (a != b) {
            revert AssertionFailed();
        }
    }

    error AssertionFailed();
}
