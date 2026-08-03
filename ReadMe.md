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



## 2. Preparing the Fee Change

**Script:** `script/PrepareFeeChange.s.sol`

This script reads live vault state, converts a human-readable fee input into the contract's integer units, validates it, and generates **unsigned calldata** for both stages of a Morpho VaultV2 fee change. It never signs or broadcasts a transaction.

### Human-readable input → contract units

The script accepts the proposed fee in **basis points** (1 bps = 0.01%), avoiding floating-point arithmetic entirely as required. Morpho VaultV2 stores `performanceFee` scaled by `1e18` (`1e18` = 100%), so the conversion is:
newFeeScaled = proposedFeeBps * 1e14

e.g. `300` bps → `30000000000000000` (3.00%).

### Validation

- Rejects any proposal above Morpho's documented 50% performance-fee cap (`5000` bps), read as a hardcoded constant sourced from Morpho's docs rather than an on-chain call, since no explicit `MAX_FEE`-style getter was found on this interface.
- Rejects a "change" identical to the current fee.
- Rejects if `abdicated(setPerformanceFee selector)` is `true` (i.e. the function has been permanently disabled by the Curator).
- Guards against the wrong network via `require(block.chainid == 46630)`.

### Staged calldata output

Because fee changes on Morpho VaultV2 go through a two-step Submit → Execute process (see Step 1), the script outputs two distinct pieces of calldata:

1. **Stage 1 — `submit(bytes)`**: must be sent by the **Curator** (`0x967E7529DDf8B10dF01B73A384e02090DFB640D1`). Wraps the inner `setPerformanceFee(uint256)` call.
2. **Stage 2 — `setPerformanceFee(uint256)`**: callable by **anyone** once `executableAt(data)` has passed. Since the configured timelock for this function is currently `0` seconds, this is executable immediately after Stage 1.

### Example run

forge script script/PrepareFeeChange.s.sol
--rpc-url $ROBINHOOD_TESTNET_RPC_URL
--sig "run(uint256)" 300

Output (abridged):

Current fee (raw) : 0
Configured timelock : 0 seconds
Proposed fee (raw) : 30000000000000000
STAGE 1 (submit, by Curator): 0xef7fa71b...
STAGE 2 (execute, by anyone): 0x70897b23000000000000000000000000000000000000000000000000006a94d74f430000

Both calldata payloads were manually decoded and verified:
- `cast --to-hex 30000000000000000` confirmed the fee value matches the tail of the Stage 2 calldata.
- `cast 4byte-decode` confirmed the Stage 1 calldata correctly decodes as `submit(bytes)` wrapping the Stage 2 payload.

### Failure case tested

Running with `6000` bps (60%, above the 50% cap) correctly reverted with `"Proposed fee exceeds Morpho's 50% performance fee cap"`, confirming the validation logic works before any calldata is generated.

### Note on role enforcement

The claim that only the Curator can call `submit`/`setPerformanceFee` is currently based on Morpho's published documentation for this framework, not on inspection of this specific contract's bytecode (which is unverified). This is empirically verified in the fork tests (Step 4) via an unauthorized-caller failure test, rather than assumed.