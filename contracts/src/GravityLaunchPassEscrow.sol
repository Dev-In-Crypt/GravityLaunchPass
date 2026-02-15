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
        Reclaimed
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

    uint16 public constant MAX_FEE_BPS = 1000;

    mapping(address => bool) public isReviewer;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => uint256) public clientJobCount;
    mapping(bytes32 => Job) public jobs;

    uint16 public defaultFeeBps = 500;
    uint64 public defaultAcceptWindowSeconds = 3 days;
    uint64 public defaultSubmitWindowSeconds = 7 days;

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
}
