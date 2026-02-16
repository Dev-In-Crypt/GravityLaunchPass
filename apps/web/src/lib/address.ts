export function normalizeAddress(address?: string | null) {
  return address?.toLowerCase() ?? "";
}

export function addressesEqual(a?: string | null, b?: string | null) {
  if (!a || !b) return false;
  return normalizeAddress(a) === normalizeAddress(b);
}
