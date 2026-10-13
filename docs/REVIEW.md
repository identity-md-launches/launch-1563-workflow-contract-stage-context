# Independent review handoff

This is the implementer's review handoff, not an independent audit. The next review must inspect the accepted source together with the separately generated `launch.json`. Publication, signed-artifact linkage, policy attestation, admission, deployment, and explorer verification remain service responsibilities; their absence from this source contribution is not an application defect.

## Concrete compatibility deviation to review

The source specification names the Chainlink wrapper consumer base, whose stock constructor calls `wrapper.link()`. The launch explicitly forbids external calls in application constructors and tests them on an empty chain. Those constraints cannot both hold with the stock base unchanged. This contribution makes the narrow lazy-LINK adaptation documented in [DEPENDENCIES.md](DEPENDENCIES.md), preserving the exact native request helper and callback authentication. The engine and engine test remain byte-for-byte unchanged. The independent reviewer should assess this explicit source deviation rather than assume an unmodified upstream base.

The actual two-argument constructor performs no external calls or code-presence checks. The expected wrapper is the requester-specified Sepolia address; `$owner` resolves to the supplied owner. `Deployment.t.sol` executes the full creation bytecode through CREATE2 on a chain without wrapper code, verifies ownership is not assigned to the factory, and scans deployed opcodes and EIP-170 sizes. The manifest must not independently deploy or link `CatWarsEngine`, alter constructor argument order, or grant roles to the factory/deployer.

## Accounting and external interactions

- All deposits, request fee/refund flows, settlement crediting, claims, and withdrawals use OpenZeppelin's reentrancy guard. Claim flags and withdrawal balances are updated before external payment. Failed claim/refund sends become a recipient credit; a failed withdrawal reverts and preserves that credit.
- A request requires a sufficient caller payment before contacting the wrapper. The actual price returned by the native helper is also checked against that payment, atomically rolling back any unexpected repricing. Wrapper failure cannot leave a partially requested round or consume player ETH.
- Request mappings encode `roundId + 1` so an unknown request cannot fulfill round zero. Duplicate request IDs are rejected. Unknown, stale, repeated, and empty callbacks do nothing; simulation runs only in explicit settlement.
- Rake is snapshotted when opening. The current treasury at settlement receives the credit, as specified. Changing treasury cannot redirect old credits. No sweep, owner payout, arbitrary-call, upgrade, or rescue path exists.
- Each winning share rounds down using `Math.mulDiv`. Remaining dust and forced ETH are permanently surplus to liabilities. The owner cannot extract them. A batch skips absent, losing, duplicate, and previously claimed entries.
- Claim/refund calls set a 50,000-gas budget (plus the EVM value-transfer stipend) and discard returndata. A bad receiver cannot block other recipients in an adequately funded batch. Honest contracts exceeding that receive budget must use their own `withdraw()`; contracts unable to accept ETH or invoke withdrawal can permanently lock their own credit.

## Trust and liveness assumptions

The immutable, correctly configured Chainlink wrapper is trusted for authenticated VRF words. No local mock establishes production oracle availability or correctness. The owner/keeper controls matchmaking and may cancel any Open round, but loses that discretionary cancellation power when a request is accepted. The owner can alter future rake up to 10%, change the live minimum bet, assign a treasury/keeper, or prevent future openings. Pause does not stop resolution or claims. Ownership renunciation can make a pause permanent for new rounds and does not revoke the existing keeper.

Public timeouts protect principal when no request is made or no callback arrives. They do not reimburse caller-funded oracle charges. When fulfillment and timeout cancellation compete, the first valid transaction wins. There is no selective reroll, result replacement, or cancellation of Fulfilled rounds. Players/keepers pay their own transaction gas; the protocol does not reward permissionless maintenance.

The keeper uses complete event history and on-chain entitlement checks. It should run once per signing wallet and be funded by the owner/operator. Two-confirmation receipts are an operational assumption, not finality; restart after a deeper reorg to clear the completed-round cache. The later frontend must handle reorgs, use the precise published seed, and never infer outcome from an unset `winner` field.

## Validation boundary

The delivered tests exercise the specification's Section 3 cases, exact engine vectors, factory construction, ERC-20 behavior, runtime restrictions, keeper recovery, and two stateful invariants. The compiler's built-in lint also ran. Some lint leads are expected: the verbatim engine intentionally rounds at several intermediate arithmetic steps, timestamp comparisons implement specified timeouts, and guarded fixed-recipient calls implement payouts. Those patterns were inspected in context; warnings were not suppressed by altering the reference engine.

Slither and Mythril were not run. No production fork test, live oracle request, private-key operation, deployment, or independent audit was performed. The reviewer must still assess the final manifest's concrete source, constructor, ownership, authorization, and policy choices before release.
