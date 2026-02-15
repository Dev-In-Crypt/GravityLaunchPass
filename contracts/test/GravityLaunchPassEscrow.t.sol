// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GravityLaunchPassEscrow} from "../src/GravityLaunchPassEscrow.sol";

contract GravityLaunchPassEscrowTest is Test {
    GravityLaunchPassEscrow private escrow;

    address private client = address(0xA11CE);
    address private reviewer = address(0xB0B);
    address private other = address(0xCAFE);

    uint256 private constant JOB_AMOUNT = 1 ether;

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

    function setUp() public {
        escrow = new GravityLaunchPassEscrow();
        escrow.setReviewer(reviewer, true);

        vm.deal(client, 10 ether);
        vm.deal(reviewer, 0);
        vm.deal(other, 0);
    }

    function testCreateJobStoresFieldsAndEmits() public {
        vm.warp(1_000_000);
        bytes32 expectedJobId = keccak256(abi.encodePacked(client, uint256(0)));
        uint64 expectedSubmitDeadline = uint64(block.timestamp) + escrow.defaultSubmitWindowSeconds();
        uint64 expectedAcceptWindow = escrow.defaultAcceptWindowSeconds();

        vm.expectEmit(false, false, false, true);
        emit JobCreated(
            expectedJobId,
            client,
            address(0),
            JOB_AMOUNT,
            escrow.defaultFeeBps(),
            0,
            expectedSubmitDeadline
        );

        vm.prank(client);
        bytes32 jobId = escrow.createJob{value: JOB_AMOUNT}(address(0), 0, 0, 0);

        assertEq(jobId, expectedJobId);
        (
            address jobClient,
            address jobReviewer,
            uint256 amount,
            uint16 feeBps,
            uint64 createdAt,
            uint64 acceptWindowSeconds,
            uint64 acceptDeadline,
            uint64 submitDeadline,
            bytes32 reportHash,
            GravityLaunchPassEscrow.Status status
        ) = escrow.jobs(jobId);

        assertEq(jobClient, client);
        assertEq(jobReviewer, address(0));
        assertEq(amount, JOB_AMOUNT);
        assertEq(feeBps, escrow.defaultFeeBps());
        assertEq(createdAt, uint64(block.timestamp));
        assertEq(acceptWindowSeconds, expectedAcceptWindow);
        assertEq(acceptDeadline, 0);
        assertEq(submitDeadline, expectedSubmitDeadline);
        assertEq(reportHash, bytes32(0));
        assertTrue(status == GravityLaunchPassEscrow.Status.Open);
    }

    function testAcceptJobAllowlistOnly() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(other);
        vm.expectRevert(GravityLaunchPassEscrow.NotAllowlistedReviewer.selector);
        escrow.acceptJob(jobId);

        vm.prank(reviewer);
        escrow.acceptJob(jobId);
    }

    function testAcceptJobPreferredReviewerMismatch() public {
        bytes32 jobId = _createJob(reviewer);

        address otherReviewer = address(0xDEAD);
        escrow.setReviewer(otherReviewer, true);

        vm.prank(otherReviewer);
        vm.expectRevert(GravityLaunchPassEscrow.PreferredReviewerMismatch.selector);
        escrow.acceptJob(jobId);
    }

    function testCancelJobOnlyClientAndOpenCreditsPending() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(other);
        vm.expectRevert(GravityLaunchPassEscrow.NotAuthorized.selector);
        escrow.cancelJob(jobId);

        vm.prank(client);
        vm.expectEmit(false, false, false, true);
        emit JobCancelled(jobId, client, JOB_AMOUNT);
        escrow.cancelJob(jobId);

        assertEq(escrow.pendingWithdrawals(client), JOB_AMOUNT);
    }

    function testSubmitReportHashRules() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        vm.prank(other);
        vm.expectRevert(GravityLaunchPassEscrow.NotAuthorized.selector);
        escrow.submitReportHash(jobId, keccak256("report"));

        vm.prank(reviewer);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidReportHash.selector);
        escrow.submitReportHash(jobId, bytes32(0));

        vm.prank(reviewer);
        escrow.submitReportHash(jobId, keccak256("report"));

        vm.prank(reviewer);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.submitReportHash(jobId, keccak256("again"));
    }

    function testSubmitReportHashFromOpenReverts() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.submitReportHash(jobId, keccak256("report"));
    }

    function testAcceptJobAfterAcceptedReverts() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        vm.prank(reviewer);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.acceptJob(jobId);
    }

    function testReclaimAfterNoSubmitOnlyAfterDeadline() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.DeadlineNotReached.selector);
        escrow.reclaimAfterNoSubmit(jobId);

        (, , , , , , , uint64 submitDeadline, , ) = escrow.jobs(jobId);
        vm.warp(submitDeadline + 1);

        vm.prank(client);
        vm.expectEmit(false, false, false, true);
        emit JobReclaimed(jobId, client, JOB_AMOUNT);
        escrow.reclaimAfterNoSubmit(jobId);

        assertEq(escrow.pendingWithdrawals(client), JOB_AMOUNT);
    }

    function testAcceptAndReleaseCreditsReviewerAndOwner() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        bytes32 reportHash = keccak256("report");
        (, , , , , , , uint64 submitDeadline, , ) = escrow.jobs(jobId);
        uint256 submitTimestamp = uint256(submitDeadline) - 1;
        vm.warp(submitTimestamp);
        vm.prank(reviewer);
        escrow.submitReportHash(jobId, reportHash);
        (, , , , , uint64 acceptWindowSeconds, uint64 acceptDeadline, , , ) = escrow.jobs(jobId);
        assertEq(acceptDeadline, uint64(submitTimestamp) + acceptWindowSeconds);

        uint256 fee = (JOB_AMOUNT * escrow.defaultFeeBps()) / 10_000;
        uint256 payout = JOB_AMOUNT - fee;

        vm.prank(client);
        vm.expectEmit(false, false, false, true);
        emit JobReleased(jobId, client, reviewer, JOB_AMOUNT, fee, reportHash);
        escrow.acceptAndRelease(jobId);

        assertEq(escrow.pendingWithdrawals(reviewer), payout);
        assertEq(escrow.pendingWithdrawals(escrow.owner()), fee);
    }

    function testAcceptAndReleaseRevertsAfterAcceptDeadline() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        bytes32 reportHash = keccak256("report");
        (, , , , , , , uint64 submitDeadline, , ) = escrow.jobs(jobId);
        uint256 submitTimestamp = uint256(submitDeadline) - 1;
        vm.warp(submitTimestamp);
        vm.prank(reviewer);
        escrow.submitReportHash(jobId, reportHash);

        (, , , , , , uint64 acceptDeadline, , , ) = escrow.jobs(jobId);
        vm.warp(acceptDeadline + 1);

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.DeadlinePassed.selector);
        escrow.acceptAndRelease(jobId);
    }

    function testAutoReleaseOnlyAfterAcceptDeadline() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        bytes32 reportHash = keccak256("report");
        (, , , , , , , uint64 submitDeadline, , ) = escrow.jobs(jobId);
        uint256 submitTimestamp = uint256(submitDeadline) - 1;
        vm.warp(submitTimestamp);
        vm.prank(reviewer);
        escrow.submitReportHash(jobId, reportHash);

        vm.expectRevert(GravityLaunchPassEscrow.DeadlineNotReached.selector);
        escrow.autoRelease(jobId);

        (, , , , , , uint64 acceptDeadline, , , ) = escrow.jobs(jobId);
        vm.warp(acceptDeadline + 1);
        escrow.autoRelease(jobId);
    }

    function testWithdrawTransfersAndZeroes() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(client);
        escrow.cancelJob(jobId);

        uint256 beforeBalance = client.balance;

        vm.prank(client);
        vm.expectEmit(false, false, false, true);
        emit Withdrawal(client, JOB_AMOUNT);
        escrow.withdraw();

        assertEq(escrow.pendingWithdrawals(client), 0);
        assertEq(client.balance, beforeBalance + JOB_AMOUNT);
    }

    function testInvalidTransitionsRevert() public {
        bytes32 jobId = _createJob(address(0));

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.acceptAndRelease(jobId);

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.reclaimAfterNoSubmit(jobId);

        vm.prank(reviewer);
        escrow.acceptJob(jobId);

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.cancelJob(jobId);

        vm.prank(client);
        vm.expectRevert(GravityLaunchPassEscrow.InvalidStatus.selector);
        escrow.acceptAndRelease(jobId);
    }

    function testNoStuckFundsPaths() public {
        bytes32 jobIdCancel = _createJob(address(0));
        vm.prank(client);
        escrow.cancelJob(jobIdCancel);
        vm.prank(client);
        escrow.withdraw();

        bytes32 jobIdRelease = _createJob(address(0));
        vm.prank(reviewer);
        escrow.acceptJob(jobIdRelease);
        (, , , , , , , uint64 submitDeadlineRelease, , ) = escrow.jobs(jobIdRelease);
        vm.warp(uint256(submitDeadlineRelease) - 1);
        vm.prank(reviewer);
        escrow.submitReportHash(jobIdRelease, keccak256("report"));
        (, , , , , , uint64 acceptDeadline, , , ) = escrow.jobs(jobIdRelease);
        vm.warp(acceptDeadline + 1);
        escrow.autoRelease(jobIdRelease);
        vm.prank(reviewer);
        escrow.withdraw();

        bytes32 jobIdReclaim = _createJob(address(0));
        vm.prank(reviewer);
        escrow.acceptJob(jobIdReclaim);
        (, , , , , , , uint64 submitDeadlineReclaim, , ) = escrow.jobs(jobIdReclaim);
        vm.warp(submitDeadlineReclaim + 1);
        vm.prank(client);
        escrow.reclaimAfterNoSubmit(jobIdReclaim);
        vm.prank(client);
        escrow.withdraw();
    }

    function _createJob(address preferredReviewer) internal returns (bytes32 jobId) {
        vm.prank(client);
        jobId = escrow.createJob{value: JOB_AMOUNT}(preferredReviewer, 0, 0, 0);
    }
}
