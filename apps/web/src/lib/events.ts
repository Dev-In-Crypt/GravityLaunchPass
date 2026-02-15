import type { AbiEvent, Hex, Log } from "viem";
import { decodeEventLog } from "viem";
import { NETWORK } from "@/config/networks";
import { publicClient } from "@/lib/clients";
import { escrowAbi, escrowAddress } from "@/lib/contract";

export type TimelineEntry = {
  key: string;
  eventName: string;
  blockNumber: bigint;
  logIndex: number;
  transactionHash: Hex;
  args: Record<string, unknown>;
};

let cachedAll: TimelineEntry[] | null = null;
let cachedAt = 0;

type EventName =
  | "JobCreated"
  | "JobAccepted"
  | "ReportSubmitted"
  | "JobReleased"
  | "JobCancelled"
  | "JobReclaimed"
  | "Withdrawal";

function getEvent(name: EventName) {
  const event = escrowAbi.find((item) => item.type === "event" && item.name === name) as
    | AbiEvent
    | undefined;
  if (!event) {
    throw new Error(`Missing ABI event ${name}`);
  }
  return event;
}

function toKey(log: Log) {
  return `${log.transactionHash}-${log.logIndex}`;
}

function decodeLog(log: Log) {
  const decoded = decodeEventLog({ abi: escrowAbi, data: log.data, topics: log.topics });
  return {
    key: toKey(log),
    eventName: decoded.eventName,
    blockNumber: log.blockNumber ?? 0n,
    logIndex: log.logIndex ?? 0,
    transactionHash: log.transactionHash as Hex,
    args: decoded.args as Record<string, unknown>,
  };
}

export function clearEventsCache() {
  cachedAll = null;
  cachedAt = 0;
}

export async function fetchAllTimelineEvents(options?: { bypassCache?: boolean }) {
  if (!options?.bypassCache && cachedAll && Date.now() - cachedAt < 30_000) {
    return cachedAll;
  }
  const fromBlock = NETWORK.startBlock;
  const toBlock = await publicClient.getBlockNumber();
  const events = [
    "JobCreated",
    "JobAccepted",
    "ReportSubmitted",
    "JobReleased",
    "JobCancelled",
    "JobReclaimed",
    "Withdrawal",
  ] as const;

  const logs = await Promise.all(
    events.map((eventName) =>
      publicClient.getLogs({
        address: escrowAddress,
        event: getEvent(eventName),
        fromBlock,
        toBlock,
      })
    )
  );

  const flattened = logs.flat();
  const unique = new Map<string, Log>();
  for (const log of flattened) {
    unique.set(toKey(log), log);
  }

  const decoded = Array.from(unique.values())
    .map(decodeLog)
    .sort((a, b) => {
      if (a.blockNumber === b.blockNumber) {
        return a.logIndex - b.logIndex;
      }
      return a.blockNumber > b.blockNumber ? 1 : -1;
    });
  cachedAll = decoded;
  cachedAt = Date.now();
  return decoded;
}

export async function fetchJobTimelineEvents(jobId: Hex) {
  const fromBlock = NETWORK.startBlock;
  const toBlock = await publicClient.getBlockNumber();
  const events = [
    "JobCreated",
    "JobAccepted",
    "ReportSubmitted",
    "JobReleased",
    "JobCancelled",
    "JobReclaimed",
  ] as const;

  const logs = await Promise.all(
    events.map((eventName) =>
      publicClient.getLogs({
        address: escrowAddress,
        event: getEvent(eventName),
        fromBlock,
        toBlock,
      })
    )
  );

  const flattened = logs.flat();
  const unique = new Map<string, Log>();
  for (const log of flattened) {
    unique.set(toKey(log), log);
  }

  const decoded = Array.from(unique.values())
    .map(decodeLog)
    .sort((a, b) => {
      if (a.blockNumber === b.blockNumber) {
        return a.logIndex - b.logIndex;
      }
      return a.blockNumber > b.blockNumber ? 1 : -1;
    });

  return decoded.filter((entry) => {
    const entryJobId = entry.args.jobId as Hex | undefined;
    return entryJobId?.toLowerCase() === jobId.toLowerCase();
  });
}
