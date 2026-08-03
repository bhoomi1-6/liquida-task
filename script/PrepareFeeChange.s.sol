// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IVaultV2} from "../src/IVaultV2.sol";

/// @title PrepareFeeChange
/// @notice Reads live vault state and generates the UNSIGNED calldata required
///         to submit and later execute a performance-fee change on a Morpho
///         Vaults V2 instance. This script never signs or broadcasts a
///         transaction — it only reads on-chain state and prints calldata for
///         the Curator (or, post-timelock, anyone) to submit separately.
/// @dev Run as a read-only script:
///      forge script script/PrepareFeeChange.s.sol \
///        --rpc-url $ROBINHOOD_TESTNET_RPC_URL \
///        --sig "run(uint256)" 300
///      (300 = 3.00%, expressed in basis points — see FEE_BPS_SCALE below)
contract PrepareFeeChange is Script {
    /// @dev Expected chain ID for Robinhood Chain Testnet. Guards against
    ///      accidentally pointing this script at the wrong network.
    uint256 constant EXPECTED_CHAIN_ID = 46630;

    /// @dev Morpho VaultV2 fees are stored scaled by 1e18 (1e18 == 100%).
    uint256 constant FEE_UNIT_SCALE = 1e18;

    /// @dev Input convenience scale: caller passes fee in basis points
    ///      (1 bps = 0.01%), e.g. 300 = 3.00%. 1 bps == 1e14 in 1e18-scale.
    uint256 constant BPS_TO_FEE_UNIT = 1e14;

    /// @dev Morpho caps the performance fee at 50% of generated interest.
    uint256 constant MAX_PERFORMANCE_FEE_BPS = 5000; // 50.00%

    /// @dev Function selectors, taken directly from Morpho's published
    ///      VaultV2 selector table (docs.morpho.org/.../morpho-vaults-v2).
    bytes4 constant SET_PERFORMANCE_FEE_SELECTOR = 0x70897b23;
    bytes4 constant SET_PERFORMANCE_FEE_RECIPIENT_SELECTOR = 0x6a5f1aa2;

    address constant VAULT = 0xE2fb0bdd0ECc9F2DE7F7d3d113C4AcBD77b80C88;

    /// @param proposedFeeBps The desired performance fee in basis points
    ///        (e.g. 300 for 3.00%). Human-readable input; converted to the
    ///        contract's integer units below.
    function run(uint256 proposedFeeBps) external view {
        _guardChainId();

        IVaultV2 vault = IVaultV2(VAULT);

        // ---- 1. Read live state before proposing anything -----------
        uint256 currentFee = vault.performanceFee();
        address currentRecipient = vault.performanceFeeRecipient();
        address curator = vault.curator();
        address owner = vault.owner();
        uint256 configuredTimelock = vault.timelock(SET_PERFORMANCE_FEE_SELECTOR);
        bool isAbdicated = vault.abdicated(SET_PERFORMANCE_FEE_SELECTOR);

        require(!isAbdicated, "setPerformanceFee has been abdicated on this vault; change is impossible");

        // ---- 2. Convert human-readable input to contract units ------
        uint256 newFeeScaled = proposedFeeBps * BPS_TO_FEE_UNIT;

        // ---- 3. Validate against the contract's permitted range -----
        require(proposedFeeBps <= MAX_PERFORMANCE_FEE_BPS, "Proposed fee exceeds Morpho's 50% performance fee cap");
        require(newFeeScaled != currentFee, "Proposed fee is identical to the current fee; nothing to change");

        // ---- 4. Build the inner call (the actual state change) ------
        bytes memory innerCalldata = abi.encodeWithSelector(SET_PERFORMANCE_FEE_SELECTOR, newFeeScaled);

        // ---- 5. Build the stage-1 "submit" calldata ------------------
        // This is what the Curator must sign and send to start the
        // timelock (or, if timelock == 0, to make it immediately
        // executable).
        bytes memory submitCalldata = abi.encodeWithSelector(IVaultV2.submit.selector, innerCalldata);

        // ---- 6. Stage-2 "execute" calldata is the inner call itself -
        // Per Morpho's design, once executableAt(data) has passed,
        // ANYONE (not just the Curator) may call the target function
        // directly using this exact calldata.
        bytes memory executeCalldata = innerCalldata;

        // ---- 7. Report everything, human-readable ---------------------
        console.log("=== Liquida Vault Fee Change: Prepared (UNSIGNED, NOT BROADCAST) ===");
        console.log("Network            : Robinhood Chain Testnet (chainId %s)", block.chainid);
        console.log("Vault               :", VAULT);
        console.log("Owner               :", owner);
        console.log("Curator             :", curator);
        console.log("---");
        console.log("Current fee (raw)   :", currentFee);
        console.log("Current recipient   :", currentRecipient);
        console.log("Configured timelock :", configuredTimelock, "seconds");
        console.log("---");
        console.log("Proposed fee (bps)  :", proposedFeeBps);
        console.log("Proposed fee (raw)  :", newFeeScaled);
        console.log("---");
        console.log("STAGE 1: submit() -- must be called by Curator:", curator);
        console.logBytes(submitCalldata);
        console.log("---");
        console.log("STAGE 2: setPerformanceFee() -- callable by ANYONE once executable");
        console.log("         (executableAt has passed; configured timelock is %s s)", configuredTimelock);
        console.logBytes(executeCalldata);
        console.log("======================================================================");
    }

    /// @dev Prevents this script from being pointed at the wrong network.
    ///      Mutating scripts must never assume the caller passed the right
    ///      --rpc-url; verifying chainid on-chain is the only reliable check.
    function _guardChainId() internal view {
        require(
            block.chainid == EXPECTED_CHAIN_ID,
            "Wrong chain: refusing to prepare calldata for a non-Robinhood-Testnet RPC"
        );
    }
}
