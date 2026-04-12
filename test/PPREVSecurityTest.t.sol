// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../src/PPREVSingle.sol";

/// @title PPREVSecurityTest
/// @notice Reviewer-grade security and state-machine test suite for the PPREV protocol.
///         Covers: binding/replay safety, state-machine transitions, authorization,
///         temporal boundary conditions, and economic invariants.
///
///         Tests in CATEGORY 1 (binding) use a real ECDSANotaryVerifier to exercise
///         actual signature verification.  All other tests use the always-pass mock
///         verifiers for simplicity.
contract PPREVSecurityTest is Test {
    using MessageHashUtils for bytes32;

    // -- Mock verifiers --
    MockZKVerifier zkVerifier;
    MockThresholdSignatureVerifier sigVerifier;

    // -- Main protocol under test --
    PPREVSingle protocol;

    // -- Notary key (test-only, well-known) --
    uint256 constant NOTARY_PRIV_KEY = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
    address notaryAddr;

    // -- Actors --
    address lister = makeAddr("lister");
    address applicant = makeAddr("applicant");
    address attacker = makeAddr("attacker");
    address anyone = makeAddr("anyone");

    // -- Config --
    uint256 constant FRESHNESS_WINDOW = 300;
    uint256 constant EXPIRY_TIMEOUT = 3600;
    uint256 constant MIN_COLLATERAL = 0.1 ether;
    uint256 constant REQ_ESCROW = 0.05 ether;

    // -- Fixtures --
    bytes32 constant AD_HASH = keccak256("test-ad-hash");
    bytes32 constant POLICY_ID = keccak256("test-policy");
    bytes32 constant TRANSCRIPT_COMMIT = keccak256("transcript-commitment");
    bytes constant DUMMY_PROOF = hex"1234";
    bytes constant DUMMY_SIG = hex"5678";

    // ============================================================
    //  Setup & Helpers
    // ============================================================

    function setUp() public {
        notaryAddr = vm.addr(NOTARY_PRIV_KEY);

        zkVerifier = new MockZKVerifier();
        sigVerifier = new MockThresholdSignatureVerifier();

        protocol = new PPREVSingle(
            address(zkVerifier), address(sigVerifier), FRESHNESS_WINDOW, EXPIRY_TIMEOUT, MIN_COLLATERAL
        );
        protocol.whitelistPolicy(POLICY_ID, true);

        vm.deal(lister, 10 ether);
        vm.deal(applicant, 10 ether);
        vm.deal(attacker, 10 ether);
        vm.deal(anyone, 1 ether);
    }

    function _emptyInputs() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _notarySign(bytes32 message) internal view returns (bytes memory) {
        bytes32 ethHash = message.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(NOTARY_PRIV_KEY, ethHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Listing/application sig message matching the contract:
    ///      keccak256(caller | contract | chainId | adHash | policyId | transcript | ts | nonce)
    function _listingMsg(
        address caller,
        address contractAddr,
        bytes32 adHash,
        bytes32 policyId,
        bytes32 transcript,
        uint256 ts,
        bytes32 nonce
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(caller, contractAddr, block.chainid, adHash, policyId, transcript, ts, nonce));
    }

    /// @dev Settlement sig message matching the contract:
    ///      keccak256(caller | contract | chainId | appId | transcript | ts | nonce)
    function _settleMsg(
        address caller,
        address contractAddr,
        bytes32 appId,
        bytes32 transcript,
        uint256 ts,
        bytes32 nonce
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(caller, contractAddr, block.chainid, appId, transcript, ts, nonce));
    }

    /// @dev Register a listing as lister using mock verifiers.
    function _registerListing(bytes32 adHash, bytes32 nonce) internal {
        uint256 ts = block.timestamp;
        vm.prank(lister);
        protocol.registerListing{value: MIN_COLLATERAL}(
            adHash, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, ts, nonce, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    /// @dev Apply as applicant using mock verifiers; returns on-chain appId.
    function _applyToListing(bytes32 adHash, bytes32 nonce) internal returns (bytes32 appId) {
        uint256 ts = block.timestamp;
        vm.prank(applicant);
        protocol.applyToListing{value: REQ_ESCROW}(
            adHash, POLICY_ID, TRANSCRIPT_COMMIT, ts, nonce, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
        appId = keccak256(abi.encodePacked(adHash, applicant, nonce));
    }

    // ============================================================
    //  CATEGORY 1 - Binding / Replay Safety
    //  (use real ECDSANotaryVerifier so sig recovery is exercised)
    // ============================================================

    /// @notice Cross-contract replay is blocked: sig bound to protocol1 is rejected on protocol2.
    ///         address(this) and block.chainid are now included in the signed message hash.
    function test_Binding_CrossContractReplay_IsBlocked() public {
        ECDSANotaryVerifier ecdsaVerifier = new ECDSANotaryVerifier(notaryAddr);
        MockZKVerifier zk2 = new MockZKVerifier();

        PPREVSingle protocol1 =
            new PPREVSingle(address(zk2), address(ecdsaVerifier), FRESHNESS_WINDOW, EXPIRY_TIMEOUT, MIN_COLLATERAL);
        protocol1.whitelistPolicy(POLICY_ID, true);

        PPREVSingle protocol2 =
            new PPREVSingle(address(zk2), address(ecdsaVerifier), FRESHNESS_WINDOW, EXPIRY_TIMEOUT, MIN_COLLATERAL);
        protocol2.whitelistPolicy(POLICY_ID, true);

        vm.deal(lister, 20 ether);

        uint256 ts = block.timestamp;
        bytes32 nonce = keccak256("nonce-xreplay");

        // Sig is bound to protocol1's address
        bytes memory sig =
            _notarySign(_listingMsg(lister, address(protocol1), AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, ts, nonce));

        // Works on protocol1
        vm.prank(lister);
        protocol1.registerListing{value: MIN_COLLATERAL}(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, ts, nonce, DUMMY_PROOF, _emptyInputs(), sig
        );
        assertEq(uint256(protocol1.getListing(AD_HASH).status), uint256(PPREVSingle.ListingStatus.ACTIVE));

        // Replay on protocol2 must revert — sig hash contains protocol1's address
        bytes32 nonce2 = keccak256("nonce-xreplay-2");
        bytes memory sig2 =
            _notarySign(_listingMsg(lister, address(protocol1), AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, ts, nonce2));
        vm.expectRevert(PPREVSingle.InvalidThresholdSignature.selector);
        vm.prank(lister);
        protocol2.registerListing{value: MIN_COLLATERAL}(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, ts, nonce2, DUMMY_PROOF, _emptyInputs(), sig2
        );
    }

    /// @notice Caller-bound registerListing: attacker cannot submit lister's sig.
    function test_Binding_CallerBound_RegisterListing_AttackerReverts() public {
        ECDSANotaryVerifier ecdsaVerifier = new ECDSANotaryVerifier(notaryAddr);
        MockZKVerifier zk2 = new MockZKVerifier();
        PPREVSingle proto =
            new PPREVSingle(address(zk2), address(ecdsaVerifier), FRESHNESS_WINDOW, EXPIRY_TIMEOUT, MIN_COLLATERAL);
        proto.whitelistPolicy(POLICY_ID, true);
        vm.deal(attacker, 5 ether);

        bytes32 nonce = keccak256("nonce-caller-reg");
        uint256 ts = block.timestamp;
        bytes memory sig =
            _notarySign(_listingMsg(lister, address(proto), AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, ts, nonce));

        vm.expectRevert(PPREVSingle.InvalidThresholdSignature.selector);
        vm.prank(attacker);
        proto.registerListing{value: MIN_COLLATERAL}(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, ts, nonce, DUMMY_PROOF, _emptyInputs(), sig
        );
    }

    /// @notice Caller-bound applyToListing: attacker cannot reuse applicant's eligibility sig.
    function test_Binding_CallerBound_ApplyToListing_AttackerReverts() public {
        ECDSANotaryVerifier ecdsaVerifier = new ECDSANotaryVerifier(notaryAddr);
        MockZKVerifier zk2 = new MockZKVerifier();
        PPREVSingle proto =
            new PPREVSingle(address(zk2), address(ecdsaVerifier), FRESHNESS_WINDOW, EXPIRY_TIMEOUT, MIN_COLLATERAL);
        proto.whitelistPolicy(POLICY_ID, true);
        vm.deal(lister, 5 ether);
        vm.deal(applicant, 5 ether);
        vm.deal(attacker, 5 ether);

        uint256 ts = block.timestamp;
        bytes32 regNonce = keccak256("reg-nonce-cbind");
        bytes memory regSig =
            _notarySign(_listingMsg(lister, address(proto), AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, ts, regNonce));
        vm.prank(lister);
        proto.registerListing{value: MIN_COLLATERAL}(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, ts, regNonce, DUMMY_PROOF, _emptyInputs(), regSig
        );

        bytes32 appNonce = keccak256("apply-nonce-bind");
        // Sig bound to applicant's address, not attacker
        bytes memory appSig =
            _notarySign(_listingMsg(applicant, address(proto), AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, ts, appNonce));

        vm.expectRevert(PPREVSingle.InvalidThresholdSignature.selector);
        vm.prank(attacker);
        proto.applyToListing{value: REQ_ESCROW}(
            AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, ts, appNonce, DUMMY_PROOF, _emptyInputs(), appSig
        );
    }

    /// @notice Wrong adHash produces a different appId - ApplicationNotFound on settle.
    function test_Binding_WrongAdHash_SettleFails() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        _applyToListing(AD_HASH, keccak256("app-n"));

        bytes32 fakeAd = keccak256("fake-ad");
        bytes32 fakeAppId = keccak256(abi.encodePacked(fakeAd, applicant, keccak256("app-n")));

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationNotFound.selector, fakeAppId));
        vm.prank(lister);
        protocol.settleListing(
            fakeAppId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    /// @notice A nonce consumed in Phase 1 cannot be reused in Phase 2.
    function test_Replay_NonceCrossPhase_Rejected() public {
        bytes32 nonce = keccak256("shared-nonce");
        _registerListing(AD_HASH, nonce);

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.NonceAlreadyUsed.selector, nonce));
        vm.prank(applicant);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, block.timestamp, nonce, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    // ============================================================
    //  CATEGORY 2 - State Machine Safety
    // ============================================================

    /// @notice Cannot apply to a LOCKED listing.
    function test_SM_RejectApply_WhenLocked() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        _applyToListing(AD_HASH, keccak256("app-n1")); // listing -> LOCKED

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ListingNotActive.selector, AD_HASH));
        vm.prank(anyone);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            keccak256("app-n2"),
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    /// @notice Cannot apply to a SETTLED listing.
    function test_SM_RejectApply_WhenSettled() public {
        _registerListing(AD_HASH, keccak256("r-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("a-n"));

        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ListingNotActive.selector, AD_HASH));
        vm.prank(applicant);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            keccak256("app-n2"),
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    /// @notice Cannot apply to a CANCELLED listing.
    function test_SM_RejectApply_WhenCancelled() public {
        _registerListing(AD_HASH, keccak256("reg-nc"));
        vm.prank(lister);
        protocol.cancelListing(AD_HASH);

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ListingNotActive.selector, AD_HASH));
        vm.prank(applicant);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            keccak256("app-nc"),
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    /// @notice Cannot settle an application whose status is EXPIRED.
    function test_SM_RejectSettle_AfterExpired() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        protocol.expireApplication(appId);
        // Status is now EXPIRED

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationNotPending.selector, appId));
        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    /// @notice Double settlement on the same appId is rejected.
    function test_SM_RejectDoubleSettlement() public {
        _registerListing(AD_HASH, keccak256("r-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("a-n"));

        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n1"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationNotPending.selector, appId));
        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n2"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    /// @notice A second applicant cannot apply while listing is LOCKED.
    function test_SM_RejectSecondApply_WhileLocked() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        _applyToListing(AD_HASH, keccak256("app-n1"));

        address applicant2 = makeAddr("applicant2");
        vm.deal(applicant2, 5 ether);

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ListingNotActive.selector, AD_HASH));
        vm.prank(applicant2);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            keccak256("app-n2"),
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    /// @notice After expiration, listing reverts to ACTIVE and a fresh application succeeds.
    function test_SM_AfterExpire_FreshApplySucceeds() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId1 = _applyToListing(AD_HASH, keccak256("app-n1"));

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        protocol.expireApplication(appId1);

        assertEq(uint256(protocol.getListing(AD_HASH).status), uint256(PPREVSingle.ListingStatus.ACTIVE));

        bytes32 nonce2 = keccak256("app-n2");
        vm.prank(applicant);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, block.timestamp, nonce2, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        bytes32 appId2 = keccak256(abi.encodePacked(AD_HASH, applicant, nonce2));
        assertEq(
            uint256(protocol.getApplication(appId2).status), uint256(PPREVSingle.ApplicationStatus.PENDING_TRANSFER)
        );
    }

    // ============================================================
    //  CATEGORY 3 - Authorization Safety
    // ============================================================

    /// @notice Non-owner cannot cancel the listing.
    function test_Auth_RejectCancel_ByNonOwner() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.CallerNotListingOwner.selector, attacker, lister));
        vm.prank(attacker);
        protocol.cancelListing(AD_HASH);
    }

    /// @notice Self-application is rejected: landlord cannot apply to their own listing.
    function test_Auth_SelfApplication_IsRejected() public {
        _registerListing(AD_HASH, keccak256("reg-n"));

        vm.expectRevert(PPREVSingle.CannotApplyToOwnListing.selector);
        vm.prank(lister);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH,
            POLICY_ID,
            TRANSCRIPT_COMMIT,
            block.timestamp,
            keccak256("self-app-n"),
            DUMMY_PROOF,
            _emptyInputs(),
            DUMMY_SIG
        );
    }

    /// @notice All admin functions reject non-owner callers.
    function test_Auth_AllAdminFunctions_RejectNonOwner() public {
        vm.startPrank(attacker);

        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.setMinCollateral(1 ether);

        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.setFreshnessWindow(1);

        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.setExpiryTimeout(1);

        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.setZKVerifier(address(zkVerifier));

        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.setThresholdVerifier(address(sigVerifier));

        vm.expectRevert(PPREVSingle.NotOwner.selector);
        protocol.whitelistPolicy(POLICY_ID, false);

        vm.stopPrank();
    }

    /// @notice Non-listing-owner cannot call settleListing.
    function test_Auth_RejectSettle_ByNonListingOwner() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.CallerNotListingOwner.selector, attacker, lister));
        vm.prank(attacker);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    // ============================================================
    //  CATEGORY 4 - Temporal Safety
    // ============================================================

    /// @notice Settlement reverts with ApplicationExpiredCannotSettle when past expiry.
    function test_Temporal_RejectSettle_PastExpiry() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationExpiredCannotSettle.selector, appId));
        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    /// @notice Boundary: at exactly expires_at, settle still succeeds (strict > check).
    function test_Temporal_Boundary_AtExpiresAt_SettleSucceeds() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));
        uint256 expiresAt = protocol.getApplication(appId).createdAt + EXPIRY_TIMEOUT;

        vm.warp(expiresAt); // block.timestamp == expiresAt -> NOT > expiresAt -> allowed

        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        assertEq(uint256(protocol.getApplication(appId).status), uint256(PPREVSingle.ApplicationStatus.SETTLED));
    }

    /// @notice Boundary: at exactly expires_at, expire reverts (strict > check).
    function test_Temporal_Boundary_AtExpiresAt_ExpireReverts() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));
        uint256 expiresAt = protocol.getApplication(appId).createdAt + EXPIRY_TIMEOUT;

        vm.warp(expiresAt); // block.timestamp <= expiresAt -> not yet expirable

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationNotYetExpirable.selector, appId, expiresAt));
        protocol.expireApplication(appId);
    }

    /// @notice Boundary: at expires_at + 1, settle reverts and expire succeeds.
    ///         Confirms the two operations are mutually exclusive at every second.
    function test_Temporal_Boundary_AtExpiresAtPlusOne_CleanHandoff() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));
        uint256 expiresAt = protocol.getApplication(appId).createdAt + EXPIRY_TIMEOUT;

        vm.warp(expiresAt + 1);

        // Settle must revert with ApplicationExpiredCannotSettle
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationExpiredCannotSettle.selector, appId));
        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        // Expire must succeed
        protocol.expireApplication(appId);
        assertEq(uint256(protocol.getApplication(appId).status), uint256(PPREVSingle.ApplicationStatus.EXPIRED));
    }

    /// @notice Freshness boundary: sig exactly freshnessWindow seconds old is accepted.
    ///         Check: block.timestamp > sigTs + window -> 10000 > 10000 -> false -> pass.
    function test_Temporal_Boundary_Freshness_ExactEdge_Accepted() public {
        vm.warp(10_000);
        uint256 sigTs = block.timestamp - FRESHNESS_WINDOW; // 9700
        bytes32 nonce = keccak256("fresh-exact");

        vm.prank(lister);
        protocol.registerListing{value: MIN_COLLATERAL}(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, sigTs, nonce, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
        assertEq(uint256(protocol.getListing(AD_HASH).status), uint256(PPREVSingle.ListingStatus.ACTIVE));
    }

    /// @notice Freshness boundary: one second beyond window is rejected.
    ///         Check: block.timestamp > sigTs + window -> 10000 > 9999 -> true -> revert.
    function test_Temporal_Boundary_Freshness_OneBeyond_Rejected() public {
        vm.warp(10_000);
        uint256 sigTs = block.timestamp - FRESHNESS_WINDOW - 1; // 9699
        bytes32 nonce = keccak256("fresh-over");

        vm.expectRevert();
        vm.prank(lister);
        protocol.registerListing{value: MIN_COLLATERAL}(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_COMMIT, sigTs, nonce, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
    }

    // ============================================================
    //  CATEGORY 5 - Economic Correctness
    // ============================================================

    /// @notice Exact balance accounting after successful settlement.
    ///         Lister receives escrow + collateral; contract is fully drained.
    function test_Econ_Settlement_ExactBalances() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        uint256 listerBefore = lister.balance;
        uint256 applicantBefore = applicant.balance;

        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        assertEq(lister.balance - listerBefore, REQ_ESCROW + MIN_COLLATERAL, "lister balance wrong");
        assertEq(applicant.balance, applicantBefore, "applicant should be unchanged");
        assertEq(address(protocol).balance, 0, "contract not fully drained");
    }

    /// @notice Exact balance accounting after expiration with slashing.
    ///         Applicant receives escrow + 10% slash; remaining collateral stays in contract.
    function test_Econ_Expiration_ExactBalances() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        uint256 listerBefore = lister.balance;
        uint256 applicantBefore = applicant.balance;

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        protocol.expireApplication(appId);

        uint256 slashAmount = (MIN_COLLATERAL * 1000) / 10_000; // 0.01 ETH

        assertEq(applicant.balance - applicantBefore, REQ_ESCROW + slashAmount, "applicant balance wrong");
        assertEq(lister.balance, listerBefore, "lister should be unchanged");
        assertEq(address(protocol).balance, MIN_COLLATERAL - slashAmount, "contract balance wrong");
        assertEq(protocol.getListing(AD_HASH).collateral, MIN_COLLATERAL - slashAmount, "listing collateral wrong");
    }

    /// @notice Exact balance accounting after cancellation - full collateral returned.
    function test_Econ_Cancel_ExactBalances_NoStuckFunds() public {
        _registerListing(AD_HASH, keccak256("reg-n"));

        uint256 listerBefore = lister.balance;
        vm.prank(lister);
        protocol.cancelListing(AD_HASH);

        assertEq(lister.balance - listerBefore, MIN_COLLATERAL, "lister balance wrong");
        assertEq(address(protocol).balance, 0, "stuck funds after cancel");
        assertEq(protocol.getListing(AD_HASH).collateral, 0, "collateral field not zeroed");
    }

    /// @notice After expiration, remaining collateral is recoverable via cancelListing.
    function test_Econ_NoStuckFunds_AfterExpireThenCancel() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        protocol.expireApplication(appId);

        uint256 remaining = protocol.getListing(AD_HASH).collateral;
        assertGt(remaining, 0);

        uint256 listerBefore = lister.balance;
        vm.prank(lister);
        protocol.cancelListing(AD_HASH);

        assertEq(lister.balance - listerBefore, remaining, "lister did not recover remaining collateral");
        assertEq(address(protocol).balance, 0, "stuck funds after expire+cancel");
    }

    /// @notice Slash compounds on remaining collateral across two expiration cycles.
    ///         Cycle 1: 10% of 0.1 ETH = 0.01 ETH slashed -> 0.09 ETH remains.
    ///         Cycle 2: 10% of 0.09 ETH = 0.009 ETH slashed -> 0.081 ETH remains.
    function test_Econ_SlashAccumulation_TwoExpirations() public {
        _registerListing(AD_HASH, keccak256("reg-n"));

        // First expiration
        bytes32 appId1 = _applyToListing(AD_HASH, keccak256("app-n1"));
        vm.warp(block.timestamp + EXPIRY_TIMEOUT + 1);
        protocol.expireApplication(appId1);
        assertEq(protocol.getListing(AD_HASH).collateral, 0.09 ether, "wrong collateral after 1st expire");

        // Second expiration
        bytes32 nonce2 = keccak256("app-n2");
        vm.prank(applicant);
        protocol.applyToListing{value: REQ_ESCROW}(
            AD_HASH, POLICY_ID, TRANSCRIPT_COMMIT, block.timestamp, nonce2, DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );
        bytes32 appId2 = keccak256(abi.encodePacked(AD_HASH, applicant, nonce2));

        // Read createdAt from storage to avoid Solidity optimizer caching block.timestamp
        // (the optimizer may reuse the pre-warp value if block.timestamp appears multiple times
        //  in the same function, causing vm.warp to use a stale base).
        uint256 createdAt2 = protocol.getApplication(appId2).createdAt;
        vm.warp(createdAt2 + EXPIRY_TIMEOUT + 1);
        protocol.expireApplication(appId2);
        assertEq(protocol.getListing(AD_HASH).collateral, 0.081 ether, "wrong collateral after 2nd expire");
    }

    /// @notice settleListing zeroes app.escrowAmount and listing.collateral after transfer.
    ///         Prevents stale storage from misleading frontend and off-chain monitoring.
    function test_Econ_SettleListing_StorageZeroedAfterSettle() public {
        _registerListing(AD_HASH, keccak256("reg-n"));
        bytes32 appId = _applyToListing(AD_HASH, keccak256("app-n"));

        vm.prank(lister);
        protocol.settleListing(
            appId, TRANSCRIPT_COMMIT, block.timestamp, keccak256("settle-n"), DUMMY_PROOF, _emptyInputs(), DUMMY_SIG
        );

        assertEq(address(protocol).balance, 0, "stuck ETH after settleListing");
        assertEq(protocol.getApplication(appId).escrowAmount, 0, "app.escrowAmount not zeroed");
        assertEq(protocol.getListing(AD_HASH).collateral, 0, "listing.collateral not zeroed");
    }
}
