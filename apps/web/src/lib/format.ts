export function shortAddress(address?: string) {
  if (!address) return "";
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

export function formatTimestamp(seconds?: bigint | number) {
  if (!seconds) return "-";
  const value = typeof seconds === "bigint" ? Number(seconds) : seconds;
  if (!value) return "-";
  return new Date(value * 1000).toLocaleString();
}

export function formatEther(value?: bigint) {
  if (value === undefined) return "-";
  const whole = value / 10n ** 18n;
  const fraction = value % 10n ** 18n;
  if (fraction === 0n) return `${whole} ETH`;
  const fractionStr = fraction.toString().padStart(18, "0").slice(0, 6);
  return `${whole}.${fractionStr} ETH`;
}
