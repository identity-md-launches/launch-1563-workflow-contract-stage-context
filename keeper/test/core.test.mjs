import test from 'node:test';
import assert from 'node:assert/strict';
import { chooseMatchup, withVrfBuffer, eligible, Keeper, Status, runLoop } from '../core.mjs';
import { createAdapter } from '../adapter.mjs';

// Local test fixtures only: the production keeper never invents players or rounds.
class FakeChain {
  rounds = [];
  bets = new Map();
  calls = [];
  clock = 0n;
  isPaused = false;
  authorized = true;
  failQuote = false;
  async roundCount() { return BigInt(this.rounds.length); }
  async timestamp() { return this.clock; }
  async round(id) { return { ...this.rounds[Number(id)] }; }
  async bet(id, player) { return { ...this.bets.get(`${id}:${player}`) }; }
  async paused() { return this.isPaused; }
  async canOpen() { return this.authorized; }
  async gasPrice() { return 13n; }
  async vrfPrice(gasPrice) {
    assert.equal(gasPrice, 13n);
    if (this.failQuote) throw new Error('oracle unavailable');
    return 101n;
  }
  async bettors(id) {
    return [...this.bets.keys()].filter(key => key.startsWith(`${id}:`)).map(key => key.split(':')[1]);
  }
  addRound(overrides = {}) {
    this.rounds.push({ status: Status.Open, catA: 0, catB: 1, lockAt: 300n, requestedAt: 0n,
      total0: 100n, total1: 100n, winner: 0, ...overrides });
    return BigInt(this.rounds.length - 1);
  }
  addBet(id, player, side = 0) { this.bets.set(`${id}:${player}`, { side, amount: 100n, claimed: false }); }
  async send(name, args, options = {}) {
    this.calls.push({ name, args, options });
    const round = this.rounds[Number(args[0])];
    if (name === 'openRound') this.addRound({ catA: args[0], catB: args[1], lockAt: this.clock + 300n });
    if (name === 'requestResult') {
      assert.equal(round.status, Status.Open);
      assert.ok(this.clock >= round.lockAt);
      round.status = round.total0 === 0n || round.total1 === 0n ? Status.Cancelled : Status.Requested;
      round.requestedAt = this.clock;
    }
    if (name === 'cancelRound') round.status = Status.Cancelled;
    if (name === 'settle') { assert.equal(round.status, Status.Fulfilled); round.status = Status.Settled; }
    if (name === 'claimMany') {
      for (const player of args[1]) {
        const bet = this.bets.get(`${args[0]}:${player}`);
        assert.ok(eligible(round, bet));
        bet.claimed = true;
      }
    }
  }
}

test('every random selection uses distinct cats and excludes previous unordered matchup', () => {
  const previous = { catA: 0, catB: 1 };
  const selected = new Set();
  for (let index = 0; index < 54; index++) {
    const [a, b] = chooseMatchup(previous, length => { assert.equal(length, 54); return index; });
    assert.notEqual(a, b);
    assert.ok(a >= 0 && a < 8 && b >= 0 && b < 8);
    assert.notDeepEqual([a, b].sort(), [0, 1]);
    selected.add(`${a}:${b}`);
  }
  assert.equal(selected.size, 54);
});

test('VRF budget rounds a 20 percent buffer upward', () => {
  assert.equal(withVrfBuffer(0n), 0n);
  assert.equal(withVrfBuffer(100n), 120n);
  assert.equal(withVrfBuffer(101n), 122n);
});

test('opens the first round then waits for on-chain lock time', async () => {
  const chain = new FakeChain();
  const keeper = new Keeper(chain, { random: () => 0 });
  await keeper.step();
  assert.equal(chain.calls.length, 1);
  assert.equal(chain.calls[0].name, 'openRound');
  chain.clock = 299n;
  await keeper.step();
  assert.equal(chain.calls.length, 1);
});

test('full lifecycle separately pays VRF and batches only unclaimed winners', async () => {
  const chain = new FakeChain();
  chain.addRound();
  for (let i = 0; i < 45; i++) chain.addBet(0n, `winner${i}`);
  chain.addBet(0n, 'loser', 1);
  chain.clock = 300n;
  const keeper = new Keeper(chain, { batchSize: 20, random: () => 0 });
  await keeper.step();
  assert.equal(chain.calls.length, 1);
  assert.deepEqual(chain.calls[0], { name: 'requestResult', args: [0n], options: { value: 122n, gasPrice: 13n } });
  await keeper.step();
  assert.equal(chain.calls.length, 1);
  chain.rounds[0].status = Status.Fulfilled;
  await keeper.step();
  assert.deepEqual(chain.calls.map(call => call.name), ['requestResult', 'settle', 'claimMany', 'claimMany', 'claimMany', 'openRound']);
  assert.deepEqual(chain.calls.filter(call => call.name === 'claimMany').map(call => call.args[1].length), [20, 20, 5]);
  assert.equal((await chain.bet(0n, 'loser')).claimed, false);
  assert.notDeepEqual(chain.calls.at(-1).args.slice().sort(), [0, 1]);
  await keeper.step();
  assert.equal(chain.calls.length, 6);
});

