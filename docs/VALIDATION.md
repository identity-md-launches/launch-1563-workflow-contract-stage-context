# Local validation

Validated with Solidity 0.8.26, Foundry 1.8.3, optimizer 200 runs, via-IR, Cancun EVM, and `bytecode_hash = "none"`.

| Check | Result |
|---|---|
| `forge build` | Pass |
| `forge test` | 39 reported test groups pass, none failed or skipped; Foundry groups the two invariant functions together |
| Reference engine vectors | All 500 match winner, turns and both final HP values |
| Lifecycle fuzz | 512 runs of randomized stakes, random word, and rake; exact payouts and conservation |
| Token transfer fuzz | 512 runs |
| Stateful invariants | 128 runs × 96 calls = 12,288 calls, zero unexpected reverts; solvency, round totals, deterministic outcomes, and total ETH conservation |
| Factory / runtime checks | Empty-chain CREATE2 construction, supplied owner, unchanged factory token balance, no forbidden opcodes, EIP-170 bounds |
| `forge fmt --check` | Pass; required verbatim files excluded from formatting |
| ABI export consistency | Pass, checked against compiler artifacts |
| `node --test keeper/test/*.test.mjs` | 17 tests pass, including adapter log pagination and recovery; no live RPC or keys |

The supplied engine's gas test reports average simulation gas **184,177**, maximum **425,745** across the 500 vectors. The full `CatWars.settle` benchmark first cools the game address and storage, then settles each of the 500 vector fights. Observed average is **256,681** gas, maximum **498,651** gas, below the specification's approximate 600,000 target. Measurements cover those vectors, not every possible seed, and exclude transaction intrinsic gas. The callback succeeds with the configured **150,000** gas limit.

At these compiler settings the deployed runtime sizes are **12,695 bytes** for `CatWars` and **1,502 bytes** for `LaunchToken`, both below 24,576 bytes. The reference library is internal and introduces no link placeholders.

For a focused gas report run `forge test --match-contract CatWarsGasTest -vv`. For compiler call-level statistics run `forge test --match-contract CatWarsTest --gas-report`. Reproduce the full suite from the repository root; there is no environment-variable, RPC, account, or live-chain dependency in the Solidity tests. The 500-vector test only reads its committed JSON file.

These are implementer-run checks. Independent launch review and service verification remain required.
