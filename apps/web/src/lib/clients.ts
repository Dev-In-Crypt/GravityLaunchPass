import { createPublicClient, http } from "viem";
import { NETWORK } from "@/config/networks";
import { gravityChain } from "@/lib/wagmi";

export const publicClient = createPublicClient({
  chain: gravityChain,
  transport: http(NETWORK.rpcUrl),
});
