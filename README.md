# Gravity LaunchPass Escrow (Stage 1)

## Stage 1 State Machine
Statuses:
- Open
- Accepted
- Submitted
- Released
- Cancelled
- Reclaimed

Allowed transitions:
- Open -> Accepted (allowlisted reviewer)
- Open -> Cancelled (client)
- Accepted -> Submitted (assigned reviewer, before submitDeadline)
- Accepted -> Reclaimed (client, only after submitDeadline, if no reportHash submitted)
- Submitted -> Released (client, only before acceptDeadline)
- Submitted -> Released (anyone, via autoRelease, only after acceptDeadline)

## Job ID
`jobId = keccak256(abi.encodePacked(client, clientJobCount[client]))`

## Deadlines
- `submitDeadline` is derived from job creation time: `createdAt + submitWindowSeconds`.
- `acceptWindowSeconds` is stored per job.
- `acceptDeadline` is derived from report submission time: `submitTimestamp + acceptWindowSeconds`.

## reportHash
Compute offchain as `keccak256` of the raw report file bytes. Submit the resulting `bytes32` hash onchain.

## Tests
Run:
- `forge test`

## Deployment (Gravity Testnet)
Set env vars `RPC_URL` and `PRIVATE_KEY`, then run:
- `forge script contracts/scripts/DeployGravityLaunchPassEscrow.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast`

## Stage 2 Web App
Location: `apps/web`

### Env Vars
Set in `apps/web/.env.local`:
- `NEXT_PUBLIC_CHAIN_ID`
- `NEXT_PUBLIC_RPC_URL`
- `NEXT_PUBLIC_ESCROW_ADDRESS`
- `NEXT_PUBLIC_EXPLORER_BASE`
- `NEXT_PUBLIC_START_BLOCK`

### Run Web App
From `apps/web`:
- `npm install`
- `npm run dev`

### Start Block
The app scans events starting from `NEXT_PUBLIC_START_BLOCK` to limit log queries.

### reportHash
The reviewer flow computes `reportHash = keccak256(raw file bytes)` before submitting onchain.

### Timeline Note
Withdrawal events are global and not tied to a specific jobId, so they are not shown in the job timeline.

### Manual Test Checklist
1. Connect wallet and ensure Gravity testnet.
2. Create job with amount.
3. Accept job as allowlisted reviewer.
4. Submit report file and reportHash.
5. Accept and release as client.
6. Withdraw as reviewer and owner.
7. Create second job and test cancel.
8. Create third job and test reclaim after no submit. Simulate on testnet by waiting past submitDeadline or using a short submit window override.
