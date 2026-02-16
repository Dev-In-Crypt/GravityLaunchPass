"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import { Hex, isAddress, keccak256 } from "viem";
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
import { addressesEqual, normalizeAddress } from "@/lib/address";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export default function JobDetailPage() {
  const params = useParams();
  const jobId = (params?.jobId as string | undefined) ?? "";
  const jobIdHex = jobId as Hex;
  const [mounted, setMounted] = useState(false);
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { switchChain } = useSwitchChain();
  const { writeContractAsync } = useWriteContract();
  const [timeline, setTimeline] = useState<TimelineEntry[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [reportHash, setReportHash] = useState<Hex | null>(null);
  const [disputeArbitrators, setDisputeArbitrators] = useState<string[]>(["", "", ""]);
  const [voteOutcome, setVoteOutcome] = useState<"Release" | "Refund" | "Split">("Release");
  const [voteReviewerBps, setVoteReviewerBps] = useState("5000");

  const { data: jobData, refetch: refetchJob } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "jobs",
    args: [jobIdHex],
    query: { enabled: mounted && Boolean(jobIdHex) },
  });

  const { data: isAllowlisted } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "isReviewer",
    args: address ? [address] : undefined,
    query: { enabled: mounted && !!address },
  });

  const { data: disputeDepositAmount } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "disputeDepositAmount",
    query: { enabled: mounted },
  });

  const { data: voteWindowSeconds } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "voteWindowSeconds",
    query: { enabled: mounted },
  });

  const { data: disputeData, refetch: refetchDispute } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "getDispute",
    args: [jobIdHex],
    query: { enabled: mounted && Boolean(jobIdHex) },
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
    setMounted(true);
  }, []);

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

  useEffect(() => {
    setError(null);
    setStatus(null);
    setReportHash(null);
    setDisputeArbitrators(["", "", ""]);
    setVoteOutcome("Release");
    setVoteReviewerBps("5000");
  }, [address, chainId]);

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
      case "DisputeOpened":
        return "Disputed";
      case "DisputeDepositPosted":
        return "Disputed";
      case "DisputeVoteCast":
        return "Disputed";
      case "DisputeResolved": {
        const outcome = last.args.outcome as number | undefined;
        if (outcome === 0) return "Released";
        if (outcome === 1) return "ResolvedRefunded";
        if (outcome === 2) return "ResolvedSplit";
        return "Unknown";
      }
      case "DisputeTimeoutResolved":
        return "ResolvedRefunded";
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
    (normalizeAddress(job[1]) === ZERO_ADDRESS || addressesEqual(job[1], address));

  const canSubmit =
    statusFromEvents === "Accepted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    addressesEqual(job[1], address) &&
    submitDeadline !== 0n &&
    nowSeconds <= submitDeadline;

  const canAcceptAndRelease =
    statusFromEvents === "Submitted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    addressesEqual(job[0], address) &&
    acceptDeadline !== 0n &&
    nowSeconds <= acceptDeadline;

  const canCancel =
    statusFromEvents === "Open" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    addressesEqual(job[0], address);

  const canReclaim =
    statusFromEvents === "Accepted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    addressesEqual(job[0], address) &&
    submitDeadline !== 0n &&
    nowSeconds > submitDeadline;

  const canAutoRelease =
    statusFromEvents === "Submitted" &&
    isConnected &&
    !wrongNetwork &&
    acceptDeadline !== 0n &&
    nowSeconds > acceptDeadline;

  const handleAction = async (
    fn: string,
    args: readonly unknown[] = [],
    value?: bigint
  ) => {
    setError(null);
    setStatus(null);
    try {
      const hash = await writeContractAsync({
        address: escrowAddress,
        abi: escrowAbi,
        functionName: fn as any,
        args: args as any,
        value,
      });
      await publicClient.waitForTransactionReceipt({ hash });
      await refresh();
      await refetchDispute();
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

  if (!mounted) {
    return (
      <div>
        <h1>Job Detail</h1>
        <div className="card">
          <p>Loading job...</p>
        </div>
      </div>
    );
  }

  const dispute = disputeData as
    | [
        boolean,
        bigint,
        bigint,
        readonly [string, string, string],
        boolean,
        boolean,
        bigint,
        bigint,
        bigint,
        boolean,
        number,
        number
      ]
    | undefined;

  const disputeExists = dispute?.[0] ?? false;
  const disputeOpenedAt = dispute?.[1] ?? 0n;
  const disputeVoteDeadline = dispute?.[2] ?? 0n;
  const disputeArbList = dispute?.[3] ?? ["", "", ""];
  const disputeClientDeposited = dispute?.[4] ?? false;
  const disputeReviewerDeposited = dispute?.[5] ?? false;
  const disputeClientDepositAmount = dispute?.[6] ?? 0n;
  const disputeReviewerDepositAmount = dispute?.[7] ?? 0n;
  const disputeDepositSnapshot = dispute?.[8] ?? 0n;
  const disputeResolved = dispute?.[9] ?? false;
  const disputeResolvedOutcome = dispute?.[10] ?? 0;
  const disputeResolvedReviewerBps = dispute?.[11] ?? 0;

  const { data: arbVote1 } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "getDisputeVote",
    args: disputeArbList[0] ? [jobIdHex, disputeArbList[0]] : undefined,
    query: { enabled: mounted && disputeExists && !!disputeArbList[0] },
  });

  const { data: arbVote2 } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "getDisputeVote",
    args: disputeArbList[1] ? [jobIdHex, disputeArbList[1]] : undefined,
    query: { enabled: mounted && disputeExists && !!disputeArbList[1] },
  });

  const { data: arbVote3 } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "getDisputeVote",
    args: disputeArbList[2] ? [jobIdHex, disputeArbList[2]] : undefined,
    query: { enabled: mounted && disputeExists && !!disputeArbList[2] },
  });

  const voteEntries = [arbVote1, arbVote2, arbVote3].map((vote) => {
    const tuple = vote as [boolean, number, number] | undefined;
    return {
      exists: tuple?.[0] ?? false,
      outcome: tuple?.[1] ?? 0,
      reviewerBps: tuple?.[2] ?? 0,
    };
  });

  const hasMatchingVotes = useMemo(() => {
    let releaseCount = 0;
    let refundCount = 0;
    const splitCounts = new Map<number, number>();

    for (const vote of voteEntries) {
      if (!vote.exists) continue;
      if (vote.outcome === 0) releaseCount += 1;
      if (vote.outcome === 1) refundCount += 1;
      if (vote.outcome === 2) {
        const current = splitCounts.get(vote.reviewerBps) ?? 0;
        splitCounts.set(vote.reviewerBps, current + 1);
      }
    }

    if (releaseCount >= 2 || refundCount >= 2) return true;
    for (const count of splitCounts.values()) {
      if (count >= 2) return true;
    }
    return false;
  }, [voteEntries]);

  const isDisputeArbitrator =
    addressesEqual(disputeArbList[0], address) ||
    addressesEqual(disputeArbList[1], address) ||
    addressesEqual(disputeArbList[2], address);

  const canOpenDispute =
    statusFromEvents === "Submitted" &&
    isConnected &&
    !wrongNetwork &&
    job &&
    addressesEqual(job[0], address) &&
    acceptDeadline !== 0n &&
    nowSeconds <= acceptDeadline &&
    !disputeExists;

  const canPostClientDeposit =
    disputeExists &&
    !disputeResolved &&
    addressesEqual(job?.[0], address) &&
    !disputeClientDeposited;

  const canPostReviewerDeposit =
    disputeExists &&
    !disputeResolved &&
    addressesEqual(job?.[1], address) &&
    !disputeReviewerDeposited;

  const canVote =
    disputeExists &&
    !disputeResolved &&
    isDisputeArbitrator &&
    statusFromEvents === "Disputed" &&
    isConnected &&
    !wrongNetwork;

  const canResolve =
    disputeExists &&
    !disputeResolved &&
    disputeClientDeposited &&
    disputeReviewerDeposited &&
    hasMatchingVotes &&
    isConnected &&
    !wrongNetwork;

  const canResolveTimeout =
    disputeExists &&
    !disputeResolved &&
    disputeVoteDeadline !== 0n &&
    nowSeconds > disputeVoteDeadline &&
    isConnected &&
    !wrongNetwork;

  const arbInput0 = disputeArbitrators[0];
  const arbInput1 = disputeArbitrators[1];
  const arbInput2 = disputeArbitrators[2];

  const arb0Valid = isAddress(arbInput0);
  const arb1Valid = isAddress(arbInput1);
  const arb2Valid = isAddress(arbInput2);

  const { data: arb0Allowlisted } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "isArbitrator",
    args: arb0Valid ? [arbInput0] : undefined,
    query: { enabled: mounted && arb0Valid },
  });

  const { data: arb1Allowlisted } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "isArbitrator",
    args: arb1Valid ? [arbInput1] : undefined,
    query: { enabled: mounted && arb1Valid },
  });

  const { data: arb2Allowlisted } = useReadContract({
    address: escrowAddress,
    abi: escrowAbi,
    functionName: "isArbitrator",
    args: arb2Valid ? [arbInput2] : undefined,
    query: { enabled: mounted && arb2Valid },
  });

  const disputeInputsNormalized = [
    normalizeAddress(arbInput0),
    normalizeAddress(arbInput1),
    normalizeAddress(arbInput2),
  ];
  const disputeInputsUnique = new Set(disputeInputsNormalized).size === 3;
  const disputeInputsNonZero = disputeInputsNormalized.every(
    (value) => value !== "" && value !== ZERO_ADDRESS
  );
  const disputeInputsNotParties =
    disputeInputsNormalized.every((value) => value !== normalizeAddress(job?.[0])) &&
    disputeInputsNormalized.every((value) => value !== normalizeAddress(job?.[1]));
  const disputeInputsAllowlisted =
    arb0Allowlisted === true && arb1Allowlisted === true && arb2Allowlisted === true;
  const disputeInputsValid =
    arb0Valid &&
    arb1Valid &&
    arb2Valid &&
    disputeInputsUnique &&
    disputeInputsNonZero &&
    disputeInputsNotParties &&
    disputeInputsAllowlisted;

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
        <h3>Dispute</h3>
        <p>
          Deposit:{" "}
          {formatEther(
            disputeExists
              ? (disputeDepositSnapshot as bigint | undefined)
              : (disputeDepositAmount as bigint | undefined)
          )}
        </p>
        <p>Vote Window (seconds): {voteWindowSeconds?.toString() ?? "-"}</p>
        {disputeExists && (
          <>
            <p>Opened: {formatTimestamp(disputeOpenedAt)}</p>
            <p>Vote Deadline: {formatTimestamp(disputeVoteDeadline)}</p>
            <p>Arbitrators: {disputeArbList.map(shortAddress).join(", ")}</p>
            <p>Client Deposit: {disputeClientDeposited ? "Paid" : "Missing"}</p>
            <p>Reviewer Deposit: {disputeReviewerDeposited ? "Paid" : "Missing"}</p>
            {disputeResolved && (
              <p>
                Resolved:{" "}
                {disputeResolvedOutcome === 0
                  ? "Release to Reviewer"
                  : disputeResolvedOutcome === 1
                    ? "Refund to Client"
                    : "Split"}{" "}
                {disputeResolvedOutcome === 2 ? `(reviewerBps ${disputeResolvedReviewerBps})` : ""}
              </p>
            )}
          </>
        )}

        {canOpenDispute && (
          <div style={{ marginTop: 12 }}>
            <p>Open dispute (client only)</p>
            <input
              placeholder="Arbitrator 1 address"
              value={arbInput0}
              onChange={(event) =>
                setDisputeArbitrators([event.target.value, arbInput1, arbInput2])
              }
            />
            <input
              placeholder="Arbitrator 2 address"
              value={arbInput1}
              onChange={(event) =>
                setDisputeArbitrators([arbInput0, event.target.value, arbInput2])
              }
            />
            <input
              placeholder="Arbitrator 3 address"
              value={arbInput2}
              onChange={(event) =>
                setDisputeArbitrators([arbInput0, arbInput1, event.target.value])
              }
            />
            {!disputeInputsValid && (
              <p style={{ color: "red" }}>
                Arbitrators must be valid, unique, allowlisted, nonzero, and not client/reviewer.
              </p>
            )}
            <button
              disabled={
                !disputeInputsValid ||
                !disputeDepositAmount ||
                disputeDepositAmount === 0n
              }
              onClick={() =>
                handleAction(
                  "openDispute",
                  [jobIdHex, disputeArbitrators as unknown as [string, string, string]],
                  disputeDepositAmount as bigint
                )
              }
            >
              Open Dispute
            </button>
          </div>
        )}

        {canPostClientDeposit && (
          <button
            disabled={
              disputeExists
                ? disputeDepositSnapshot === 0n
                : !disputeDepositAmount || disputeDepositAmount === 0n
            }
            onClick={() =>
              handleAction(
                "postDisputeDeposit",
                [jobIdHex],
                (disputeExists
                  ? (disputeDepositSnapshot as bigint)
                  : (disputeDepositAmount as bigint)) ?? 0n
              )
            }
          >
            Post Client Deposit
          </button>
        )}
        {canPostReviewerDeposit && (
          <button
            disabled={
              disputeExists
                ? disputeDepositSnapshot === 0n
                : !disputeDepositAmount || disputeDepositAmount === 0n
            }
            onClick={() =>
              handleAction(
                "postDisputeDeposit",
                [jobIdHex],
                (disputeExists
                  ? (disputeDepositSnapshot as bigint)
                  : (disputeDepositAmount as bigint)) ?? 0n
              )
            }
          >
            Post Reviewer Deposit
          </button>
        )}

        {canVote && (
          <div style={{ marginTop: 12 }}>
            <p>Vote (arbitrator only)</p>
            <select
              value={voteOutcome}
              onChange={(event) =>
                setVoteOutcome(event.target.value as "Release" | "Refund" | "Split")
              }
            >
              <option value="Release">Release to Reviewer</option>
              <option value="Refund">Refund to Client</option>
              <option value="Split">Split</option>
            </select>
            {voteOutcome === "Split" && (
              <input
                placeholder="Reviewer bps (0-10000)"
                value={voteReviewerBps}
                onChange={(event) => setVoteReviewerBps(event.target.value)}
              />
            )}
            <button
              onClick={() =>
                handleAction("voteDispute", [
                  jobIdHex,
                  voteOutcome === "Release" ? 0 : voteOutcome === "Refund" ? 1 : 2,
                  voteOutcome === "Split" ? Number(voteReviewerBps || "0") : 0,
                ])
              }
            >
              Cast Vote
            </button>
          </div>
        )}

        {canResolve && (
          <button onClick={() => handleAction("resolveDispute", [jobIdHex])}>
            Resolve Dispute
          </button>
        )}

        {canResolveTimeout && (
          <button onClick={() => handleAction("resolveDisputeTimeout", [jobIdHex])}>
            Resolve Timeout
          </button>
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
