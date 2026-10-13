# Additional contributor tests

These tests extend the accepted suite without changing contracts, configuration,
dependencies, deployment artifacts, or the canonical engine vectors. Their game
properties come from `docs/reference/SPEC.md` sections 2 and 3.

Run from the repository root:

```sh
forge build --offline
forge test --offline
```

No added test needs a network, environment variable, FFI, or downloaded dependency.
The new fuzz tests specify 1,000 runs in source. Each new invariant campaign specifies
256 sequences of 96 calls, with unexpected handler reverts treated as failures.

## Game accounting and exit invariant

`CatWarsLedgerInvariant.t.sol` maintains an independent ledger for four ordinary
players, a receiver that can reject ETH, and the owner. It records inputs when they
succeed rather than reconstructing deposits or credits from the game's getters.
Actors are funded only in the constructor; no action replenishes balances.

Random actions include opening rounds, bets and top-ups, time changes, requests
and excess refunds, empty/unknown/repeated/stale callbacks, settlement, cancellation,
individual and duplicate batch claims, failed/successful withdrawals, and changes
to rake, minimum bet, duration, treasury and pause. A composite progress action also
reaches settlement amid those independently ordered actions.

After every action the campaign checks:

- Player balances, bets, bettor counts and claim flags against the input ledger.
- Exact credits for each beneficiary, including accumulated failed sends and rake.
- Round status, snapshotted settings, request metadata and immutable fulfilled words.
- Wrapper receipts equal fees supplied by request callers.
- Game ETH equals outstanding stakes, unpaid payouts/refunds, owed credits and rounding dust.
- Each settled round retains less than one wei of rounding dust per winning bettor.

After every sequence, the harness advances beyond the deadlines, cancels unresolved
rounds, settles fulfilled rounds, claims for all players, and withdraws every credit.
It checks that no pending payout remains and that the ledger still balances. The
deterministic smoke test separately proves that settlement, timeout cancellation,
failed receiver credits, failed withdrawal and full exit are reachable.

The campaign has no unsolicited ETH donations. Exact equality is asserted for this
closed set of actors and flows; the specification's general solvency requirement
allows additional unaccounted ETH. The earlier solvency suite remains intact.

## Failure paths and arithmetic

`CatWarsAdversarial.t.sol` covers atomic rejection of unknown round IDs across all
round entry points, premature claims and settlement, terminal-state immutability,
keeper cancellation restrictions, side-switch rollback, and refunds after an extreme
minimum-bet change. It also checks zero-valued winning claims, combined refund/rake/
winning credits, failed withdrawals, and the indexed lifecycle events and full-width
seed used by the frontend.

The reentry receivers actually execute their fallback and verify the exact guard
error for all seven money-moving entry points. A revert caused only by an already
claimed bet cannot satisfy this test.

Large-stake fuzzing exercises intermediate products exceeding 256 bits. Equal winning
stakes give an independent payout oracle, `floor(netPool / 2)`, and a quotient/remainder
calculation checks rake without reusing the implementation's `Math.mulDiv`.

## Launch token invariant

`LaunchTokenInvariant.t.sol` tracks all balances and allowances across five holders
under random transfers, self-transfers, approvals, finite/infinite allowance spending,
overspending and invalid zero-address operations. Every balance must match the ledger
and their sum must remain exactly `10^27`. A deterministic sequence exercises full
supply transfers, allowance revocation and failed operations.

## Integration boundary

VRF integration is exercised offline through the accepted local wrapper mock. These
tests do not establish live wrapper availability, pricing/feed configuration,
subscription funding or coordinator delivery. A fork/integration run against the
intended Chainlink deployment remains separate validation; none is claimed here.
