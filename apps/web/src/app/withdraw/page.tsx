"use client";

import { useMemo, useState } from "react";
import { useAccount, useChainId, useConnect, useReadContract, useSwitchChain, useWriteContract } from "wagmi";
import { NETWORK } from "@/config/networks";
import { escrowAbi, escrowAddress } from "@/lib/contract";
import { friendlyErrorMessage } from "@/lib/errors";
import { formatEther } from "@/lib/format";
import { publicClient } from "@/lib/clients";

export default function WithdrawPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const { data: pending, refetch: refetchPending } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "pendingWithdrawals",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const wrongNetwork = isConnected && chainId !== NETWORK.chainId;

  const handleWithdraw = async () => {
    setError(null);
    setStatus(null);
    try {
      const hash = await writeContractAsync({
        address: escrowAddress,
        abi: escrowAbi,
        functionName: "withdraw",
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await refetchPending();
      setStatus("Withdrawal submitted");
    } catch (err) {
      console.error(err);
      setError(friendlyErrorMessage(err));
    }
  };

  const canWithdraw = useMemo(() => {
    if (!pending) return false;
    return BigInt(pending as bigint) > 0n;
  }, [pending]);

  return (
    <div>
      <h1>Withdraw</h1>
      {wrongNetwork && (
        <div className="banner">
          Wrong network. Please switch to Gravity testnet.
          <div style={{ marginTop: 8 }}>
            <button onClick={() => switchChain({ chainId: NETWORK.chainId })}>
              Switch Network
            </button>
          </div>
        </div>
      )}
      {!isConnected && (
        <div className="card">
          <p>Connect a wallet to withdraw funds.</p>
          <button onClick={() => connect({ connector: connectors[0] })}>Connect Wallet</button>
        </div>
      )}
      <div className="card">
        <p>Pending: {formatEther(pending as bigint | undefined)}</p>
        <button disabled={!isConnected || wrongNetwork || !canWithdraw} onClick={handleWithdraw}>
          Withdraw
        </button>
        {status && <p>{status}</p>}
        {error && <p style={{ color: "red" }}>{error}</p>}
      </div>
    </div>
  );
}
