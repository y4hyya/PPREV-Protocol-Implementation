// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PPREVSingle.sol";

/// @title PPREVSingleTest
/// @notice End-to-end tests for the PPREV single-file MVP.
contract PPREVSingleTest is Test {
    // ── Contracts ──
    MockZKVerifier zkVerifier;
    MockThresholdSignatureVerifier sigVerifier;
    PPREVSingle protocol;

    // ── Actors ──
    address admin = address(this);
    address lister = makeAddr("lister");
    address applicant = makeAddr("applicant");
    address anyone = makeAddr("anyone");

    // ── Config ──
    uint256 constant FRESHNESS_WINDOW = 300; // 5 minutes
    uint256 constant EXPIRY_TIMEOUT = 3600; // 1 hour
    uint256 constant MIN_COLLATERAL = 0.1 ether;
    uint256 constant REQ_ESCROW = 0.05 ether;

    // ── Fixtures ──
    bytes32 constant AD_HASH = keccak256("test-ad-hash");
    bytes32 constant POLICY_ID = keccak256("test-policy");
    bytes32 constant TRANSCRIPT_COMMIT = keccak256("transcript-commitment");
    bytes constant DUMMY_PROOF = hex"1234";
    bytes constant DUMMY_SIG = hex"5678";

    function setUp() public {
        // Deploy mock verifiers
        zkVerifier = new MockZKVerifier();
        sigVerifier = new MockThresholdSignatureVerifier();

        // Deploy protocol
        protocol = new PPREVSingle(
            address(zkVerifier),
            address(sigVerifier),
            FRESHNESS_WINDOW,
            EXPIRY_TIMEOUT,
            MIN_COLLATERAL
        );

        // Whitelist the test policy
        protocol.whitelistPolicy(POLICY_ID, true);

        // Fund actors
        vm.deal(lister, 10 ether);
        vm.deal(applicant, 10 ether);
        vm.deal(anyone, 1 ether);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Helper: build empty zkInputs array
    // ════════════════════════════════════════════════════════════════════════

    function _emptyInputs() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Full Happy Path (Register → Apply → Settle)
    // ════════════════════════════════════════════════════════════════════════

    function test_FullHappyPath() public {
        bytes32 nonce1 = keccak256("nonce-register");
        bytes32 nonce2 = keccak256("nonce-apply");
        bytes32 nonce3 = keccak256("nonce-settle");

        // ── Phase 1: Register listing ──
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce1,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        PPREVSingle.Listing memory listing = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing.status),
            uint256(PPREVSingle.ListingStatus.ACTIVE)
        );
        assertEq(listing.owner, lister);
        assertEq(listing.collateral, 0.1 ether);

        // ── Phase 2: Application ──
        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce2,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // Derive expected appId
        bytes32 expectedAppId = keccak256(
            abi.encodePacked(AD_HASH, applicant, nonce2)
        );

        PPREVSingle.Application memory app = protocol.getApplication(
            expectedAppId
        );
        assertEq(
            uint256(app.status),
            uint256(PPREVSingle.ApplicationStatus.PENDING_TRANSFER)
        );
        assertEq(app.applicant, applicant);
        assertEq(app.escrowAmount, 0.05 ether);

        // Listing should be LOCKED
        listing = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing.status),
            uint256(PPREVSingle.ListingStatus.LOCKED)
        );

        // ── Phase 3: Settlement ──
        uint256 listerBalBefore = lister.balance;

        vm.prank(lister);
        protocol.settleListing(
            expectedAppId,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce3,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        app = protocol.getApplication(expectedAppId);
        assertEq(
            uint256(app.status),
            uint256(PPREVSingle.ApplicationStatus.SETTLED)
        );

        listing = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing.status),
            uint256(PPREVSingle.ListingStatus.SETTLED)
        );

        // Lister should have received escrow (0.05) + collateral (0.1) = 0.15 ether
        uint256 listerBalAfter = lister.balance;
        assertEq(listerBalAfter - listerBalBefore, 0.15 ether);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Expiration Path
    // ════════════════════════════════════════════════════════════════════════

    function test_ExpirationPath() public {
        bytes32 nonce1 = keccak256("nonce-register-exp");
        bytes32 nonce2 = keccak256("nonce-apply-exp");

        // Register
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce1,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // Apply
        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce2,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        bytes32 appId = keccak256(abi.encodePacked(AD_HASH, applicant, nonce2));

        // Cannot expire before timeout
        vm.expectRevert();
        vm.prank(anyone);
        protocol.expireApplication(appId);

        // Warp past expiry
        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);

        uint256 applicantBalBefore = applicant.balance;

        // Anyone can expire
        vm.prank(anyone);
        protocol.expireApplication(appId);

        PPREVSingle.Application memory app = protocol.getApplication(appId);
        assertEq(
            uint256(app.status),
            uint256(PPREVSingle.ApplicationStatus.EXPIRED)
        );

        // Listing should be ACTIVE again
        PPREVSingle.Listing memory listing = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing.status),
            uint256(PPREVSingle.ListingStatus.ACTIVE)
        );

        // Applicant should have received escrow + 10% slash of collateral
        uint256 slashAmount = 0.01 ether; // 10% of 0.1 ether
        uint256 applicantBalAfter = applicant.balance;
        assertEq(applicantBalAfter - applicantBalBefore, 0.05 ether + slashAmount);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Revert — Duplicate nonce
    // ════════════════════════════════════════════════════════════════════════

    function test_RevertDuplicateNonce() public {
        bytes32 nonce = keccak256("nonce-dup");

        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // Second listing with same nonce should revert
        bytes32 adHash2 = keccak256("ad-hash-2");
        vm.expectRevert(
            abi.encodeWithSelector(PPREVSingle.NonceAlreadyUsed.selector, nonce)
        );
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            adHash2,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Revert — Insufficient collateral
    // ════════════════════════════════════════════════════════════════════════

    function test_RevertInsufficientCollateral() public {
        bytes32 nonce = keccak256("nonce-low-col");

        vm.expectRevert(
            abi.encodeWithSelector(
                PPREVSingle.InsufficientCollateral.selector,
                0.01 ether,
                MIN_COLLATERAL
            )
        );
        vm.prank(lister);
        protocol.registerListing{value: 0.01 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Revert — Freshness window exceeded
    // ════════════════════════════════════════════════════════════════════════

    function test_RevertFreshnessExceeded() public {
        // Warp to a realistic timestamp so subtraction doesn't underflow
        vm.warp(1_700_000_000);

        bytes32 nonce = keccak256("nonce-stale");
        uint256 staleTimestamp = block.timestamp - FRESHNESS_WINDOW - 1;

        vm.expectRevert();
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            staleTimestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Revert — Non-whitelisted policy
    // ════════════════════════════════════════════════════════════════════════

    function test_RevertNonWhitelistedPolicy() public {
        bytes32 nonce = keccak256("nonce-bad-policy");
        bytes32 badPolicy = keccak256("unknown-policy");

        vm.expectRevert(
            abi.encodeWithSelector(
                PPREVSingle.PolicyNotWhitelisted.selector,
                badPolicy
            )
        );
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            badPolicy,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Revert — Settlement by non-owner
    // ════════════════════════════════════════════════════════════════════════

    function test_RevertSettlementByNonOwner() public {
        bytes32 nonce1 = keccak256("nonce-reg-auth");
        bytes32 nonce2 = keccak256("nonce-app-auth");
        bytes32 nonce3 = keccak256("nonce-settle-auth");

        // Register
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce1,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // Apply
        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce2,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        bytes32 appId = keccak256(abi.encodePacked(AD_HASH, applicant, nonce2));

        // Non-owner tries to settle
        vm.expectRevert(
            abi.encodeWithSelector(
                PPREVSingle.CallerNotListingOwner.selector,
                anyone,
                lister
            )
        );
        vm.prank(anyone);
        protocol.settleListing(
            appId,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce3,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Admin functions
    // ════════════════════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Cancel Listing
    // ════════════════════════════════════════════════════════════════════════

    function test_CancelListing() public {
        bytes32 nonce = keccak256("nonce-cancel");

        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        uint256 listerBalBefore = lister.balance;

        vm.prank(lister);
        protocol.cancelListing(AD_HASH);

        PPREVSingle.Listing memory listing = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing.status),
            uint256(PPREVSingle.ListingStatus.CANCELLED)
        );

        // Collateral should be returned
        uint256 listerBalAfter = lister.balance;
        assertEq(listerBalAfter - listerBalBefore, 0.1 ether);
    }

    function test_RevertCancelNotOwner() public {
        bytes32 nonce = keccak256("nonce-cancel-notown");

        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PPREVSingle.CallerNotListingOwner.selector,
                anyone,
                lister
            )
        );
        vm.prank(anyone);
        protocol.cancelListing(AD_HASH);
    }

    function test_RevertCancelLockedListing() public {
        bytes32 nonce1 = keccak256("nonce-cancel-locked1");
        bytes32 nonce2 = keccak256("nonce-cancel-locked2");

        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce1,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce2,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                PPREVSingle.ListingNotActive.selector,
                AD_HASH
            )
        );
        vm.prank(lister);
        protocol.cancelListing(AD_HASH);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Slashing reduces collateral
    // ════════════════════════════════════════════════════════════════════════

    function test_SlashReducesCollateral() public {
        bytes32 nonce1 = keccak256("nonce-reg-slash");
        bytes32 nonce2 = keccak256("nonce-app-slash");

        // Register
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce1,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // Apply
        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce2,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // Warp past expiry
        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);

        bytes32 appId = keccak256(
            abi.encodePacked(AD_HASH, applicant, nonce2)
        );
        vm.prank(anyone);
        protocol.expireApplication(appId);

        // Collateral should be reduced by 10%
        PPREVSingle.Listing memory listing = protocol.getListing(AD_HASH);
        assertEq(listing.collateral, 0.09 ether); // 0.1 - 0.01
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Admin functions
    // ════════════════════════════════════════════════════════════════════════

    function test_AdminFunctions() public {
        // Only owner should be able to call admin functions
        vm.prank(anyone);
        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.setMinCollateral(0.5 ether);

        // Owner can update config
        protocol.setMinCollateral(0.5 ether);
        assertEq(protocol.minCollateral(), 0.5 ether);

        protocol.setFreshnessWindow(600);
        assertEq(protocol.freshnessWindow(), 600);

        protocol.setExpiryTimeout(7200);
        assertEq(protocol.expiryTimeout(), 7200);

        protocol.setMaxExpirations(10);
        assertEq(protocol.maxExpirations(), 10);

        // Whitelist / un-whitelist
        bytes32 newPolicy = keccak256("new-policy");
        protocol.whitelistPolicy(newPolicy, true);
        assertTrue(protocol.isPolicyWhitelisted(newPolicy));

        protocol.whitelistPolicy(newPolicy, false);
        assertFalse(protocol.isPolicyWhitelisted(newPolicy));

        // Zero-address verifiers should revert
        vm.expectRevert(PPREVSingle.InvalidVerifierAddress.selector);
        protocol.setZKVerifier(address(0));

        vm.expectRevert(PPREVSingle.InvalidVerifierAddress.selector);
        protocol.setThresholdVerifier(address(0));
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Max expirations auto-cancels listing
    // ════════════════════════════════════════════════════════════════════════

    function test_MaxExpirationsAutoCancels() public {
        // Set maxExpirations to 2 for faster test
        protocol.setMaxExpirations(2);

        bytes32 nonce1 = keccak256("nonce-maxexp-reg");

        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            REQ_ESCROW,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce1,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        // ── Cycle 1: apply → expire ──
        bytes32 nonce2 = keccak256("nonce-maxexp-app1");
        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce2,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        bytes32 appId1 = keccak256(
            abi.encodePacked(AD_HASH, applicant, nonce2)
        );
        vm.prank(anyone);
        protocol.expireApplication(appId1);

        // After 1st expiration: listing should still be ACTIVE
        PPREVSingle.Listing memory listing1 = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing1.status),
            uint256(PPREVSingle.ListingStatus.ACTIVE)
        );

        // ── Cycle 2: apply → expire (should auto-cancel) ──
        bytes32 nonce3 = keccak256("nonce-maxexp-app2");
        vm.prank(applicant);
        protocol.applyToListing{value: 0.05 ether}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce3,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        bytes32 appId2 = keccak256(
            abi.encodePacked(AD_HASH, applicant, nonce3)
        );

        uint256 listerBalBefore = lister.balance;
        vm.prank(anyone);
        protocol.expireApplication(appId2);

        // After 2nd expiration: listing should be CANCELLED
        PPREVSingle.Listing memory listing2 = protocol.getListing(AD_HASH);
        assertEq(
            uint256(listing2.status),
            uint256(PPREVSingle.ListingStatus.CANCELLED)
        );
        // Remaining collateral should be zero (returned to owner)
        assertEq(listing2.collateral, 0);

        // Lister should have received remaining collateral
        uint256 listerBalAfter = lister.balance;
        assertTrue(listerBalAfter > listerBalBefore);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Test: Revert on zero reqEscrow
    // ════════════════════════════════════════════════════════════════════════

    function test_RevertZeroReqEscrow() public {
        bytes32 nonce = keccak256("nonce-zero-escrow");

        vm.expectRevert(PPREVSingle.InvalidEscrowAmount.selector);
        vm.prank(lister);
        protocol.registerListing{value: 0.1 ether}(
            AD_HASH,
            POLICY_ID,
            0, // zero reqEscrow
            TRANSCRIPT_COMMIT,
            block.timestamp,
            nonce,
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }
}
