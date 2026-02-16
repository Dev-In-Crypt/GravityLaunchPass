// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "./oz/Ownable.sol";
import {ReentrancyGuard} from "./oz/ReentrancyGuard.sol";

contract GravityLaunchPassEscrow is Ownable, ReentrancyGuard {
    enum Status {
        Open,
        Accepted,
        Submitted,
        Released,
        Cancelled,
        Reclaimed,
        Disputed,
        ResolvedRefunded,
        ResolvedSplit
    }

    enum DisputeOutcome {
        ReleaseToReviewer,
        RefundToClient,
        Split
    }

    struct Job {
        address client;
        address reviewer;
        uint256 amount;
        uint16 feeBps;
        uint64 createdAt;
        uint64 acceptWindowSeconds;
        uint64 acceptDeadline;
        uint64 submitDeadline;
        bytes32 reportHash;
        Status status;
    }

    struct DisputeCore {
        bool exists;
        uint64 openedAt;
        uint64 voteDeadline;
        address[3] arbitrators;
        bool clientDeposited;
        bool reviewerDeposited;
        uint256 clientDepositAmount;
        uint256 reviewerDepositAmount;
        uint256 depositAmount;
        bool resolved;
        DisputeOutcome resolvedOutcome;
        uint16 resolvedReviewerBps;
    }

    struct Vote {
        bool exists;
        DisputeOutcome outcome;
        uint16 reviewerBps;
    }

    uint16 public constant MAX_FEE_BPS = 1000;

    mapping(address => bool) public isReviewer;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => uint256) public clientJobCount;
    mapping(bytes32 => Job) public jobs;
    mapping(address => bool) public isArbitrator;

    mapping(bytes32 => DisputeCore) private disputes;
    mapping(bytes32 => mapping(address => Vote)) private disputeVotes;
    mapping(bytes32 => uint8) private disputeReleaseCount;
    mapping(bytes32 => uint8) private disputeRefundCount;
    mapping(bytes32 => mapping(uint16 => uint8)) private disputeSplitCounts;

    address[] private arbitrators;
    mapping(address => uint256) private arbitratorIndex;

    uint16 public defaultFeeBps = 500;
    uint64 public defaultAcceptWindowSeconds = 3 days;
    uint64 public defaultSubmitWindowSeconds = 7 days;
    uint256 public disputeDepositAmount;
    uint64 public voteWindowSeconds;

    event JobCreated(
        bytes32 jobId,
        address client,
        address preferredReviewer,
        uint256 amount,
        uint16 feeBps,
        uint64 acceptDeadline,
        uint64 submitDeadline
    );
    event JobAccepted(bytes32 jobId, address reviewer);
    event JobCancelled(bytes32 jobId, address client, uint256 amount);
    event ReportSubmitted(bytes32 jobId, address reviewer, bytes32 reportHash);
    event JobReleased(
        bytes32 jobId,
        address client,
        address reviewer,
        uint256 amount,
        uint256 fee,
        bytes32 reportHash
    );
    event JobReclaimed(bytes32 jobId, address client, uint256 amount);
    event Withdrawal(address account, uint256 amount);
    event ReviewerAllowlistUpdated(address reviewer, bool allowed);
    event ConfigUpdated(
        uint16 defaultFeeBps,
        uint64 defaultAcceptWindowSeconds,
        uint64 defaultSubmitWindowSeconds
    );
    event DisputeOpened(
        bytes32 jobId,
        address client,
        address reviewer,
        address[3] arbitrators,
        uint64 voteDeadline
    );
    event DisputeDepositPosted(bytes32 jobId, address party, uint256 amount);
    event DisputeVoteCast(bytes32 jobId, address arbitrator, DisputeOutcome outcome, uint16 reviewerBps);
    event DisputeResolved(bytes32 jobId, DisputeOutcome outcome, uint16 reviewerBps);
    event DisputeTimeoutResolved(bytes32 jobId);
    event ArbitratorAllowlistUpdated(address arbitrator, bool allowed);
    event DisputeConfigUpdated(uint256 disputeDepositAmount, uint64 voteWindowSeconds);

    error ZeroAmount();
    error NotAuthorized();
    error InvalidStatus();
    error DeadlineNotReached();
    error DeadlinePassed();
    error NotAllowlistedReviewer();
    error PreferredReviewerMismatch();
    error InvalidReportHash();
    error TransferFailed();
    error InvalidFeeBps();
    error InvalidDisputeConfig();
    error InvalidArbitrator();
    error DuplicateArbitrator();
    error DisputeAlreadyExists();
    error DisputeNotFound();
    error AlreadyDeposited();
    error InvalidDeposit();
    error VoteNotAllowed();
    error AlreadyVoted();
    error InvalidOutcome();
    error DisputeNotReady();
    error DisputeAlreadyResolved();

    constructor() Ownable() ReentrancyGuard() {}

    function setReviewer(address reviewer, bool allowed) external onlyOwner {
        isReviewer[reviewer] = allowed;
        emit ReviewerAllowlistUpdated(reviewer, allowed);
    }

    function updateConfig(
        uint16 feeBps,
        uint64 acceptWindowSeconds,
        uint64 submitWindowSeconds
    ) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) {
            revert InvalidFeeBps();
        }
        defaultFeeBps = feeBps;
        defaultAcceptWindowSeconds = acceptWindowSeconds;
        defaultSubmitWindowSeconds = submitWindowSeconds;
        emit ConfigUpdated(feeBps, acceptWindowSeconds, submitWindowSeconds);
    }

    function setDisputeDepositAmount(uint256 newAmount) external onlyOwner {
        disputeDepositAmount = newAmount;
        emit DisputeConfigUpdated(disputeDepositAmount, voteWindowSeconds);
    }

    function setVoteWindowSeconds(uint64 newSeconds) external onlyOwner {
        voteWindowSeconds = newSeconds;
        emit DisputeConfigUpdated(disputeDepositAmount, voteWindowSeconds);
    }

    function setArbitrator(address arbitrator, bool allowed) external onlyOwner {
        if (arbitrator == address(0)) {
            revert InvalidArbitrator();
        }
        if (allowed && arbitrator == owner()) {
            revert InvalidArbitrator();
        }

        bool currentlyAllowed = isArbitrator[arbitrator];
        if (allowed && !currentlyAllowed) {
            arbitrators.push(arbitrator);
            arbitratorIndex[arbitrator] = arbitrators.length;
            isArbitrator[arbitrator] = true;
        } else if (!allowed && currentlyAllowed) {
            uint256 index = arbitratorIndex[arbitrator];
            if (index != 0) {
                uint256 lastIndex = arbitrators.length;
                if (index != lastIndex) {
                    address last = arbitrators[lastIndex - 1];
                    arbitrators[index - 1] = last;
                    arbitratorIndex[last] = index;
                }
                arbitrators.pop();
                arbitratorIndex[arbitrator] = 0;
            }
            isArbitrator[arbitrator] = false;
        }

        emit ArbitratorAllowlistUpdated(arbitrator, allowed);
    }

    function getArbitrators() external view returns (address[] memory) {
        return arbitrators;
    }

    function getDispute(bytes32 jobId) external view returns (DisputeCore memory) {
        return disputes[jobId];
    }

    function getDisputeVote(bytes32 jobId, address arbitrator)
        external
        view
        returns (bool exists, DisputeOutcome outcome, uint16 reviewerBps)
    {
        Vote storage vote = disputeVotes[jobId][arbitrator];
        return (vote.exists, vote.outcome, vote.reviewerBps);
    }

    function getDisputeSplitCount(bytes32 jobId, uint16 reviewerBps) external view returns (uint8) {
        return disputeSplitCounts[jobId][reviewerBps];
    }

    function createJob(
        address preferredReviewer,
        uint16 feeBpsOverride,
        uint64 acceptWindowOverride,
        uint64 submitWindowOverride
    ) external payable returns (bytes32 jobId) {
        if (msg.value == 0) {
            revert ZeroAmount();
        }
        if (preferredReviewer != address(0) && !isReviewer[preferredReviewer]) {
            revert NotAllowlistedReviewer();
        }

        uint16 feeBps = feeBpsOverride == 0 ? defaultFeeBps : feeBpsOverride;
        if (feeBps > MAX_FEE_BPS) {
            revert InvalidFeeBps();
        }

        uint64 acceptWindow =
            acceptWindowOverride == 0 ? defaultAcceptWindowSeconds : acceptWindowOverride;
        uint64 submitWindow =
            submitWindowOverride == 0 ? defaultSubmitWindowSeconds : submitWindowOverride;

        uint256 currentCount = clientJobCount[msg.sender];
        jobId = keccak256(abi.encodePacked(msg.sender, currentCount));
        clientJobCount[msg.sender] = currentCount + 1;

        uint64 createdAt = uint64(block.timestamp);
        uint64 submitDeadline = createdAt + submitWindow;

        jobs[jobId] = Job({
            client: msg.sender,
            reviewer: preferredReviewer,
            amount: msg.value,
            feeBps: feeBps,
            createdAt: createdAt,
            acceptWindowSeconds: acceptWindow,
            acceptDeadline: 0,
            submitDeadline: submitDeadline,
            reportHash: bytes32(0),
            status: Status.Open
        });

        emit JobCreated(
            jobId,
            msg.sender,
            preferredReviewer,
            msg.value,
            feeBps,
            0,
            submitDeadline
        );
    }

    function acceptJob(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) {
            revert InvalidStatus();
        }
        if (!isReviewer[msg.sender]) {
            revert NotAllowlistedReviewer();
        }
        if (job.reviewer != address(0) && job.reviewer != msg.sender) {
            revert PreferredReviewerMismatch();
        }

        job.reviewer = msg.sender;
        job.status = Status.Accepted;

        emit JobAccepted(jobId, msg.sender);
    }

    function cancelJob(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Open) {
            revert InvalidStatus();
        }
        if (job.client != msg.sender) {
            revert NotAuthorized();
        }

        job.status = Status.Cancelled;
        pendingWithdrawals[job.client] += job.amount;

        emit JobCancelled(jobId, job.client, job.amount);
    }

    function submitReportHash(bytes32 jobId, bytes32 reportHash) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Accepted) {
            revert InvalidStatus();
        }
        if (job.reviewer != msg.sender) {
            revert NotAuthorized();
        }
        if (block.timestamp > job.submitDeadline) {
            revert DeadlinePassed();
        }
        if (reportHash == bytes32(0)) {
            revert InvalidReportHash();
        }

        job.reportHash = reportHash;
        job.acceptDeadline = uint64(block.timestamp) + job.acceptWindowSeconds;
        job.status = Status.Submitted;

        emit ReportSubmitted(jobId, msg.sender, reportHash);
    }

    function openDispute(bytes32 jobId, address[3] calldata disputeArbitrators) external payable {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) {
            revert InvalidStatus();
        }
        if (job.client != msg.sender) {
            revert NotAuthorized();
        }
        if (job.acceptDeadline == 0) {
            revert InvalidStatus();
        }
        if (block.timestamp > job.acceptDeadline) {
            revert DeadlinePassed();
        }
        if (disputeDepositAmount == 0 || voteWindowSeconds == 0) {
            revert InvalidDisputeConfig();
        }
        if (msg.value != disputeDepositAmount) {
            revert InvalidDeposit();
        }
        if (disputes[jobId].exists) {
            revert DisputeAlreadyExists();
        }

        for (uint256 i = 0; i < 3; i++) {
            address arbitrator = disputeArbitrators[i];
            if (
                arbitrator == address(0) || arbitrator == job.client || arbitrator == job.reviewer
                    || arbitrator == owner()
            ) {
                revert InvalidArbitrator();
            }
            if (!isArbitrator[arbitrator]) {
                revert InvalidArbitrator();
            }
            for (uint256 j = 0; j < i; j++) {
                if (disputeArbitrators[j] == arbitrator) {
                    revert DuplicateArbitrator();
                }
            }
        }

        DisputeCore storage dispute = disputes[jobId];
        dispute.exists = true;
        dispute.openedAt = uint64(block.timestamp);
        dispute.voteDeadline = uint64(block.timestamp) + voteWindowSeconds;
        dispute.arbitrators = disputeArbitrators;
        dispute.clientDeposited = true;
        dispute.clientDepositAmount = msg.value;
        dispute.depositAmount = msg.value;

        job.status = Status.Disputed;

        emit DisputeOpened(jobId, job.client, job.reviewer, disputeArbitrators, dispute.voteDeadline);
        emit DisputeDepositPosted(jobId, msg.sender, msg.value);
    }

    function postDisputeDeposit(bytes32 jobId) external payable {
        DisputeCore storage dispute = disputes[jobId];
        if (!dispute.exists) {
            revert DisputeNotFound();
        }
        if (dispute.resolved) {
            revert DisputeAlreadyResolved();
        }
        Job storage job = jobs[jobId];
        if (job.status != Status.Disputed) {
            revert InvalidStatus();
        }
        if (msg.value != dispute.depositAmount) {
            revert InvalidDeposit();
        }

        if (msg.sender == job.client) {
            if (dispute.clientDeposited) {
                revert AlreadyDeposited();
            }
            dispute.clientDeposited = true;
            dispute.clientDepositAmount = msg.value;
        } else if (msg.sender == job.reviewer) {
            if (dispute.reviewerDeposited) {
                revert AlreadyDeposited();
            }
            dispute.reviewerDeposited = true;
            dispute.reviewerDepositAmount = msg.value;
        } else {
            revert NotAuthorized();
        }

        emit DisputeDepositPosted(jobId, msg.sender, msg.value);
    }

    function voteDispute(bytes32 jobId, uint8 outcome, uint16 reviewerBps) external {
        DisputeCore storage dispute = disputes[jobId];
        if (!dispute.exists) {
            revert DisputeNotFound();
        }
        if (dispute.resolved) {
            revert DisputeAlreadyResolved();
        }
        if (block.timestamp > dispute.voteDeadline) {
            revert DeadlinePassed();
        }
        if (!_isDisputeArbitrator(dispute.arbitrators, msg.sender)) {
            revert VoteNotAllowed();
        }

        Vote storage existing = disputeVotes[jobId][msg.sender];
        if (existing.exists) {
            revert AlreadyVoted();
        }
        if (outcome > uint8(DisputeOutcome.Split)) {
            revert InvalidOutcome();
        }

        DisputeOutcome decodedOutcome = DisputeOutcome(outcome);
        if (decodedOutcome == DisputeOutcome.Split) {
            if (reviewerBps > 10_000) {
                revert InvalidOutcome();
            }
        } else {
            if (reviewerBps != 0) {
                revert InvalidOutcome();
            }
        }

        existing.exists = true;
        existing.outcome = decodedOutcome;
        existing.reviewerBps = reviewerBps;

        if (decodedOutcome == DisputeOutcome.ReleaseToReviewer) {
            disputeReleaseCount[jobId] += 1;
        } else if (decodedOutcome == DisputeOutcome.RefundToClient) {
            disputeRefundCount[jobId] += 1;
        } else {
            disputeSplitCounts[jobId][reviewerBps] += 1;
        }

        emit DisputeVoteCast(jobId, msg.sender, decodedOutcome, reviewerBps);
    }

    function resolveDispute(bytes32 jobId) external {
        DisputeCore storage dispute = disputes[jobId];
        if (!dispute.exists) {
            revert DisputeNotFound();
        }
        if (dispute.resolved) {
            revert DisputeAlreadyResolved();
        }
        if (!dispute.clientDeposited || !dispute.reviewerDeposited) {
            revert DisputeNotReady();
        }
        Job storage job = jobs[jobId];
        if (job.status != Status.Disputed) {
            revert InvalidStatus();
        }

        (bool decided, DisputeOutcome outcome, uint16 reviewerBps) =
            _hasDecision(jobId, dispute.arbitrators);
        if (!decided) {
            revert DisputeNotReady();
        }

        _finalizeDispute(jobId, job, dispute, outcome, reviewerBps);
        emit DisputeResolved(jobId, outcome, reviewerBps);
    }

    function resolveDisputeTimeout(bytes32 jobId) external {
        DisputeCore storage dispute = disputes[jobId];
        if (!dispute.exists) {
            revert DisputeNotFound();
        }
        if (dispute.resolved) {
            revert DisputeAlreadyResolved();
        }
        if (block.timestamp <= dispute.voteDeadline) {
            revert DeadlineNotReached();
        }

        Job storage job = jobs[jobId];
        if (job.status != Status.Disputed) {
            revert InvalidStatus();
        }

        (bool decided, DisputeOutcome outcome, uint16 reviewerBps) =
            _hasDecision(jobId, dispute.arbitrators);

        if (decided) {
            _finalizeDispute(jobId, job, dispute, outcome, reviewerBps);
            emit DisputeResolved(jobId, outcome, reviewerBps);
        } else {
            _finalizeDispute(jobId, job, dispute, DisputeOutcome.RefundToClient, 0);
            emit DisputeTimeoutResolved(jobId);
        }
    }

    function acceptAndRelease(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) {
            revert InvalidStatus();
        }
        if (job.client != msg.sender) {
            revert NotAuthorized();
        }
        if (job.acceptDeadline == 0) {
            revert InvalidStatus();
        }
        if (block.timestamp > job.acceptDeadline) {
            revert DeadlinePassed();
        }

        _release(jobId, job);
    }

    function autoRelease(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Submitted) {
            revert InvalidStatus();
        }
        if (job.acceptDeadline == 0) {
            revert InvalidStatus();
        }
        if (block.timestamp <= job.acceptDeadline) {
            revert DeadlineNotReached();
        }

        _release(jobId, job);
    }

    function reclaimAfterNoSubmit(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        if (job.status != Status.Accepted) {
            revert InvalidStatus();
        }
        if (job.client != msg.sender) {
            revert NotAuthorized();
        }
        if (block.timestamp <= job.submitDeadline) {
            revert DeadlineNotReached();
        }

        job.status = Status.Reclaimed;
        pendingWithdrawals[job.client] += job.amount;

        emit JobReclaimed(jobId, job.client, job.amount);
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) {
            revert ZeroAmount();
        }

        pendingWithdrawals[msg.sender] = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit Withdrawal(msg.sender, amount);
    }

    function _release(bytes32 jobId, Job storage job) internal {
        uint256 fee = (job.amount * job.feeBps) / 10_000;
        uint256 payout = job.amount - fee;

        job.status = Status.Released;
        pendingWithdrawals[job.reviewer] += payout;
        pendingWithdrawals[owner()] += fee;

        emit JobReleased(jobId, job.client, job.reviewer, job.amount, fee, job.reportHash);
    }

    function _isDisputeArbitrator(address[3] memory disputeArbitrators, address who)
        internal
        pure
        returns (bool)
    {
        return (disputeArbitrators[0] == who || disputeArbitrators[1] == who
            || disputeArbitrators[2] == who);
    }

    function _matchingSplitVote(bytes32 jobId, address[3] memory disputeArbitrators)
        internal
        view
        returns (bool, uint16)
    {
        Vote storage vote0 = disputeVotes[jobId][disputeArbitrators[0]];
        Vote storage vote1 = disputeVotes[jobId][disputeArbitrators[1]];
        Vote storage vote2 = disputeVotes[jobId][disputeArbitrators[2]];

        if (vote0.exists && vote1.exists && vote0.outcome == DisputeOutcome.Split
            && vote1.outcome == DisputeOutcome.Split && vote0.reviewerBps == vote1.reviewerBps)
        {
            return (true, vote0.reviewerBps);
        }
        if (vote0.exists && vote2.exists && vote0.outcome == DisputeOutcome.Split
            && vote2.outcome == DisputeOutcome.Split && vote0.reviewerBps == vote2.reviewerBps)
        {
            return (true, vote0.reviewerBps);
        }
        if (vote1.exists && vote2.exists && vote1.outcome == DisputeOutcome.Split
            && vote2.outcome == DisputeOutcome.Split && vote1.reviewerBps == vote2.reviewerBps)
        {
            return (true, vote1.reviewerBps);
        }

        return (false, 0);
    }

    function _hasDecision(bytes32 jobId, address[3] memory disputeArbitrators)
        internal
        view
        returns (bool, DisputeOutcome, uint16)
    {
        if (disputeReleaseCount[jobId] >= 2) {
            return (true, DisputeOutcome.ReleaseToReviewer, 0);
        }
        if (disputeRefundCount[jobId] >= 2) {
            return (true, DisputeOutcome.RefundToClient, 0);
        }
        (bool hasSplit, uint16 reviewerBps) = _matchingSplitVote(jobId, disputeArbitrators);
        if (hasSplit) {
            return (true, DisputeOutcome.Split, reviewerBps);
        }
        return (false, DisputeOutcome.ReleaseToReviewer, 0);
    }

    function _finalizeDispute(
        bytes32 jobId,
        Job storage job,
        DisputeCore storage dispute,
        DisputeOutcome outcome,
        uint16 reviewerBps
    ) internal {
        dispute.resolved = true;
        dispute.resolvedOutcome = outcome;
        dispute.resolvedReviewerBps = reviewerBps;

        uint256 totalDeposits = dispute.clientDepositAmount + dispute.reviewerDepositAmount;

        if (outcome == DisputeOutcome.ReleaseToReviewer) {
            uint256 fee = (job.amount * job.feeBps) / 10_000;
            uint256 payout = job.amount - fee;

            job.status = Status.Released;
            pendingWithdrawals[job.reviewer] += payout + totalDeposits;
            pendingWithdrawals[owner()] += fee;

            emit JobReleased(jobId, job.client, job.reviewer, job.amount, fee, job.reportHash);
            return;
        }

        if (outcome == DisputeOutcome.RefundToClient) {
            job.status = Status.ResolvedRefunded;
            pendingWithdrawals[job.client] += job.amount + totalDeposits;
            return;
        }

        uint256 reviewerShare = (job.amount * reviewerBps) / 10_000;
        uint256 clientShare = job.amount - reviewerShare;
        uint256 feeOnReviewer = (reviewerShare * job.feeBps) / 10_000;

        uint256 reviewerDepositShare = (totalDeposits * reviewerBps) / 10_000;
        uint256 clientDepositShare = totalDeposits - reviewerDepositShare;

        job.status = Status.ResolvedSplit;
        pendingWithdrawals[job.reviewer] += reviewerShare - feeOnReviewer + reviewerDepositShare;
        pendingWithdrawals[job.client] += clientShare + clientDepositShare;
        pendingWithdrawals[owner()] += feeOnReviewer;
    }
}
