"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { Hex } from "viem";
import { useAccount, useChainId, useConnect, useReadContract, useSwitchChain, useWriteContract } from "wagmi";
import { NETWORK } from "@/config/networks";
import { clearEventsCache, fetchAllTimelineEvents } from "@/lib/events";
import { friendlyErrorMessage } from "@/lib/errors";
import { formatEther, shortAddress } from "@/lib/format";
import { addressesEqual, normalizeAddress } from "@/lib/address";
import { escrowAbi, escrowAddress } from "@/lib/contract";
import { publicClient } from "@/lib/clients";

const STATUS_LABELS = {
  Open: "Open",
  Accepted: "Accepted",
  Submitted: "Submitted",
  Released: "Released",
  Cancelled: "Cancelled",
  Reclaimed: "Reclaimed",
} as const;

type JobSnapshot = {
  jobId: Hex;
  client?: string;
  reviewer?: string;
  amount?: bigint;
  status: keyof typeof STATUS_LABELS;
  preferredReviewer?: string;
};

export default function JobsPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const [jobs, setJobs] = useState<JobSnapshot[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<"All" | "Open" | "Accepted" | "Submitted">("All");

  const { data: isAllowlisted } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "isReviewer",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  const wrongNetwork = isConnected && chainId !== NETWORK.chainId;

  const refresh = async () => {
    clearEventsCache();
    const entries = await fetchAllTimelineEvents({ bypassCache: true });
    const map = new Map<string, JobSnapshot>();
    for (const entry of entries) {
      const jobId = entry.args.jobId as Hex | undefined;
      if (!jobId) continue;
      const existing = map.get(jobId) ?? { jobId, status: "Open" };
      if (entry.eventName === "JobCreated") {
        existing.client = entry.args.client as string;
        existing.preferredReviewer = entry.args.preferredReviewer as string;
        existing.amount = entry.args.amount as bigint;
        existing.status = "Open";
      }
      if (entry.eventName === "JobAccepted") {
        existing.reviewer = entry.args.reviewer as string;
        existing.status = "Accepted";
      }
      if (entry.eventName === "ReportSubmitted") {
        existing.status = "Submitted";
      }
      if (entry.eventName === "JobReleased") {
        existing.status = "Released";
      }
      if (entry.eventName === "JobCancelled") {
        existing.status = "Cancelled";
      }
      if (entry.eventName === "JobReclaimed") {
        existing.status = "Reclaimed";
      }
      map.set(jobId, existing);
    }
    setJobs(Array.from(map.values()));
  };

  useEffect(() => {
    let mounted = true;
    refresh()
      .catch((err) => {
        console.error(err);
        if (!mounted) return;
        setError("Failed to load jobs");
      });
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    setError(null);
  }, [address, chainId]);

  const filteredJobs = useMemo(() => {
    if (filter === "All") return jobs;
    return jobs.filter((job) => job.status === filter);
  }, [jobs, filter]);

  const handleAccept = async (jobId: Hex) => {
    setError(null);
    try {
      const hash = await writeContractAsync({
        address: escrowAddress,
        abi: escrowAbi,
        functionName: "acceptJob",
        args: [jobId],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await refresh();
    } catch (err) {
      console.error(err);
      setError(friendlyErrorMessage(err));
    }
  };

  return (
    <div>
      <h1>Job Board</h1>
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
          <p>Connect a wallet to see and accept jobs.</p>
          <button onClick={() => connect({ connector: connectors[0] })}>Connect Wallet</button>
        </div>
      )}
      <div className="card">
        <div className="row">
          <label>
            Filter
            <select value={filter} onChange={(event) => setFilter(event.target.value as any)}>
              <option value="All">All</option>
              <option value="Open">Open</option>
              <option value="Accepted">Accepted</option>
              <option value="Submitted">Submitted</option>
            </select>
          </label>
        </div>
      </div>
      {error && <p style={{ color: "red" }}>{error}</p>}
      {filteredJobs.map((job) => {
        const canAccept =
          job.status === "Open" &&
          isConnected &&
          !wrongNetwork &&
          isAllowlisted === true &&
          (!job.preferredReviewer ||
            normalizeAddress(job.preferredReviewer) ===
              "0x0000000000000000000000000000000000000000" ||
            addressesEqual(job.preferredReviewer, address));
        return (
          <div key={job.jobId} className="card">
            <div className="row">
              <span className="badge">{STATUS_LABELS[job.status]}</span>
              <Link href={`/jobs/${job.jobId}`}>View</Link>
            </div>
            <p>Job ID: {job.jobId}</p>
            <p>Client: {shortAddress(job.client)}</p>
            <p>Preferred Reviewer: {shortAddress(job.preferredReviewer)}</p>
            <p>Amount: {formatEther(job.amount)}</p>
            {canAccept && (
              <button onClick={() => handleAccept(job.jobId)}>
                Accept Job
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}
