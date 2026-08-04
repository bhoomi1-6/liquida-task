# AGENTS.md

Instructions for AI coding agents (and human contributors) working in this repository.

## What this repository is

A Foundry project that investigates a deployed Morpho Vaults V2 instance on Robinhood Chain Testnet, prepares an unsigned performance-fee change, and proves the expected behaviour entirely against a local fork. No part of this repository sends a real transaction to any live network.

## Build & test

```bash
forge fmt --check       # verify formatting (CI enforces this)
forge build              # compile
forge test -vvv          # run fork tests (requires ROBINHOOD_TESTNET_RPC_URL)
```

Required environment variables (see `.env.example`):
- `ROBINHOOD_TESTNET_RPC_URL` — public RPC endpoint
- `ROBINHOOD_TESTNET_FORK_BLOCK` — pinned block number for reproducible fork tests (optional; defaults to latest if unset)

## Scripts

```bash
# Prepare unsigned calldata for a fee change (read-only, no fork mutation)
forge script script/PrepareFeeChange.s.sol --rpc-url $ROBINHOOD_TESTNET_RPC_URL --sig "run(uint256)" <feeBps>

# Run the full submit -> warp -> execute lifecycle on a local in-memory fork
forge script script/DemoFeeChangeOnFork.s.sol --rpc-url $ROBINHOOD_TESTNET_RPC_URL --sig "run(uint256)" <feeBps>
```

Both scripts MUST be run without the `--broadcast` flag. Never add `--broadcast` to any command in this repository.

## Hard rules — an agent must NEVER do the following

1. **Never use, request, generate, or hardcode a private key, seed phrase, or `.env` value containing real credentials.** Impersonation for testing is done exclusively via `vm.prank` inside a local fork.
2. **Never add the `--broadcast` flag** to any `forge script` command, and never call `cast send`.
3. **Never commit `.env`** or any file containing real secrets. Only `.env.example` (with placeholder/public values) is tracked.
4. **Never assume a function signature, selector, role, or fee unit is correct without verifying it against live on-chain state** (`cast call`) or a primary source (verified contract source, or the framework's official documentation once the framework is identified). Treat AI-generated ABIs and assumptions as untrusted until checked.
5. **Never remove or weaken the chain-ID guard** (`require(block.chainid == 46630, ...)`) in any mutating script.
6. **Never modify `src/IVaultV2.sol` function selectors** without re-verifying them against the live contract or Morpho's published interface — a wrong selector silently calls the wrong function.

## What "done" looks like

- `forge fmt --check` passes with no diff
- `forge build` compiles with no errors
- `forge test -vvv` passes all tests, including at least one meaningful failure case
- `PrepareFeeChange.s.sol` and `DemoFeeChangeOnFork.s.sol` both run successfully against the pinned fork block
- README.md accurately reflects current findings, assumptions, and any known incomplete work
- No real transaction has been sent to Robinhood Chain Testnet at any point