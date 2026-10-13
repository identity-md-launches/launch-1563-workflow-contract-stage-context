import test from 'node:test';
import assert from 'node:assert/strict';
import { makeAdapter } from '../adapter.mjs';

function fixture() {
  const calls = [];
  const account = { address: 'keeper' };
  const logRanges = [];
  const client = {
    async readContract(input) {
      calls.push(input);
      const values = { owner: 'owner', keeper: 'KEEPER', roundCount: 5n, vrfPrice: 123n };
      return values[input.functionName];
    },
    async getBlockNumber() { return 20_000n; },
    async getBlock({ blockNumber = 20_000n } = {}) { return { timestamp: blockNumber * 12n }; },
    async getContractEvents(input) {
      logRanges.push(input);
      const events = [
        { block: 15_000n, player: 'Alice' }, { block: 15_001n, player: 'Alice' }, { block: 15_002n, player: 'Bob' },
      ];
      return events.filter(event => event.block >= input.fromBlock && event.block <= input.toBlock)
        .map(event => ({ args: { player: event.player } }));
    },
    async getGasPrice() { return 12n; },
    async simulateContract(input) { calls.push(input); return { request: input }; },
    async waitForTransactionReceipt(input) { calls.push(input); return { status: 'success', blockNumber: 20_000n }; },
  };
  const wallet = { async writeContract(input) { calls.push(input); return 'transactionHash'; } };
  const adapter = makeAdapter({ client, wallet, abi: [], address: 'game', account });
  return { adapter, calls, logRanges, client, wallet };
}

test('VRF quote carries the same gasPrice used by the simulated transaction', async () => {
  const { adapter, calls } = fixture();
  assert.equal(await adapter.vrfPrice(12n), 123n);
  assert.equal(calls[0].gasPrice, 12n);
  await adapter.send('requestResult', [0n], { gasPrice: 12n, value: 148n });
  assert.equal(calls[1].gasPrice, 12n);
  assert.equal(calls[1].value, 148n);
  assert.deepEqual(calls[1], calls[2]);
  assert.equal(calls[3].confirmations, 2);
});

test('round log recovery deduplicates topups and filters by round in bounded block ranges', async () => {
  const { adapter, logRanges } = fixture();
  const players = await adapter.bettors(42n, { lockAt: 180_100n, bettors0: 1n, bettors1: 1n });
  assert.deepEqual(players, ['alice', 'bob']);
  assert.ok(logRanges.length > 1);
  for (const range of logRanges) {
    assert.equal(range.eventName, 'BetPlaced');
    assert.deepEqual(range.args, { roundId: 42n });
    assert.ok(range.toBlock - range.fromBlock < 2000n);
    assert.equal(range.strict, true);
  }
});

test('incomplete log responses fail rather than silently omitting a bettor', async () => {
  const { adapter } = fixture();
  await assert.rejects(adapter.bettors(42n, { lockAt: 180_100n, bettors0: 2n, bettors1: 1n }), /logs incomplete/);
});

test('cancelled-before-lock rounds include bets from the current head', async () => {
  const { adapter, client } = fixture();
  client.getContractEvents = async ({ fromBlock, toBlock }) =>
    fromBlock <= 20_000n && toBlock >= 20_000n ? [{ args: { player: 'AtHead' } }] : [];
  assert.deepEqual(await adapter.bettors(0n, { lockAt: 250_000n, bettors0: 1n, bettors1: 0n }), ['athead']);
});

test('reverted receipts are failures and keeper role is checked without case sensitivity', async () => {
  const { adapter, client } = fixture();
  assert.equal(await adapter.canOpen(), true);
  client.waitForTransactionReceipt = async () => ({ status: 'reverted' });
  await assert.rejects(adapter.send('settle', [1n]), /Transaction reverted/);
});
