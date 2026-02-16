// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GravityLaunchPassEscrow} from "../src/GravityLaunchPassEscrow.sol";

contract GravityLaunchPassEscrowDisputesTest is Test {
    GravityLaunchPassEscrow private escrow;

    address private client = address(0xA11CE);
    address private reviewer = address(0xB0B);
    address private arb1 = address(0xABCD1);
    address private arb2 = address(0xABCD2);
    address private arb3 = address(0xABCD3);
    address private other = address(0xCAFE);

    uint256 private constant JOB_AMOUNT = 1 ether;
    uint256 private constant DISPUTE_DEPOSIT = 0.1 ether;
    uint64 private constant VOTE_WINDOW = 3 days;

    function setUp() public {
        escrow = new GravityLaunchPassEscrow();
        escrow.setReviewer(reviewer, true);
        escrow.setArbitrator(arb1, true);
        escrow.setArbitrator(arb2, true);
        escrow.setArbitrator(arb3, true);
        escrow.setDisputeDepositAmount(DISPUTE_DEPOSIT);
        escrow.setVoteWindowSeconds(VOTE_WINDOW);

        vm.deal(client, 10 ether);
        vm.deal(reviewer, 10 ether);
        vm.deal(arb1, 1 ether);
        vm.deal(arb2, 1 ether);
        vm.deal(arb3, 1 ether);
        vm.deal(other, 1 ether);
    }

    function testHappyPathDisputeReleaseToReviewer() public {
        bytes32 jobId = _createAcceptedSubmittedJob();

        address[3] memory arbitrators = [arb1, arb2, arb3];
        vm.prank(client);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, arbitrators);

        vm.prank(reviewer);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);

        vm.prank(arb1);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);
        vm.prank(arb2);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);

        escrow.resolveDispute(jobId);

        (, , , , , , , , , GravityLaunchPassEscrow.Status status) = escrow.jobs(jobId);
        assertTrue(status == GravityLaunchPassEscrow.Status.Released);

        uint256 fee = (JOB_AMOUNT * escrow.defaultFeeBps()) / 10_000;
        uint256 payout = JOB_AMOUNT - fee;
        uint256 totalDeposits = DISPUTE_DEPOSIT * 2;

        assertEq(escrow.pendingWithdrawals(reviewer), payout + totalDeposits);
        assertEq(escrow.pendingWithdrawals(escrow.owner()), fee);
    }

    function testSplitResolutionAppliesFeeOnlyToReviewerShare() public {
        bytes32 jobId = _createAcceptedSubmittedJob();

        address[3] memory arbitrators = [arb1, arb2, arb3];
        vm.prank(client);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, arbitrators);
        vm.prank(reviewer);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);

        uint16 reviewerBps = 6000;
        vm.prank(arb1);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.Split), reviewerBps);
        vm.prank(arb2);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.Split), reviewerBps);

        escrow.resolveDispute(jobId);

        (, , , , , , , , , GravityLaunchPassEscrow.Status status) = escrow.jobs(jobId);
        assertTrue(status == GravityLaunchPassEscrow.Status.ResolvedSplit);

        uint256 reviewerShare = (JOB_AMOUNT * reviewerBps) / 10_000;
        uint256 clientShare = JOB_AMOUNT - reviewerShare;
        uint256 fee = (reviewerShare * escrow.defaultFeeBps()) / 10_000;

        uint256 totalDeposits = DISPUTE_DEPOSIT * 2;
        uint256 reviewerDepositShare = (totalDeposits * reviewerBps) / 10_000;
        uint256 clientDepositShare = totalDeposits - reviewerDepositShare;

        assertEq(escrow.pendingWithdrawals(reviewer), reviewerShare - fee + reviewerDepositShare);
        assertEq(escrow.pendingWithdrawals(client), clientShare + clientDepositShare);
        assertEq(escrow.pendingWithdrawals(escrow.owner()), fee);
    }

    function testOpenDisputeOnlySubmitted() public {
        bytes32 jobId = _createJob();
        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        address[3] memory arbitrators = [arb1, arb2, arb3];
        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, arbitrators);
    }

    function testOpenDisputeAfterAcceptDeadlineReverts() public {
        bytes32 jobId = _createAcceptedSubmittedJob();
        (, , , , , , uint64 acceptDeadline, , , ) = escrow.jobs(jobId);
        vm.warp(acceptDeadline + 1);

        address[3] memory arbitrators = [arb1, arb2, arb3];
        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.DeadlinePassed.selector);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, arbitrators);
    }

    function testOpenDisputeRejectsInvalidArbitrators() public {
        bytes32 jobId = _createAcceptedSubmittedJob();
        address[3] memory duplicate = [arb1, arb1, arb2];

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.DuplicateArbitrator.selector);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, duplicate);

        address[3] memory notAllowed = [arb1, arb2, other];
        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidArbitrator.selector);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, notAllowed);
    }

    function testVotingRules() public {
        bytes32 jobId = _openDispute();

        vm.prank(other);
        vm.expectRevert(GravityLaunchPassEscrow.VoteNotAllowed.selector);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);

        vm.prank(arb1);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);

        vm.prank(arb1);
        vm.expectRevert(GravityLaunchPassEscrow.AlreadyVoted.selector);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);

        vm.prank(arb2);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidOutcome.selector);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.Split), 10001);
    }

    function testResolveRequiresDepositsAndMatchingVotes() public {
        bytes32 jobId = _openDispute();

        vm.prank(arb1);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);
        vm.prank(arb2);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.RefundToClient), 0);

        vm.expectRevert(GravityLaunchPassEscrow.DisputeNotReady.selector);
        escrow.resolveDispute(jobId);

        vm.prank(reviewer);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);

        vm.expectRevert(GravityLaunchPassEscrow.DisputeNotReady.selector);
        escrow.resolveDispute(jobId);
    }

    function testTimeoutResolution() public {
        bytes32 jobId = _openDispute();

        vm.prank(reviewer);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);

        GravityLaunchPassEscrow.DisputeCore memory dispute = escrow.getDispute(jobId);
        vm.warp(uint256(dispute.voteDeadline) + 1);

        escrow.resolveDisputeTimeout(jobId);

        (, , , , , , , , , GravityLaunchPassEscrow.Status status) = escrow.jobs(jobId);
        assertTrue(status == GravityLaunchPassEscrow.Status.ResolvedRefunded);
    }

    function testTimeoutWithDecisionUsesRelease() public {
        bytes32 jobId = _openDispute();

        vm.prank(reviewer);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);

        vm.prank(arb1);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);
        vm.prank(arb2);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);

        GravityLaunchPassEscrow.DisputeCore memory dispute = escrow.getDispute(jobId);
        vm.warp(uint256(dispute.voteDeadline) + 1);

        escrow.resolveDisputeTimeout(jobId);

        (, , , , , , , , , GravityLaunchPassEscrow.Status status) = escrow.jobs(jobId);
        assertTrue(status == GravityLaunchPassEscrow.Status.Released);
    }

    function testTimeoutWithDecisionUsesSplit() public {
        bytes32 jobId = _openDispute();

        vm.prank(reviewer);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);

        uint16 reviewerBps = 7000;
        vm.prank(arb1);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.Split), reviewerBps);
        vm.prank(arb2);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.Split), reviewerBps);

        GravityLaunchPassEscrow.DisputeCore memory dispute = escrow.getDispute(jobId);
        vm.warp(uint256(dispute.voteDeadline) + 1);

        escrow.resolveDisputeTimeout(jobId);

        (, , , , , , , , , GravityLaunchPassEscrow.Status status) = escrow.jobs(jobId);
        assertTrue(status == GravityLaunchPassEscrow.Status.ResolvedSplit);
    }

    function testVoteAfterDeadlineReverts() public {
        bytes32 jobId = _openDispute();

        GravityLaunchPassEscrow.DisputeCore memory dispute = escrow.getDispute(jobId);
        vm.warp(uint256(dispute.voteDeadline) + 1);

        vm.prank(arb1);
        vm.expectRevert(GravityLaunchPassEscrow.DeadlinePassed.selector);
        escrow.voteDispute(jobId, uint8(GravityLaunchPassEscrow.DisputeOutcome.ReleaseToReviewer), 0);
    }

    function testDisputedBlocksReleasePaths() public {
        bytes32 jobId = _openDispute();

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.acceptAndRelease(jobId);

        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.autoRelease(jobId);
    }

    function testDepositRules() public {
        bytes32 jobId = _openDispute();

        vm.prank(reviewer);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidDeposit.selector);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT - 1}(jobId);

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.AlreadyDeposited.selector);
        escrow.postDisputeDeposit{value: DISPUTE_DEPOSIT}(jobId);
    }

    function _createJob() internal returns (bytes32 jobId) {
        vm.prank(client);
        jobId = escrow.createJob{value: JOB_AMOUNT}(address(0), 0, 0, 0);
    }

    function _createAcceptedSubmittedJob() internal returns (bytes32 jobId) {
        jobId = _createJob();
        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        (, , , , , , , uint64 submitDeadline, , ) = escrow.jobs(jobId);
        vm.warp(uint256(submitDeadline) - 1);
        vm.prank(reviewer);
        escrow.submitReportHash(jobId, keccak256("report"));
    }

    function _openDispute() internal returns (bytes32 jobId) {
        jobId = _createAcceptedSubmittedJob();
        address[3] memory arbitrators = [arb1, arb2, arb3];
        vm.prank(client);
        escrow.openDispute{value: DISPUTE_DEPOSIT}(jobId, arbitrators);
    }
}
