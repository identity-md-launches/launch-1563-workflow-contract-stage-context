# CAT WARS contracts

Native-ETH, 1v1 cat-fight betting for Ethereum Sepolia. Players back RED (side 0) or BLUE (side 1); Chainlink VRF v2.5 supplies a random word and the unchanged reference engine determines the fight on chain. Winning bettors share the pot in proportion to their stake, less the round's snapshotted rake.

This contract-stage contribution includes the game, independent launch token, tests, ABI exports, and the Node keeper requested for the contracts repository. Source publication, the separately reviewed launch manifest, attestation, admission, chain deployment, and the website/IPFS release belong to the subsequent launch services and frontend stage. No transactions have been broadcast and no deployment addresses are fabricated here.

The implemented contract specification is [SPEC.md at commit 62a025e](https://github.com/dew1645/cat-wars-spec/blob/62a025e1bfd655205aa1cdb54ce9943999691c85/SPEC.md), also saved in [docs/reference/SPEC.md](docs/reference/SPEC.md). The launch's constructor restrictions require one documented adaptation to the Chainlink consumer base; see below and [the review handoff](docs/REVIEW.md).

## Build and test

Run at the repository root with Foundry and Solidity **0.8.26**:

```sh
forge build
forge test
forge fmt --check
python3 tools/export-abis.py --check
node --test keeper/test/*.test.mjs
```

Solidity dependencies and the keeper's viem runtime are ordinary vendored files. These commands need no dependency download or package installation. Foundry must already have the pinned compiler, as the verifier does. FFI is disabled. The sole filesystem permission is read access to `./test` for the 500 reference vectors. The formatter excludes the verbatim engine and its verbatim test.

The test suite covers the full lifecycle, exact payment amounts, rejecting/gas-exhausting receivers, reentrancy, timeouts, malformed and stale callbacks, bounded administrative settings, factory deployment on an empty chain, forbidden opcodes, and stateful solvency. [Validation results](docs/VALIDATION.md) include measured settlement gas. Passing these checks does not replace the launch's independent adversarial review.

## Contracts and deployment parameters

| Contract | Constructor | Launch parameters |
|---|---|---|
| `LaunchToken` | No arguments, nonpayable | Name `CAT WARS`, symbol `MEOW`, 18 decimals, exactly `10^27` units minted to the deploying factory |
| `CatWars` | `constructor(address vrfWrapper, address owner_)`, nonpayable | Wrapper `0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1`; owner argument `$owner`, resolving to `0xcb97592071fa186ed4c8d00dcd1d50f4145c1a80` |

The chain is **Sepolia, 11155111**. `CatWarsEngine` is an internal library inlined into `CatWars`; do not add it as an independently deployed application or link an external library. There are no proxies or initialization calls. Both constructors succeed without code at any external address. Ownership is assigned to the explicit owner argument, never to the factory or transaction origin.

`LaunchToken` is a plain fixed-supply ERC-20 with no owner, minting, pause, tax, blocklist, upgrade, or burn entry point. The game does not use or receive an allocation of MEOW. The factory allocates the supply: 10% to the swarm distributor, 88% to liquidity, and 2% to the payer (or the policy treasury when no payer exists). No application contract performs this split.

The separate token launch pool pairs with native ETH at the policy fee **1.25%** (`12500`), tick spacing `60`, and manifest initial price `79228162514264337593543950336`. The deployer derives its effective opening price from the policy's 20 ETH opening market cap and the actual token address. The game's default 5% round rake is separate from that pool fee. The manifest author must use the supplied policy values and record `LaunchToken` plus `CatWars`; this contribution intentionally does not write `launch.json`.

### Chainlink constructor adaptation

The standard `VRFV2PlusWrapperConsumerBase` calls `wrapper.link()` during construction. That conflicts with the launch's empty-chain constructor check. The vendored base therefore removes the cached LINK immutable and resolves LINK lazily inside `getLinkToken()` and the unused LINK-payment helper. Its native-payment helper and wrapper-authenticated callback are unchanged. `CatWars` uses only native payment. The constructor still has exactly the two required arguments, and the wrapper is immutable. `vrfPrice()` checks that the wrapper has code on first use. The original base and a precise dependency record are included for review in [docs/reference](docs/reference) and [DEPENDENCIES.md](docs/DEPENDENCIES.md).

## Playing and round transitions

1. The owner or keeper calls `openRound(catA, catB)` with different cat IDs from 0 to 7. Only one round may be `Open`; already requested rounds can coexist with a new round. IDs start at zero. Each round fixes `lockAt` and snapshots `rakeBps` when opened.
2. Before `lockAt`, anyone calls `placeBet(id, side)` with at least `minBet` in ETH. An address can top up its chosen side, but cannot switch sides in that round. Each top-up must independently meet the current minimum.
3. At or after `lockAt`, anyone calls payable `requestResult(id)`. Empty/one-sided rounds are cancelled and the request payment is refunded without contacting VRF. For two-sided rounds the caller supplies the complete native VRF fee; **stakes never pay it**. Three confirmations and one word are requested with a 150,000 callback gas limit. Excess ETH is returned, or credited to `owed[caller]` if the receiver rejects it. Quote at the transaction's intended gas price and include a margin; a stale/insufficient payment reverts atomically.
4. The immutable wrapper delivers the word. The callback only records the word and sets `Fulfilled`. Unknown requests, empty word arrays, duplicate callbacks, and callbacks after cancellation are ignored. Unauthorized callers revert. A zero random word is valid.
5. Anyone calls `settle(id)`. The seed is exactly `bytes32(randomWord)`, big-endian. The reference engine picks the winner. Rake is `floor(pool * round.rakeBps / 10000)` and is credited to the **treasury configured at settlement**. The round becomes `Settled`; no automatic external payment occurs during settlement.
6. Anyone may claim for a bettor. A winning payout is `floor(stake * (pool - rake) / winningSideTotal)`; a cancelled round refunds the full stake. Losing single claims revert; batches skip losers, absent bets, and already claimed bets. The player receives the payment, regardless of who called. The claimed flag is set before sending. Failed sends become `owed[player]` and do not block others.

Claims use a 50,000-gas call budget per receiver (plus the EVM value-transfer stipend), so a hostile fallback cannot exhaust a whole adequately funded batch. A receiver needing more gas can call `withdraw()` itself: this forwards available gas, zeroes its own `owed` balance before interaction, and restores the credit on transfer failure. Withdrawals cannot redirect another account's credit. Contract bettors must be able to invoke `withdraw()` and eventually accept ETH; there is intentionally no privileged recovery or alternate-recipient function.

All divisions round down. Payout dust and forced ETH remain locked in the contract; there is no sweep. No ordinary direct ETH deposits are accepted. The solvency invariant counts live stakes, unpaid settled winnings/cancelled refunds, and all `owed` balances. The tests also independently check total ETH conservation and stake/bettor totals.

### Cancellations and asynchronous failure

- Owner/keeper may cancel an `Open` round at any time, returning stakes in full.
- Anyone may cancel an `Open` round **strictly after** `lockAt + 1 hour`.
- Anyone, including the owner acting under the same public rule, may cancel a `Requested` round **strictly after** `requestedAt + 24 hours`. The owner/keeper has no earlier privilege.
- `Fulfilled` and `Settled` rounds can never be cancelled. A fulfilled round remains settleable even after 24 hours.
- A failed wrapper request leaves the round `Open` and all ETH intact. A timed-out request does not return the VRF fee already paid to Chainlink; only player stakes are refundable. No request is retried or replaced after it has been accepted.
- In the race between an expired request's callback and its cancellation, transaction order decides whether the round settles or refunds. A delayed callback cannot resurrect a cancelled round.

## Administrative powers and assumptions

| Owner action | Default / bounds | Effect |
|---|---|---|
| `setRakeBps(uint16)` | 500 / 0–1000 | Only rounds opened afterwards |
| `setBettingDuration(uint256)` | 300 seconds / 60–86400 | Only future round lock times |
| `setMinBet(uint256)` | 0.001 ETH / greater than zero | Every subsequent bet/top-up, including in an already open round |
| `setTreasury(address)` | Initial owner / nonzero | Future settlement rake; existing `owed` credits stay with their recipients |
| `setKeeper(address)` | Initial owner / any address | Opening and early Open-round cancellation; zero disables the extra keeper role |
| `pause()` / `unpause()` | Initially unpaused | Blocks only opening new rounds; bets and all resolution/payment paths continue |
| `transferOwnership` + `acceptOwnership` | OpenZeppelin two-step | Changes admin authority; treasury and keeper remain separately configured |
| `renounceOwnership()` | Inherited OpenZeppelin behavior | Irreversibly removes administration; the existing keeper remains authorized |

The owner can change future economics or stop new rounds, but cannot withdraw stakes, select a fight seed, cancel a fulfilled round, replace the wrapper, or upgrade the game. The immutable wrapper and Chainlink's oracle network are trusted to authenticate and deliver VRF results. The deterministic reference engine is trusted for fight logic and is tested against its canonical vectors. Keeper availability is not required for refunds or claims, since those paths are permissionless; timely request/settlement still needs someone willing to pay transaction gas and VRF charges.

### After launch

No contract setup is required. `treasury = keeper = owner_`, and the game is usable with its defaults immediately. The owner may optionally assign a dedicated keeper with `setKeeper(address)` using an address they control and a treasury with `setTreasury(address)` using a wallet or contract able to call `withdraw()`. They obtain those addresses from their own wallets; no outside subscription, LINK funding, or unknown oracle setting is required.

The operator funds their keeper account with Sepolia ETH for transaction gas and native VRF charges, supplies the actual deployed game address and RPC endpoint, and runs [keeper/run.mjs](keeper/run.mjs). The treasury calls `withdraw()` to receive accrued rake; failed-payment recipients also withdraw their own credits. Monitor insufficient keeper balance, oracle outages, unclaimed refunds, transaction failures, and unfulfilled requests. Changing ownership does not transfer or revoke the separately configured keeper or treasury.

The frontend stage receives the actual addresses and deployment block from the deployment handoff and the ABI files in [docs/abi](docs/abi). [ABI.md](docs/ABI.md) describes reads, transactions, replay encoding, events, and required UI behavior. Do not substitute invented addresses or live sample activity.

Experimental game. Only play where online wagering is legal for you. 18+.
