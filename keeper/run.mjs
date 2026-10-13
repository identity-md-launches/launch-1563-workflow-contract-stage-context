import { createAdapter } from './adapter.mjs';
import { Keeper, runLoop } from './core.mjs';

const log = (step, fields = {}) => console.log(JSON.stringify(
  { time: new Date().toISOString(), step, ...fields }, (_, value) => typeof value === 'bigint' ? value.toString() : value,
));
const controller = new AbortController();
process.once('SIGINT', () => controller.abort());
process.once('SIGTERM', () => controller.abort());

try {
  const adapter = await createAdapter({
    RPC_URL: process.env.RPC_URL,
    PRIVATE_KEY: process.env.PRIVATE_KEY,
    GAME_ADDRESS: process.env.GAME_ADDRESS,
  });
  const keeper = new Keeper(adapter, { log });
  log('started', { chainId: 11155111 });
  await runLoop(keeper, { signal: controller.signal, log });
} catch (error) {
  log('startup-failed', { error: error.name });
  process.exitCode = 1;
}
