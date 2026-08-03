// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVaultV2
/// @notice Minimal interface for a Morpho Vaults V2 instance, covering only
///         the functions required to inspect and change the performance fee.
/// @dev Confirmed against the live deployment at
///      0xE2fb0bdd0ECc9F2DE7F7d3d113C4AcBD77b80C88 on Robinhood Chain Testnet
///      via successful (non-reverting) `cast call` reads, and cross-checked
///      against https://docs.morpho.org/get-started/resources/contracts/morpho-vaults-v2/
///      Full source: https://github.com/morpho-org/vault-v2
interface IVaultV2 {
    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------

    /// @notice Returns the current owner address of the vault.
    function owner() external view returns (address);

    /// @notice Returns the current curator address of the vault.
    function curator() external view returns (address);

    /// @notice Checks if an account has the Sentinel role.
    function isSentinel(address account) external view returns (bool);

    // ------------------------------------------------------------------
    // Fee state (view)
    // ------------------------------------------------------------------

    /// @notice Returns the current performance fee, scaled by 1e18 (1e18 = 100%).
    function performanceFee() external view returns (uint96);

    /// @notice Returns the recipient address of performance fees.
    function performanceFeeRecipient() external view returns (address);

    /// @notice Returns the current management fee, scaled by 1e18.
    function managementFee() external view returns (uint96);

    /// @notice Returns the recipient address of management fees.
    function managementFeeRecipient() external view returns (address);

    // ------------------------------------------------------------------
    // Timelock / staged governance
    // ------------------------------------------------------------------

    /// @notice Returns the configured timelock duration (seconds) for a given function selector.
    function timelock(bytes4 selector) external view returns (uint256);

    /// @notice Returns the timestamp at which a submitted timelocked action becomes executable.
    /// @param data The exact ABI-encoded call previously passed to `submit`.
    function executableAt(bytes memory data) external view returns (uint256);

    /// @notice Checks whether the Curator has permanently disabled a given selector.
    function abdicated(bytes4 selector) external view returns (bool);

    /// @notice Submits a timelocked action for execution once its timelock expires.
    /// @dev Callable only by the Curator.
    function submit(bytes calldata data) external;

    // ------------------------------------------------------------------
    // Curator functions (timelocked: submit() first, then anyone executes)
    // ------------------------------------------------------------------

    /// @notice Sets the vault's performance fee.
    /// @dev Selector: 0x70897b23. Callable by Curator, subject to `timelock(selector)`.
    /// @param newPerformanceFee The new performance fee, scaled by 1e18.
    function setPerformanceFee(uint256 newPerformanceFee) external;

    /// @notice Sets the performance fee recipient.
    /// @dev Selector: 0x6a5f1aa2. Callable by Curator, subject to `timelock(selector)`.
    function setPerformanceFeeRecipient(address newPerformanceFeeRecipient) external;

    // ------------------------------------------------------------------
    // ERC-4626 / asset accounting (useful for test assertions)
    // ------------------------------------------------------------------

    /// @notice Returns the address of the underlying asset held by the vault.
    function asset() external view returns (address);

    /// @notice Returns the total amount of underlying assets held by the vault.
    function totalAssets() external view returns (uint256);

    /// @notice Accrues interest and mints pending fee shares to fee recipients.
    function accrueInterest() external;
}
