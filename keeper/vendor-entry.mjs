// Build input for the pinned, self-contained viem runtime in vendor/viem.mjs.
export { createPublicClient, createWalletClient, http, getAddress } from 'viem';
export { privateKeyToAccount } from 'viem/accounts';
export { sepolia } from 'viem/chains';
