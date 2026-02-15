export const NETWORK = {
    chainId: Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 13505),
    rpcUrl: process.env.NEXT_PUBLIC_RPC_URL ?? "https://rpc-sepolia.gravity.xyz",
    escrowAddress: (process.env.NEXT_PUBLIC_ESCROW_ADDRESS ??
      "0x7FC4e0Aa40488588f66eB135C7326068F37cEb80") as `0x${string}`,
    explorerBase:
      process.env.NEXT_PUBLIC_EXPLORER_BASE ?? "https://explorer-sepolia.gravity.xyz",
    startBlock: BigInt(process.env.NEXT_PUBLIC_START_BLOCK ?? "96624"),
  } as const;
  