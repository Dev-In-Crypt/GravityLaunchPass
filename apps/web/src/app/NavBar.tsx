"use client";

import Link from "next/link";
import { useAccount, useDisconnect } from "wagmi";
import { shortAddress } from "@/lib/format";

export function NavBar() {
  const { address, isConnected, connector } = useAccount();
  const { disconnectAsync } = useDisconnect();

  const handleDisconnect = async () => {
    await disconnectAsync();
    if (connector?.id === "walletConnect") {
      try {
        await connector.disconnect();
      } catch (err) {
        console.warn("Failed to disconnect WalletConnect session", err);
      }
    }
  };

  return (
    <nav>
      <strong>Gravity LaunchPass</strong>
      <Link href="/">Create Job</Link>
      <Link href="/jobs">Jobs</Link>
      <Link href="/withdraw">Withdraw</Link>
      {isConnected && (
        <>
          <span>{shortAddress(address)}</span>
          <button onClick={handleDisconnect}>Disconnect</button>
        </>
      )}
    </nav>
  );
}
