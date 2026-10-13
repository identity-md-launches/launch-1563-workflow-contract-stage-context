import { readFile } from 'node:fs/promises';
import { createPublicClient, createWalletClient, http, getAddress, privateKeyToAccount, sepolia } from './vendor/viem.mjs';

export async function createAdapter(config) {
  if (!config.RPC_URL || !config.PRIVATE_KEY || !config.GAME_ADDRESS) {
    throw new Error('RPC_URL, PRIVATE_KEY and GAME_ADDRESS are required');
  }
  const url = new URL(config.RPC_URL);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Use an HTTP(S) RPC URL');
  const address = getAddress(config.GAME_ADDRESS);
  const account = privateKeyToAccount(config.PRIVATE_KEY);
  const client = createPublicClient({ chain: sepolia, transport: http(config.RPC_URL) });
  const wallet = createWalletClient({ chain: sepolia, transport: http(config.RPC_URL), account });
  const abi = JSON.parse(await readFile(new URL('../docs/abi/CatWars.json', import.meta.url), 'utf8'));
  if (await client.getChainId() !== sepolia.id) throw new Error('RPC must be Ethereum Sepolia (11155111)');
  const code = await client.getBytecode({ address });
  if (!code || code === '0x') throw new Error('GAME_ADDRESS has no contract code');
  const read = (functionName, args = [], options = {}) => client.readContract({ address, abi, functionName, args, ...options });
  const wrapper = await read('i_vrfV2PlusWrapper');
  if (wrapper.toLowerCase() !== '0x195f15f2d49d693ce265b4fb0fddbe15b1850cc1') {
    throw new Error('Unexpected Sepolia VRF wrapper');
  }
  return makeAdapter({ client, wallet, abi, address, account });
}

// Clients are supplied explicitly so operational behavior can be tested without
// environment variables, credentials, a live RPC, or signing any transaction.
export function makeAdapter({ client, wallet, abi, address, account }) {
  const read = (functionName, args = [], options = {}) => client.readContract({ address, abi, functionName, args, ...options });

  // Find a conservative event start block from the round's lock timestamp. A round
  // can be open for at most one day; timestamp lookup avoids an undocumented
  // deployment-block dependency and genesis-wide log queries on every restart.
  const startBlocks = new Map();
  async function firstBlockAt(timestamp, head) {
    let low = 0n;
    let high = head;
    while (low < high) {
      const middle = (low + high) / 2n;
      const block = await client.getBlock({ blockNumber: middle });
      if (block.timestamp < timestamp) low = middle + 1n;
      else high = middle;
    }
    return low;
  }

  return {
    roundCount: () => read('roundCount'),
    timestamp: async () => (await client.getBlock()).timestamp,
    round: id => read('getRound', [id]),
    bet: (id, player) => read('getBet', [id, player]),
    paused: () => read('paused'),
    gasPrice: () => client.getGasPrice(),
    vrfPrice: gasPrice => read('vrfPrice', [], { gasPrice }),
    canOpen: async () => {
      const [owner, keeper] = await Promise.all([read('owner'), read('keeper')]);
      return [owner, keeper].some(value => value.toLowerCase() === account.address.toLowerCase());
    },
    bettors: async (id, round) => {
      const head = await client.getBlockNumber();
      if (!startBlocks.has(id)) {
        const first = await firstBlockAt(round.lockAt > 86_400n ? round.lockAt - 86_400n : 0n, head);
        startBlocks.set(id, first > 0n ? first - 1n : 0n);
      }
      const players = new Set();
      const end = await firstBlockAt(round.lockAt + 1n, head);
      for (let fromBlock = startBlocks.get(id); fromBlock <= end; fromBlock += 2000n) {
        const toBlock = fromBlock + 1999n < end ? fromBlock + 1999n : end;
        const logs = await client.getContractEvents({
          address, abi, eventName: 'BetPlaced', args: { roundId: id }, fromBlock, toBlock, strict: true,
        });
        for (const log of logs) players.add(log.args.player.toLowerCase());
      }
      // A silent/truncated RPC response must never mark a partly paid round complete.
      if (BigInt(players.size) !== round.bettors0 + round.bettors1) {
        throw new Error('BetPlaced logs incomplete; retry with a complete-history RPC');
      }
      return [...players];
    },
    send: async (functionName, args, options = {}) => {
      const { request } = await client.simulateContract({ address, abi, account, functionName, args, ...options });
      const hash = await wallet.writeContract(request);
      const receipt = await client.waitForTransactionReceipt({ hash, confirmations: 2, timeout: 180_000 });
      if (receipt.status !== 'success') throw new Error('Transaction reverted');
      return receipt;
    },
  };
}
