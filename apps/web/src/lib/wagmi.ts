import { http, createConfig } from "wagmi";
import { injected } from "wagmi/connectors";
import { NETWORK } from "@/config/networks";

export const gravityChain = {
  id: NETWORK.chainId,
  name: "Gravity Testnet",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [NETWORK.rpcUrl] },
    public: { http: [NETWORK.rpcUrl] },
  },
  blockExplorers: {
    default: { name: "Gravity Explorer", url: NETWORK.explorerBase },
  },
  testnet: true,
} as const;

export const wagmiConfig = createConfig({
  chains: [gravityChain],
  connectors: [injected()],
  transports: {
    [gravityChain.id]: http(NETWORK.rpcUrl),
  },
});
