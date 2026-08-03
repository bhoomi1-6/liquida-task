## 1. Vault Investigation

**Target:** `0xE2fb0bdd0ECc9F2DE7F7d3d113C4AcBD77b80C88` on Robinhood Chain Testnet (chain ID 46630)

### Vault type / interface source

The contract is **unverified** on the block explorer, so no direct source was available. It was identified as a **Morpho Vaults V2** deployment by decoding emitted event signatures from its transaction logs and matching them against Morpho's public documentation and open-source repository (`github.com/morpho-org/vault-v2`). Specifically, the vault emits `Withdraw(address,address,address,uint256,uint256)`, `Deposit(address,address,uint256,uint256)`, `Submit(bytes4,bytes,uint256)`, `Accept(bytes4,bytes)`, and `AccrueInterest(uint256,uint256,uint256,uint256)` — an exact match to the Morpho VaultV2 event set, including the dual performance/management fee accrual pattern unique to that framework. This was cross-checked by successfully calling several Morpho VaultV2-specific view functions (`performanceFee`, `curator`, `timelock`, `abdicated`) against the live contract, all of which returned valid (non-reverting) results.

Reference: [Morpho Vaults V2 documentation](https://docs.morpho.org/get-started/resources/contracts/morpho-vaults-v2/)

### Current fee state

| Field | Value |
|---|---|
| Performance fee | `0` (0%, scaled by 1e18) |
| Performance fee recipient | `0x0000000000000000000000000000000000000000` (unset) |
| Management fee | `0` (0%) |
| Management fee recipient | `0x0000000000000000000000000000000000000000` (unset) |
| Underlying asset | `0x8864986420c217C7a56314629B9eC4861cC03b1e` (Liquida Testnet GBPx) |

### Roles

| Role | Address | Notes |
|---|---|---|
| Owner | `0x5025B416632ccaF169262Edf2Cd398D9B7dCC16f` | Manages role assignments (owner/curator/sentinel). Not a Sentinel. |
| Curator | `0x967E7529DDf8B10dF01B73A384e02090DFB640D1` | Chief risk curator; sole role authorised to change fees. **Also holds the Sentinel role on this deployment.** |

### Who can initiate the fee change

The **Curator** is the only role authorised to call `setPerformanceFee(uint256)` (selector `0x70897b23`) and `setPerformanceFeeRecipient(address)` (selector `0x6a5f1aa2`). Both are timelock-gated Curator functions per the Morpho VaultV2 spec.

### Timelock / staged process

Morpho VaultV2 uses a two-stage process for Curator-privileged functions:

1. Curator calls `submit(bytes calldata data)` with the ABI-encoded call (e.g. `setPerformanceFee(newFee)`).
2. Once `executableAt(data)` has passed, **anyone** can call the target function directly to execute it.

On-chain checks show `timelock(0x70897b23) == 0` and `timelock(0x6a5f1aa2) == 0` — i.e. **no timelock duration is currently configured** for either the fee-setting or the fee-recipient functions on this deployment. The staged Submit/Accept mechanism exists structurally, but in practice a submitted fee change becomes executable with no meaningful delay.

### Security observations

- **No effective timelock**: `setPerformanceFee` and `setPerformanceFeeRecipient` both have a `0`-second configured timelock, so depositors get no advance-notice window before a fee change takes effect, contrary to the intended purpose of Morpho's timelock design.
- **Role concentration**: the Curator address is also flagged as a Sentinel (`isSentinel(curator) == true`). Since the Sentinel role exists specifically to provide an independent check that can revoke malicious Curator proposals, having both roles held by the same address removes that separation of duties.
- **`setPerformanceFee` is not abdicated** (`abdicated(0x70897b23) == false`), so the function remains usable — this is not a dead vault.
- Both fees are currently `0` with unset recipients, consistent with a fresh testnet deployment rather than a live production configuration.