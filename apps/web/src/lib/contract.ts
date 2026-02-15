import EscrowAbi from "@/config/abi/GravityLaunchPassEscrow.json";
import { NETWORK } from "@/config/networks";

export const escrowAbi = EscrowAbi as const;
export const escrowAddress = NETWORK.escrowAddress;
