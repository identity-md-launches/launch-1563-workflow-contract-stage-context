import { randomInt } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

export const Status = Object.freeze({ Open: 0, Requested: 1, Fulfilled: 2, Settled: 3, Cancelled: 4 });

// Matchups are presentation choices, never the source of fight randomness.
export function chooseMatchup(previous, random = randomInt) {
  const choices = [];
  for (let a = 0; a < 8; a++) {
    for (let b = 0; b < 8; b++) {
      if (a === b) continue;
      if (previous && ((a === previous.catA && b === previous.catB) || (a === previous.catB && b === previous.catA))) continue;
      choices.push([a, b]);
    }
  }
  return choices[random(choices.length)];
}

export function withVrfBuffer(price) {
  return (price * 6n + 4n) / 5n;
}

export function eligible(round, bet) {
  return bet.amount > 0n && !bet.claimed
    && (round.status === Status.Cancelled || (round.status === Status.Settled && bet.side === round.winner));
}

/**
 * All durable state lives on chain. completed is only an optimization: a fresh
 * process rechecks every round, including old pending rounds and unpaid claims.
 * The adapter serializes transactions and waits for receipts before returning.
 */
export class Keeper {
  constructor(adapter, { batchSize = 20, random = randomInt, log = () => {} } = {}) {
    if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 50) throw new Error('batchSize must be 1..50');
    this.adapter = adapter;
    this.batchSize = batchSize;
    this.random = random;
    this.log = log;
    this.completed = new Set();
  }

  async step() {
    const api = this.adapter;
    const count = await api.roundCount();
    const now = await api.timestamp();
    let outstanding = false;
    let previous;
    for (let id = 0n; id < count; id++) {
      if (this.completed.has(id)) continue;
      let round = await api.round(id);
      if (id === count - 1n) previous = round;
      if (round.status === Status.Open && now >= round.lockAt) {
        try {
          if (round.total0 === 0n || round.total1 === 0n) {
            await api.send('requestResult', [id]);
          } else {
            // Quote and submit at the same gas price because Chainlink uses tx.gasprice.
            const gasPrice = await api.gasPrice();
            const price = await api.vrfPrice(gasPrice);
            await api.send('requestResult', [id], { value: withVrfBuffer(price), gasPrice });
          }
          this.log('requestResult', { roundId: id });
        } catch (error) {
          // A failed oracle/quote must not strand a locked round. This permissionless
          // timeout remains available even when this process is no longer the keeper.
          if (now <= round.lockAt + 3600n) throw error;
          await api.send('cancelRound', [id]);
          this.log('cancelRound', { roundId: id });
        }
        round = await api.round(id);
      }
      if (round.status === Status.Requested && now > round.requestedAt + 86_400n) {
        await api.send('cancelRound', [id]);
        this.log('cancelRound', { roundId: id });
        round = await api.round(id);
      }
      if (round.status === Status.Fulfilled) {
        await api.send('settle', [id]);
        this.log('settle', { roundId: id });
        round = await api.round(id);
      }
      if (round.status === Status.Settled || round.status === Status.Cancelled) {
        // Do not trust a local event cursor for entitlement: recheck each bet on chain.
        const players = [...new Set((await api.bettors(id, round)).map(player => player.toLowerCase()))];
        const unpaid = [];
        for (const player of players) {
          if (eligible(round, await api.bet(id, player))) unpaid.push(player);
        }
        for (let start = 0; start < unpaid.length; start += this.batchSize) {
          const batch = unpaid.slice(start, start + this.batchSize);
          await api.send('claimMany', [id, batch]);
          this.log('claimMany', { roundId: id, players: batch.length });
        }
        this.completed.add(id);
      } else {
        outstanding = true;
      }
    }
    // The keeper runs rounds sequentially, but also recovers concurrently pending rounds opened by others.
    if (!outstanding && !(await api.paused()) && await api.canOpen()) {
      if (!previous && count > 0n) previous = await api.round(count - 1n);
      const matchup = chooseMatchup(previous, this.random);
      await api.send('openRound', matchup);
      this.log('openRound', { catA: matchup[0], catB: matchup[1] });
    }
  }
}

export async function runLoop(keeper, { intervalMs = 12_000, signal, log = () => {} } = {}) {
  if (!Number.isInteger(intervalMs) || intervalMs < 1) throw new Error('Invalid polling interval');
  while (!signal?.aborted) {
    try {
      await keeper.step();
    } catch (error) {
      // Avoid leaking RPC credentials or account configuration through provider error dumps.
      log('retry', { error: error?.name ?? 'Error' });
    }
    try {
      await delay(intervalMs, undefined, { signal });
    } catch (error) {
      if (error.name !== 'AbortError') throw error;
    }
  }
}
