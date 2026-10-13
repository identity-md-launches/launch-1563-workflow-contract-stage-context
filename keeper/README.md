# CAT WARS keeper

Requires Node 22 or newer. The repository includes a pinned viem 2.38.5 runtime and licenses in `vendor/`; no `npm install`, CDN import, or runtime dependency download is needed.

The operator supplies these environment variables through their process supervisor or secret store:

| Variable | Actual value to supply |
|---|---|
| `RPC_URL` | An Ethereum Sepolia HTTP(S) RPC endpoint with historical blocks and complete event logs |
| `PRIVATE_KEY` | The operator's keeper account key; use the initial owner or an account assigned with `setKeeper` |
| `GAME_ADDRESS` | The deployed `CatWars` address from the launch handoff |

Start with `node keeper/run.mjs` from the repository root. No real keys are included, read, or used by tests. Run `node --test keeper/test/*.test.mjs` for offline tests; the polling loop is exercised at a 1 ms interval there. Runtime polling is 12 seconds and exits on SIGINT/SIGTERM after the current step finishes.

The keeper opens a random distinct-cat matchup, excluding the last unordered pair. Matchup selection does not determine fight randomness. It requests the result after the on-chain lock time, waits for the authenticated callback, settles, and claims eligible players in batches of 20. It submits `ceil(vrfPrice * 1.2)` at the same gas price used to quote the request; player stakes never pay the fee. One-sided rounds need no VRF quote or payment. Oracle failure can lead to permissionless cancellation after the Open timeout; unfulfilled accepted requests can be cancelled after 24 hours.

Every restart scans all round IDs and recovers older pending requests and unpaid claims, including when another operator has opened a newer round. Event queries are filtered by round, split into at most 2,000-block ranges, and deduplicate top-ups. The query starts conservatively within the maximum one-day betting window. The unique-bettor count must match the on-chain count before any round is marked complete, so incomplete RPC logs cause a retry instead of silently dropping a player. Claim entitlement is read again from `getBet`, not trusted from local state.

Writes are simulated, submitted serially, and awaited for two confirmations. A reverted write or lost connection is retried from chain state on the next tick. Already claimed bets are skipped; a receiver whose payment failed has an `owed` credit and must invoke `withdraw()` itself. This script cannot withdraw a player's credit. Treasury rake is also withdrawn by the treasury separately.

Run one process per signing account to avoid nonce competition. Fund it with ETH for gas and VRF charges. Monitor the one-line JSON step/retry logs; a `retry` line deliberately omits provider error dumps, which can contain RPC credentials. Diagnose configuration/RPC availability independently without exposing keys in logs. A deep reorganization after the two-confirmation threshold can invalidate the process's in-memory completed-round cache; restart the keeper after such an event to rescan every round. The contract remains the authority for every state transition.

Normal use is offline with respect to package dependencies, but naturally needs the supplied RPC connection to operate. The optional maintenance command `python3 tools/bundle-keeper.py` downloads exactly the integrity-pinned npm archives from `vendor/packages.json`, uses the pinned esbuild tool in a temporary directory, and regenerates `vendor/viem.mjs`. It never creates `node_modules`. The generated bundle and all required licenses are delivered, so rebuilding it is not necessary to run or verify this project.