test('one-sided rounds refund all bettors without a VRF quote', async () => {
  const chain = new FakeChain();
  chain.addRound({ total0: 0n });
  chain.addBet(0n, 'blue', 1);
  chain.failQuote = true;
  chain.clock = 300n;
  chain.isPaused = true;
  await new Keeper(chain).step();
  assert.deepEqual(chain.calls.map(call => call.name), ['requestResult', 'claimMany']);
  assert.deepEqual(chain.calls[0].options, {});
  assert.ok((await chain.bet(0n, 'blue')).claimed);
});

test('restart recovers old pending rounds and old claims while a newer round is open', async () => {
  const chain = new FakeChain();
  chain.addRound({ status: Status.Fulfilled });
  chain.addBet(0n, 'oldwinner');
  chain.addRound({ status: Status.Cancelled });
  chain.addBet(1n, 'refunder', 1);
  chain.addRound();
  await new Keeper(chain).step();
  assert.deepEqual(chain.calls.map(call => call.name), ['settle', 'claimMany', 'claimMany']);
  await new Keeper(chain).step();
  assert.equal(chain.calls.length, 3);
});

test('an interrupted claim batch is recovered from on-chain claimed flags', async () => {
  const chain = new FakeChain();
  chain.addRound({ status: Status.Settled });
  chain.addBet(0n, 'first');
  chain.addBet(0n, 'second');
  chain.isPaused = true;
  const send = chain.send.bind(chain);
  let once = true;
  chain.send = async (...args) => {
    await send(...args);
    if (once) { once = false; throw new Error('receipt connection lost after mining'); }
  };
  await assert.rejects(new Keeper(chain, { batchSize: 1 }).step());
  await new Keeper(chain, { batchSize: 1 }).step();
  assert.equal(chain.calls.length, 2);
  assert.ok((await chain.bet(0n, 'first')).claimed);
  assert.ok((await chain.bet(0n, 'second')).claimed);
});

test('request timeout uses the strict 24-hour boundary', async () => {
  const chain = new FakeChain();
  chain.addRound({ status: Status.Requested, requestedAt: 10n });
  chain.addBet(0n, 'player');
  chain.clock = 86410n;
  chain.isPaused = true;
  const keeper = new Keeper(chain);
  await keeper.step();
  assert.equal(chain.calls.length, 0);
  chain.clock++;
  await keeper.step();
  assert.deepEqual(chain.calls.map(call => call.name), ['cancelRound', 'claimMany']);
});

test('unavailable VRF preserves the permissionless open-round timeout', async () => {
  const chain = new FakeChain();
  chain.addRound();
  chain.failQuote = true;
  chain.isPaused = true;
  chain.clock = 3900n;
  const keeper = new Keeper(chain);
  await assert.rejects(keeper.step());
  assert.equal(chain.calls.length, 0);
  chain.clock++;
  await keeper.step();
  assert.equal(chain.calls[0].name, 'cancelRound');
});

test('pause and missing opening authority still allow settlement and claims', async () => {
  for (const paused of [true, false]) {
    const chain = new FakeChain();
    chain.addRound({ status: Status.Fulfilled });
    chain.addBet(0n, 'player');
    chain.isPaused = paused;
    chain.authorized = false;
    await new Keeper(chain).step();
    assert.deepEqual(chain.calls.map(call => call.name), ['settle', 'claimMany']);
  }
});

test('short-interval loop retries failures and stops promptly', async () => {
  const controller = new AbortController();
  let steps = 0;
  const logs = [];
  const keeper = { async step() {
    steps++;
    if (steps === 1) throw new Error('deliberately unavailable RPC');
    if (steps === 3) controller.abort();
  } };
  await runLoop(keeper, { intervalMs: 1, signal: controller.signal, log: (...args) => logs.push(args) });
  assert.equal(steps, 3);
  assert.deepEqual(logs, [['retry', { error: 'Error' }]]);
});

test('vendored viem imports offline and adapter rejects missing deployment configuration', async () => {
  await assert.rejects(createAdapter({}), /RPC_URL, PRIVATE_KEY and GAME_ADDRESS are required/);
});
