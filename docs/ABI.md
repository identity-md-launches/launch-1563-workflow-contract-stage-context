# Contract interface and frontend handoff

`docs/abi/CatWars.json` and `docs/abi/LaunchToken.json` are JSON ABI arrays exported from Solidity 0.8.26 artifacts. `CatWarsEngine.json` is empty because every callable library function is internal. Regenerate with `forge build` then `python3 tools/export-abis.py`; check with `--check`. These are interfaces, not a deployment manifest. Services supply the real addresses and deployment block.

## Round and bet data

| `Status` value | Meaning |
|---|---|
| 0 | Open: accepts bets only while chain time is below `lockAt` |
| 1 | Requested: immutable pending VRF request |
| 2 | Fulfilled: ready for anyone to settle |
| 3 | Settled: winning claims available |
| 4 | Cancelled: refunds available |

`getRound(id)` returns a tuple with these fields in declaration order:

| Fields | Solidity type | Meaning |
|---|---|---|
| `catA`, `catB` | `uint8` each | RED and BLUE roster indices |
| `status` | `uint8` | Enum above |
| `rakeBps` | `uint16` | Snapshot at opening |
| `winner`, `turns` | `uint8` each | Valid only when Settled; winner is side 0 or 1 |
| `lockAt`, `requestedAt`, `requestId` | `uint256` each | Timestamps in seconds, and wrapper request ID |
| `total0`, `total1` | `uint256` each | Gross stakes in wei, never reduced by claims |
| `bettors0`, `bettors1` | `uint256` each | Unique addresses on each side; top-ups do not increment |
| `randomWord` | `uint256` | Valid once Fulfilled/Settled; zero is a legitimate word |
| `rake` | `uint256` | Final rake in wei, set at settlement |

`getBet(id, player)` returns `(uint8 side, uint256 amount, bool claimed)`. A zero amount means no bet. `pendingPayout(id, player)` returns zero for nonterminal rounds, absent/already-claimed bets, and losing bets. A winning bet can also round down to zero at very small stakes. Inspect both status and the bet when deciding whether to offer a claim.

`roundCount()` is the count; `currentRoundId()` returns `roundCount - 1` and reverts `NoRounds()` when no round exists. All round-indexed calls reject nonexistent IDs with `UnknownRound(id)`. `getBalance()` is gross contract ETH, **not** withdrawable treasury revenue. Read `owed(account)` for a withdrawal.

## Writes and event indexing

| Action | Interface | Notes |
|---|---|---|
| Bet | `placeBet(uint256,uint8)` payable | Check chain, lock time, side lock, and current minimum before sending |
| Request | `requestResult(uint256)` payable | Query `vrfPrice()` at the intended `gasPrice`; caller funds the full fee, zero needed for a one-sided round |
| Settle | `settle(uint256)` | Only Fulfilled; permissionless |
| Cancel | `cancelRound(uint256)` | Owner/keeper while Open, or public strict timeout conditions |
| Own claim | `claim(uint256)` | Caller must be an eligible bettor |
| Relayed claim | `claimFor(uint256,address)` | Always pays/credits the specified bettor |
| Batch | `claimMany(uint256,address[])` | Terminal rounds only; skip ineligible entries; use bounded batches |
| Withdraw credit | `withdraw()` | Only caller's own `owed` credit |

Every listed round event indexes `roundId`. `BetPlaced` and `Claimed` also index `player`. A `BetPlaced.amount` is the additional bet amount, not the bettor's cumulative stake; `total0`/`total1` are cumulative round totals. Deduplicate addresses for a backer list and use `getBet` as the current source of truth. Persist transaction and block hashes in the frontend index so it can discard reorged events. `RoundSettled` publishes `seed`, `winner`, `turns`, `pool`, and `rake`. `RandomnessFulfilled` alone does not settle the round.

`Claimed.sent = false` means `owed[player]` increased and the bet is already claimed. `RefundCredited` covers a rejected refund of the request caller's excess ETH. `Withdrawn` is only retained in a successful transaction; failed withdrawal reverts its state and event. Admin changes emit their individual events; pause and ownership events follow OpenZeppelin.

## Fight replay

Use the canonical `engine/engine.js` and `art/catart.js` from specification commit `62a025e1bfd655205aa1cdb54ce9943999691c85`, unchanged. In the frontend:

```js
const seedHex = '0x' + randomWord.toString(16).padStart(64, '0');
const replay = engine.simulate(catA, catB, engine.hexToSeed(seedHex));
```

The `RoundSettled.seed` field is already the same 32-byte big-endian hex value. Do not hash it, reinterpret it as a little-endian integer, use a decimal string, strip leading zero bytes, or produce a new seed. The engine internally interprets seed bytes according to its own canonical RNG algorithm. Show verification only after replay winner and turns match the on-chain fields; show a mismatch explicitly otherwise.

The subsequent website must implement the supplied spec's mobile dark layout, injected-wallet and WalletConnect connections, read-only viewing, wrong-chain prompt, **TESTNET** badge on Sepolia, live countdown/backers/pot/payout multipliers, pending/confirmed/error transaction states, canonical portraits, verified replay and outcome overlays, past-round claims, `owed` withdrawal, and history with explorer links. Use chain data only. The required footer is:

> Experimental game. Only play where online wagering is legal for you. 18+.

For pre-settlement estimates use `floor(pool * round.rakeBps / 10000)`, not the current global rake setting. Expected return for one wei of winning stake is `(pool - rake) / sideTotal`; a zero side total has no defined multiplier. Show that additional bets can change the eventual multiplier. MEOW does not pay game stakes or VRF fees. If the website also shows the launch token pool, use its deployed pool key and **1.25%** fee from the service handoff.
