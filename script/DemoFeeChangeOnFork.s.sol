// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IVaultV2} from "../src/IVaultV2.sol";

/// @title DemoFeeChangeOnFork
/// @notice Runs the full performance-fee change lifecycle (submit -> warp ->
///         execute) against a LOCAL, in-memory fork of Robinhood Chain
///         Testnet, and reports the result as both human-readable console
///         output and a structured JSON file.
/// @dev IMPORTANT: run this with `forge script` WITHOUT the `--broadcast`
///      flag. Without --broadcast, forge script executes entirely inside a
///      local, in-memory EVM instance seeded from a fork of the given
///      --rpc-url. No transaction is ever sent to the real network -- the
///      same underlying mechanism used by `forge test --fork-url`.
///
///      forge script script/DemoFeeChangeOnFork.s.sol \
///        --rpc-url $ROBINHOOD_TESTNET_RPC_URL \
///        --sig "run(uint256)" 300
contract DemoFeeChangeOnFork is Script {
    uint256 constant EXPECTED_CHAIN_ID = 46630;
    uint256 constant BPS_TO_FEE_UNIT = 1e14;
    uint256 constant MAX_PERFORMANCE_FEE_BPS = 5000;

    bytes4 constant SET_PERFORMANCE_FEE_SELECTOR = 0x70897b23;
    bytes4 constant SET_PERFORMANCE_FEE_RECIPIENT_SELECTOR = 0x6a5f1aa2;

    address constant VAULT = 0xE2fb0bdd0ECc9F2DE7F7d3d113C4AcBD77b80C88;
    address constant DEMO_EXECUTOR = address(0xBEEF); // arbitrary unrelated caller

    function run(uint256 proposedFeeBps) external {
        require(block.chainid == EXPECTED_CHAIN_ID, "Wrong chain: refusing to run against a non-Robinhood-Testnet RPC");
        require(proposedFeeBps <= MAX_PERFORMANCE_FEE_BPS, "Proposed fee exceeds the 50% performance fee cap");

        IVaultV2 vault = IVaultV2(VAULT);

        // ---- Snapshot BEFORE state ------------------------------------
        uint256 feeBefore = vault.performanceFee();
        address recipientBefore = vault.performanceFeeRecipient();
        address curator = vault.curator();
        address owner = vault.owner();
        uint256 configuredTimelock = vault.timelock(SET_PERFORMANCE_FEE_SELECTOR);

        uint256 newFee = proposedFeeBps * BPS_TO_FEE_UNIT;
        address demoRecipient = address(0xCAFE);

        // ---- Stage 0: ensure a recipient is set (vault invariant) ------
        // Discovered during fork testing: the vault reverts a non-zero fee
        // change with FeeInvariantBroken() if performanceFeeRecipient is
        // still address(0). If unset, we set it first, using the same
        // submit -> warp -> execute pattern as the real fee change.
        if (recipientBefore == address(0)) {
            bytes memory setRecipientCalldata =
                abi.encodeWithSelector(SET_PERFORMANCE_FEE_RECIPIENT_SELECTOR, demoRecipient);
            vm.prank(curator);
            vault.submit(setRecipientCalldata);
            vm.warp(vault.executableAt(setRecipientCalldata));
            (bool recipientOk,) = address(vault).call(setRecipientCalldata);
            require(recipientOk, "demo setup failed: could not set performance fee recipient");
        }

        // ---- Stage 1: Curator submits the fee change (LOCAL fork only) -
        bytes memory innerCalldata = abi.encodeWithSelector(SET_PERFORMANCE_FEE_SELECTOR, newFee);
        vm.prank(curator);
        vault.submit(innerCalldata);

        uint256 executableAt = vault.executableAt(innerCalldata);

        // ---- Advance local time past the timelock (LOCAL fork only) ----
        vm.warp(executableAt);

        // ---- Stage 2: anyone can execute post-timelock (LOCAL fork only)
        vm.prank(DEMO_EXECUTOR);
        (bool success,) = address(vault).call(innerCalldata);
        require(success, "fee change execution failed");

        // ---- Snapshot AFTER state ---------------------------------------
        uint256 feeAfter = vault.performanceFee();
        address recipientAfter = vault.performanceFeeRecipient();

        // ---- Human-readable console report -------------------------------
        console.log("========================================================");
        console.log("LIQUIDA VAULT FEE CHANGE -- LOCAL FORK DEMONSTRATION");
        console.log("========================================================");
        console.log("Network         : Robinhood Chain Testnet (chainId %s)", block.chainid);
        console.log("Vault           :", VAULT);
        console.log("Owner           :", owner);
        console.log("Curator         :", curator);
        console.log("--------------------------------------------------------");
        console.log("Fee before      :", feeBefore);
        console.log("Fee after       :", feeAfter);
        console.log("Recipient before:", recipientBefore);
        console.log("Recipient after :", recipientAfter);
        console.log("Configured delay:", configuredTimelock, "seconds");
        console.log("--------------------------------------------------------");
        console.log("Stage 1 caller  : Curator (required)");
        console.log("Stage 2 caller  :", DEMO_EXECUTOR, "(unrelated address -- anyone may execute)");
        console.log("--------------------------------------------------------");
        console.log("MUTATIONS OCCURRED ONLY ON A LOCAL, IN-MEMORY FORK.");
        console.log("No transaction was broadcast to the live testnet.");
        console.log("========================================================");

        // ---- Structured JSON report ---------------------------------------
        string memory json = "demo";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "vault", VAULT);
        vm.serializeAddress(json, "owner", owner);
        vm.serializeAddress(json, "curator", curator);
        vm.serializeUint(json, "feeBefore", feeBefore);
        vm.serializeUint(json, "feeAfter", feeAfter);
        vm.serializeAddress(json, "recipientBefore", recipientBefore);
        vm.serializeAddress(json, "recipientAfter", recipientAfter);
        vm.serializeUint(json, "configuredTimelockSeconds", configuredTimelock);
        vm.serializeAddress(json, "stage1RequiredCaller", curator);
        vm.serializeAddress(json, "stage2Executor", DEMO_EXECUTOR);
        string memory finalJson = vm.serializeBool(json, "mutationsOccurredOnlyLocally", true);

        vm.writeJson(finalJson, "./out/fee-change-demo-summary.json");
        console.log("JSON summary written to ./out/fee-change-demo-summary.json");
    }
}
