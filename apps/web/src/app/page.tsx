"use client";

import { useEffect, useMemo, useState } from "react";
import { decodeEventLog, getAddress, keccak256, parseEther, type Hex } from "viem";
import { useAccount, useChainId, useConnect, useWriteContract } from "wagmi";
import { useWaitForTransactionReceipt, useReadContract, useSwitchChain } from "wagmi";
import { NETWORK } from "@/config/networks";
import { escrowAbi, escrowAddress } from "@/lib/contract";
import { friendlyErrorMessage } from "@/lib/errors";
import { shortAddress } from "@/lib/format";

export default function HomePage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { switchChain } = useSwitchChain();
  const [preferredReviewer, setPreferredReviewer] = useState("");
  const [feeBpsOverride, setFeeBpsOverride] = useState("0");
  const [acceptWindowOverride, setAcceptWindowOverride] = useState("0");
  const [submitWindowOverride, setSubmitWindowOverride] = useState("0");
  const [amount, setAmount] = useState("0.01");
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [jobId, setJobId] = useState<Hex | null>(null);
  const [txHash, setTxHash] = useState<Hex | null>(null);
  const [preCreateCount, setPreCreateCount] = useState<bigint | null>(null);

  const { writeContractAsync } = useWriteContract();
  const { data: clientJobCount } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "clientJobCount",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const { data: receipt } = useWaitForTransactionReceipt({
    hash: txHash ?? undefined,
  });

  useEffect(() => {
    if (!receipt) return;
    const matchedLog = receipt.logs.find((log) => {
      try {
        const decoded = decodeEventLog({ abi: escrowAbi, data: log.data, topics: log.topics });
        return decoded.eventName === "JobCreated";
      } catch {
        return false;
      }
    });
    if (matchedLog) {
      const decoded = decodeEventLog({
        abi: escrowAbi,
        data: matchedLog.data,
        topics: matchedLog.topics,
      });
      const args = decoded.args as { jobId: Hex };
      setJobId(args.jobId);
      return;
    }
    if (address && preCreateCount !== null) {
      const count = preCreateCount;
      const fallbackJobId = keccak256(abiEncodePackedAddressCount(getAddress(address), count));
      setJobId(fallbackJobId as Hex);
    }
  }, [receipt, address, preCreateCount]);

  useEffect(() => {
    setStatus(null);
    setError(null);
    setTxHash(null);
    setJobId(null);
    setPreCreateCount(null);
  }, [address, chainId]);

  const wrongNetwork = isConnected && chainId !== NETWORK.chainId;

  const handleCreate = async () => {
    setError(null);
    setStatus(null);
    setJobId(null);
    try {
      if (clientJobCount !== undefined) {
        setPreCreateCount(BigInt(clientJobCount));
      }
      const value = parseEther(amount || "0");
      const reviewer = preferredReviewer ? getAddress(preferredReviewer) : "0x0000000000000000000000000000000000000000";
      const hash = await writeContractAsync({
        address: escrowAddress,
        abi: escrowAbi,
        functionName: "createJob",
        args: [
          reviewer,
          Number(feeBpsOverride || "0"),
          BigInt(acceptWindowOverride || "0"),
          BigInt(submitWindowOverride || "0"),
        ],
        value,
      });
      setTxHash(hash);
      setStatus("Transaction submitted");
    } catch (err) {
      console.error(err);
      setError(friendlyErrorMessage(err));
    }
  };

  const explorerLink = useMemo(() => {
    if (!txHash) return null;
    return `${NETWORK.explorerBase}/tx/${txHash}`;
  }, [txHash]);

  return (
    <div>
      <h1>Create Job</h1>
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
          <p>Connect a wallet to continue.</p>
          <button onClick={() => connect({ connector: connectors[0] })}>Connect Wallet</button>
        </div>
      )}
      <div className="card">
        <div className="row">
          <label>
            Preferred Reviewer
            <input
              value={preferredReviewer}
              onChange={(event) => setPreferredReviewer(event.target.value)}
              placeholder="0x... (optional)"
            />
          </label>
          <label>
            Fee Bps Override
            <input
              value={feeBpsOverride}
              onChange={(event) => setFeeBpsOverride(event.target.value)}
              placeholder="0"
            />
          </label>
          <label>
            Accept Window Override (seconds)
            <input
              value={acceptWindowOverride}
              onChange={(event) => setAcceptWindowOverride(event.target.value)}
              placeholder="0"
            />
          </label>
          <label>
            Submit Window Override (seconds)
            <input
              value={submitWindowOverride}
              onChange={(event) => setSubmitWindowOverride(event.target.value)}
              placeholder="0"
            />
          </label>
          <label>
            Amount (ETH)
            <input value={amount} onChange={(event) => setAmount(event.target.value)} />
          </label>
        </div>
        <button disabled={!isConnected || wrongNetwork} onClick={handleCreate}>
          Create Job
        </button>
        {status && <p>{status}</p>}
        {error && <p style={{ color: "red" }}>{error}</p>}
        {txHash && (
          <p>
            Tx: <a href={explorerLink ?? "#"}>{shortAddress(txHash)}</a>
          </p>
        )}
        {jobId && <p>Job ID: {jobId}</p>}
      </div>
    </div>
  );
}

function abiEncodePackedAddressCount(address: string, count: bigint) {
  const addressBytes = address.replace(/^0x/, "");
  const countHex = count.toString(16).padStart(64, "0");
  return `0x${addressBytes}${countHex}` as Hex;
}
