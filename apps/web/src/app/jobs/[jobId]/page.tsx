"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import { Hex, keccak256 } from "viem";
import {
  useAccount,
  useChainId,
  useConnect,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { NETWORK } from "@/config/networks";
import { escrowAbi, escrowAddress } from "@/lib/contract";
import { clearEventsCache, fetchJobTimelineEvents, TimelineEntry } from "@/lib/events";
import { friendlyErrorMessage } from "@/lib/errors";
import { formatEther, formatTimestamp, shortAddress } from "@/lib/format";
import { publicClient } from "@/lib/clients";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export default function JobDetailPage() {
  const params = useParams();
  const jobId = (params?.jobId as string | undefined) ?? "";
  const jobIdHex = jobId as Hex;
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const [timeline, setTimeline] = useState<TimelineEntry[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [reportHash, setReportHash] = useState<Hex | null>(null);

  const { data: jobData, refetch: refetchJob } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "jobs",
    args: [jobIdHex],
    query: { enabled: Boolean(jobIdHex) },
  });

  const { data: isAllowlisted } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "isReviewer",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const wrongNetwork = isConnected && chainId !== NETWORK.chainId;

  const refresh = async () => {
    if (!jobIdHex) return;
    clearEventsCache();
    const entries = await fetchJobTimelineEvents(jobIdHex);
    setTimeline(entries);
    await refetchJob();
  };

  useEffect(() => {
    let mounted = true;
    refresh()
      .catch((err) => {
        console.error(err);
        if (!mounted) return;
        setError("Failed to load timeline");
      });
    return () => {
      mounted = false;
    };
  }, [jobIdHex]);

  const statusFromEvents = useMemo(() => {
    const last = timeline[timeline.length - 1];
    if (!last) return "Unknown";
    switch (last.eventName) {
      case "JobCreated":
        return "Open";
      case "JobAccepted":
        return "Accepted";
      case "ReportSubmitted":
        return "Submitted";
      case "JobReleased":
        return "Released";
      case "JobCancelled":
        return "Cancelled";
      case "JobReclaimed":
        return "Reclaimed";
      default:
        return "Unknown";
    }
  }, [timeline]);

  const job = jobData as
    | [
        string,
        string,
        bigint,
        number,
        bigint,
        bigint,
        bigint,
        bigint,
        Hex,
        number
      ]
    | undefined;

  const nowSeconds = BigInt(Math.floor(Date.now() / 1000));
  const acceptDeadline = job ? BigInt(job[6]) : 0n;
  const submitDeadline = job ? BigInt(job[7]) : 0n;

  const canAccept =
    statusFromEvents === "Open" &&
    isConnected &&
    !wrongNetwork &&
    isAllowlisted === true &&
    job &&
    (job[1] === ZERO_ADDRESS || job[1].toLowerCase() === address?.toLowerCase());

  const canSubmit =
    statusFromEvents === "Accepted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    job[1].toLowerCase() === address?.toLowerCase() &&
    submitDeadline !== 0n &&
    nowSeconds <= submitDeadline;

  const canAcceptAndRelease =
    statusFromEvents === "Submitted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    job[0].toLowerCase() === address?.toLowerCase() &&
    acceptDeadline !== 0n &&
    nowSeconds <= acceptDeadline;

  const canCancel =
    statusFromEvents === "Open" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    job[0].toLowerCase() === address?.toLowerCase();

  const canReclaim =
    statusFromEvents === "Accepted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    job[0].toLowerCase() === address?.toLowerCase() &&
    submitDeadline !== 0n &&
    nowSeconds > submitDeadline;

  const canAutoRelease =
    statusFromEvents === "Submitted" &&
    isConnected &&
    !wrongNetwork &&
    acceptDeadline !== 0n &&
    nowSeconds > acceptDeadline;

  const handleAction = async (fn: string, args: readonly unknown[] = []) => {
    setError(null);
    setStatus(null);
    try {
      const hash = await writeContractAsync({
        address: escrowAddress,
        abi: escrowAbi,
        functionName: fn as any,
        args: args as any,
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await refresh();
      setStatus("Transaction submitted");
    } catch (err) {
      console.error(err);
      setError(friendlyErrorMessage(err));
    }
  };

  const handleFile = async (file?: File | null) => {
    if (!file) return;
    const buffer = await file.arrayBuffer();
    const hash = keccak256(new Uint8Array(buffer));
    setReportHash(hash);
  };

  return (
    <div>
      <h1>Job Detail</h1>
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
          <p>Connect a wallet to take actions.</p>
          <button onClick={() => connect({ connector: connectors[0] })}>Connect Wallet</button>
        </div>
      )}
      {error && <p style={{ color: "red" }}>{error}</p>}
      {status && <p>{status}</p>}
      <div className="card">
        <h3>Overview</h3>
        <p>Job ID: {jobId}</p>
        <p>Status: {statusFromEvents}</p>
        <p>Client: {shortAddress(job?.[0])}</p>
        <p>Reviewer: {shortAddress(job?.[1])}</p>
        <p>Amount: {formatEther(job?.[2])}</p>
        <p>Fee Bps: {job?.[3] ?? "-"}</p>
        <p>Created: {formatTimestamp(job?.[4])}</p>
        <p>Accept Deadline: {formatTimestamp(job?.[6])}</p>
        <p>Submit Deadline: {formatTimestamp(job?.[7])}</p>
        <p>Report Hash: {job?.[8] ?? "-"}</p>
      </div>

      <div className="card">
        <h3>Actions</h3>
        {canAccept && <button onClick={() => handleAction("acceptJob", [jobIdHex])}>Accept</button>}
        {canCancel && <button onClick={() => handleAction("cancelJob", [jobIdHex])}>Cancel</button>}
        {canReclaim && (
          <button onClick={() => handleAction("reclaimAfterNoSubmit", [jobIdHex])}>Reclaim</button>
        )}
        {canAcceptAndRelease && (
          <button onClick={() => handleAction("acceptAndRelease", [jobIdHex])}>Accept + Release</button>
        )}
        {canAutoRelease && (
          <button onClick={() => handleAction("autoRelease", [jobIdHex])}>Auto Release</button>
        )}
        {canSubmit && (
          <div style={{ marginTop: 12 }}>
            <input type="file" onChange={(event) => handleFile(event.target.files?.[0])} />
            {reportHash && <p>reportHash: {reportHash}</p>}
            <button
              disabled={!reportHash}
              onClick={() => handleAction("submitReportHash", [jobIdHex, reportHash])}
            >
              Submit Report Hash
            </button>
          </div>
        )}
      </div>

      <div className="card">
        <h3>Timeline</h3>
        {timeline.length === 0 && <p>No events yet.</p>}
        {timeline.map((entry) => (
          <div key={entry.key} style={{ marginBottom: 12 }}>
            <strong>{entry.eventName}</strong>
            <div>Block: {entry.blockNumber.toString()}</div>
            <div>Tx: {entry.transactionHash}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
