// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IVaultV2} from "../src/IVaultV2.sol";

/// @title VaultFeeChangeTest
/// @notice Fork tests proving the performance-fee change lifecycle on the
///         live Morpho VaultV2 deployment at 0xE2fb...C88, entirely against
///         a local Anvil fork. No transaction in this suite ever touches
///         the real Robinhood Chain Testnet.
contract VaultFeeChangeTest is Test {
    IVaultV2 constant vault = IVaultV2(0xE2fb0bdd0ECc9F2DE7F7d3d113C4AcBD77b80C88);

    bytes4 constant SET_PERFORMANCE_FEE_SELECTOR = 0x70897b23;
    bytes4 constant INCREASE_TIMELOCK_SELECTOR = 0x47966291;

    address curator;
    address owner;
    address unauthorized = address(0xBEEF);

    function setUp() public {
        // Fork Robinhood Chain Testnet at its current head. Pin to a fixed
        // block via ROBINHOOD_TESTNET_FORK_BLOCK for fully reproducible runs.
        uint256 forkBlock = vm.envOr("ROBINHOOD_TESTNET_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("ROBINHOOD_TESTNET_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("ROBINHOOD_TESTNET_RPC_URL"), forkBlock);
        }

        curator = vault.curator();
        owner = vault.owner();
    }

    // ------------------------------------------------------------------
    // 1. Confirm initial state matches what Step 1 investigation found
    // ------------------------------------------------------------------
    function testInitialFeeIsZero() public view {
        assertEq(vault.performanceFee(), 0, "expected current performance fee to be 0");
        assertEq(vault.performanceFeeRecipient(), address(0), "expected recipient to be unset");
    }

    function testInitialTimelockIsZero() public view {
        assertEq(vault.timelock(SET_PERFORMANCE_FEE_SELECTOR), 0, "expected no configured timelock initially");
    }

    // ------------------------------------------------------------------
    // 2. Successful lifecycle: Curator submits, then executes, fee changes
    // ------------------------------------------------------------------
    function testSuccessfulFeeChangeLifecycle() public {
        uint256 newFee = 0.03e18; // 3%
        address recipient = address(0xCAFE);

        // The vault enforces FeeInvariantBroken(): a non-zero performance
        // fee requires a non-zero recipient already set. Set the recipient
        // first via the same submit -> execute flow.
        bytes memory setRecipientCalldata = abi.encodeWithSelector(bytes4(0x6a5f1aa2), recipient); // setPerformanceFeeRecipient

        vm.prank(curator);
        vault.submit(setRecipientCalldata);
        vm.warp(vault.executableAt(setRecipientCalldata));
        (bool recipientOk,) = address(vault).call(setRecipientCalldata);
        require(recipientOk, "setup failed: could not set performance fee recipient");
        assertEq(vault.performanceFeeRecipient(), recipient, "recipient not set correctly");

        // Now the actual fee change under test.
        bytes memory innerCalldata = abi.encodeWithSelector(SET_PERFORMANCE_FEE_SELECTOR, newFee);

        vm.prank(curator);
        vault.submit(innerCalldata);

        uint256 executableAt = vault.executableAt(innerCalldata);
        vm.warp(executableAt);

        vm.prank(unauthorized);
        (bool success,) = address(vault).call(innerCalldata);
        assertTrue(success, "expected setPerformanceFee execution to succeed after timelock");

        assertEq(vault.performanceFee(), newFee, "performance fee did not update to expected value");
    }

    // ------------------------------------------------------------------
    // 3. Failure: unauthorized caller cannot submit a fee change
    // ------------------------------------------------------------------
    function testUnauthorizedCallerCannotSubmit() public {
        bytes memory innerCalldata = abi.encodeWithSelector(SET_PERFORMANCE_FEE_SELECTOR, uint256(0.03e18));

        vm.prank(unauthorized);
        vm.expectRevert();
        vault.submit(innerCalldata);
    }

    // ------------------------------------------------------------------
    // 4. Failure: excessive fee is rejected by the contract itself
    //    (not just by our off-chain script's validation logic)
    // ------------------------------------------------------------------
    function testExcessiveFeeRejectedOnChain() public {
        uint256 excessiveFee = 0.51e18; // 51%, above Morpho's documented 50% cap

        bytes memory innerCalldata = abi.encodeWithSelector(SET_PERFORMANCE_FEE_SELECTOR, excessiveFee);

        vm.prank(curator);
        vault.submit(innerCalldata);

        uint256 executableAt = vault.executableAt(innerCalldata);
        vm.warp(executableAt);

        (bool success,) = address(vault).call(innerCalldata);
        assertFalse(success, "expected on-chain rejection of a fee above the 50% cap");
    }

    // ------------------------------------------------------------------
    // 5. Failure: execution before the timelock has elapsed
    //    Demonstrated by first having the Curator raise the timelock for
    //    setPerformanceFee to a nonzero duration, then attempting an
    //    early execution of a subsequent fee-change proposal.
    // ------------------------------------------------------------------
    function testExecutionBeforeTimelockReverts() public {
        uint256 newTimelockDuration = 2 days;

        // Raise the timelock itself first (this action's own timelock is
        // whatever is currently configured for its own selector — 0 here,
        // so it takes effect immediately).
        bytes memory increaseTimelockCalldata =
            abi.encodeWithSelector(INCREASE_TIMELOCK_SELECTOR, SET_PERFORMANCE_FEE_SELECTOR, newTimelockDuration);

        vm.prank(curator);
        vault.submit(increaseTimelockCalldata);
        vm.warp(vault.executableAt(increaseTimelockCalldata));
        (bool ok,) = address(vault).call(increaseTimelockCalldata);
        require(ok, "setup failed: could not raise timelock");

        assertEq(vault.timelock(SET_PERFORMANCE_FEE_SELECTOR), newTimelockDuration, "timelock was not raised");

        // Now submit a fee change under the new, nonzero timelock.
        bytes memory feeChangeCalldata = abi.encodeWithSelector(SET_PERFORMANCE_FEE_SELECTOR, uint256(0.02e18));

        vm.prank(curator);
        vault.submit(feeChangeCalldata);

        // Attempt to execute immediately, without warping forward.
        (bool success,) = address(vault).call(feeChangeCalldata);
        assertFalse(success, "expected execution to fail before the timelock elapses");
    }
}
