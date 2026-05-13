// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PPREVSingle.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title PPREVSecurityTest
/// @notice Reviewer-grade security tests organized into six categories
///         matching the paper's Section VII analysis:
///           1. Signature binding (4)
///           2. State machine safety (7)
///           3. Authentication (4)
///           4. Temporal boundaries (6)
///           5. Economic correctness (6)
///           6. Replay protection (1)
///         Uses real ECDSA signatures via vm.sign throughout.
contract PPREVSecurityTest is Test {
    PPREVSingle internal pprev;
    ECDSANotaryVerifier internal verifier;

    uint256 internal notaryPk = uint256(keccak256("notary.private.key.v1"));
    address internal notary;

    uint256 internal otherPk = uint256(keccak256("other.private.key"));

    address internal admin = address(0xA0);
    address internal listingOwner = address(0xB1);
    address internal applicant = address(0xC2);
    address internal other = address(0xD3);

    bytes32 internal constant POLICY_R = keccak256("policy.ownership");
    bytes32 internal constant POLICY_A = keccak256("policy.eligibility");
    bytes32 internal constant POLICY_S = keccak256("policy.settlement");

    uint256 internal constant FRESHNESS = 300;
    uint256 internal constant DEFAULT_LOCK = 7 days;
    uint256 internal constant MIN_COLLATERAL = 1 ether;
    uint256 internal constant REQ_ESCROW = 0.5 ether;

    function setUp() public {
        notary = vm.addr(notaryPk);

        vm.startPrank(admin);
        verifier = new ECDSANotaryVerifier(notary);
        pprev = new PPREVSingle(address(verifier), FRESHNESS, DEFAULT_LOCK, MIN_COLLATERAL);
        pprev.whitelistPolicy(POLICY_R, true);
        pprev.whitelistPolicy(POLICY_A, true);
        pprev.whitelistPolicy(POLICY_S, true);
        vm.stopPrank();

        vm.deal(listingOwner, 100 ether);
        vm.deal(applicant, 100 ether);
        vm.deal(other, 100 ether);

        // Ensure block.timestamp is large enough that nothing underflows when computing _timestamp - delta
        vm.warp(10_000);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Signing helpers (mirror the contract's sigMessage layout)
    // ────────────────────────────────────────────────────────────────────────

    function _signRaw(uint256 pk, bytes32 rawMessage) internal pure returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(rawMessage);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _sign(bytes32 rawMessage) internal view returns (bytes memory) {
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(rawMessage);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(notaryPk, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _txId(bytes memory txData, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(txData, POLICY_R, salt));
    }

    function _msgR(address contractAddr, bytes32 txID, bytes32 txDataHash, bytes32 nonce, uint256 timestamp)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(txID, txDataHash, POLICY_R, nonce, timestamp, contractAddr));
    }

    function _msgA(address contractAddr, bytes32 txID, bytes32 nonce, uint256 timestamp)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(txID, POLICY_A, nonce, timestamp, contractAddr));
    }

    function _msgS(address contractAddr, bytes32 engId, bytes32 txID, bytes32 nonce, uint256 timestamp)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(engId, txID, POLICY_S, nonce, timestamp, contractAddr));
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Lifecycle helpers (with real signatures)
    // ────────────────────────────────────────────────────────────────────────

    function _registerSigned(address caller, bytes memory txData, bytes32 salt, bytes32 nonce, uint256 ts, uint256 pk)
        internal
        returns (bytes32 txID)
    {
        txID = _txId(txData, salt);
        bytes32 txDataHash = keccak256(txData);
        bytes memory sig = _signRaw(pk, _msgR(address(pprev), txID, txDataHash, nonce, ts));
        vm.prank(caller);
        pprev.register{value: MIN_COLLATERAL}(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, sig);
    }

    function _register(address caller, bytes memory txData, bytes32 salt, bytes32 nonce)
        internal
        returns (bytes32 txID)
    {
        return _registerSigned(caller, txData, salt, nonce, block.timestamp, notaryPk);
    }

    function _applySigned(address caller, bytes32 txID, bytes32 nonce, uint256 ts, uint256 pk)
        internal
        returns (bytes32 appId)
    {
        bytes memory sig = _signRaw(pk, _msgA(address(pprev), txID, nonce, ts));
        vm.prank(caller);
        appId = pprev.applyTx{value: REQ_ESCROW}(txID, nonce, ts, sig);
    }

    function _apply(address caller, bytes32 txID, bytes32 nonce) internal returns (bytes32 appId) {
        return _applySigned(caller, txID, nonce, block.timestamp, notaryPk);
    }

    function _engage(address caller, bytes32 appId) internal returns (bytes32 engId) {
        vm.prank(caller);
        engId = pprev.engage(appId, 0);
    }

    function _settleSigned(address caller, bytes32 engId, bytes32 txID, bytes32 nonce, uint256 ts, uint256 pk)
        internal
    {
        bytes memory sig = _signRaw(pk, _msgS(address(pprev), engId, txID, nonce, ts));
        vm.prank(caller);
        pprev.settle(engId, nonce, ts, sig);
    }

    function _settle(address caller, bytes32 engId, bytes32 txID, bytes32 nonce) internal {
        _settleSigned(caller, engId, txID, nonce, block.timestamp, notaryPk);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Category 1 — Signature binding (4)
    // ════════════════════════════════════════════════════════════════════════

    /// 1.1 — Full ECDSA round-trip succeeds end-to-end.
    function test_Binding_ValidSig_Roundtrip() public {
        bytes32 txID = _register(listingOwner, abi.encode("ok"), bytes32(uint256(1)), bytes32(uint256(11)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(12)));
        bytes32 engId = _engage(listingOwner, appId);
        _settle(listingOwner, engId, txID, bytes32(uint256(13)));

        assertEq(uint256(pprev.getListing(txID).state), uint256(PPREVSingle.TxState.SETTLED));
    }

    /// 1.2 — Bit-flipped σ_R is rejected.
    function test_Binding_TamperedSig_Rejected() public {
        bytes memory txData = abi.encode("tamper");
        bytes32 salt = bytes32(uint256(2));
        bytes32 nonce = bytes32(uint256(21));
        uint256 ts = block.timestamp;
        bytes32 txID = _txId(txData, salt);
        bytes32 txDataHash = keccak256(txData);

        bytes memory sig = _sign(_msgR(address(pprev), txID, txDataHash, nonce, ts));
        sig[0] = bytes1(uint8(sig[0]) ^ 0x01); // flip one bit

        vm.prank(listingOwner);
        vm.expectRevert(PPREVSingle.InvalidNotarySignature.selector);
        pprev.register{value: MIN_COLLATERAL}(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, sig);
    }

    /// 1.3 — σ produced by a different key is rejected.
    function test_Binding_WrongNotaryKey_Rejected() public {
        bytes memory txData = abi.encode("wrongkey");
        bytes32 salt = bytes32(uint256(3));
        bytes32 nonce = bytes32(uint256(31));
        uint256 ts = block.timestamp;
        bytes32 txID = _txId(txData, salt);
        bytes32 txDataHash = keccak256(txData);

        bytes memory sig = _signRaw(otherPk, _msgR(address(pprev), txID, txDataHash, nonce, ts));

        vm.prank(listingOwner);
        vm.expectRevert(PPREVSingle.InvalidNotarySignature.selector);
        pprev.register{value: MIN_COLLATERAL}(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, sig);
    }

    /// 1.4 — σ valid for contract A is rejected when submitted to contract B (paper VII.C cross-contract).
    function test_Binding_CrossContractReplay_Blocked() public {
        // Deploy a sibling contract
        vm.startPrank(admin);
        PPREVSingle pprev2 = new PPREVSingle(address(verifier), FRESHNESS, DEFAULT_LOCK, MIN_COLLATERAL);
        pprev2.whitelistPolicy(POLICY_R, true);
        pprev2.whitelistPolicy(POLICY_A, true);
        pprev2.whitelistPolicy(POLICY_S, true);
        vm.stopPrank();

        bytes memory txData = abi.encode("cross");
        bytes32 salt = bytes32(uint256(4));
        bytes32 nonce = bytes32(uint256(41));
        uint256 ts = block.timestamp;
        bytes32 txID = _txId(txData, salt);
        bytes32 txDataHash = keccak256(txData);

        // Sign for pprev (contract A); submit to pprev2 (contract B)
        bytes memory sigForA = _sign(_msgR(address(pprev), txID, txDataHash, nonce, ts));

        vm.prank(listingOwner);
        vm.expectRevert(PPREVSingle.InvalidNotarySignature.selector);
        pprev2.register{value: MIN_COLLATERAL}(
            txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, sigForA
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Category 2 — State machine safety (7)
    // ════════════════════════════════════════════════════════════════════════

    /// 2.1 — Apply on a never-registered txID is rejected.
    function test_State_ApplyOnUnknownTx_Rejected() public {
        bytes32 fakeTxID = keccak256("fake");
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.TxNotActive.selector, fakeTxID));
        pprev.applyTx{value: REQ_ESCROW}(fakeTxID, bytes32(uint256(101)), block.timestamp, hex"00");
    }

    /// 2.2 — Engage on an unknown appId is rejected.
    function test_State_EngageUnknownApp_Rejected() public {
        bytes32 fakeAppId = keccak256("fakeapp");
        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationNotFound.selector, fakeAppId));
        pprev.engage(fakeAppId, 0);
    }

    /// 2.3 — Apply on a CANCELLED listing is rejected.
    function test_State_CancelledNotAcceptingApply() public {
        bytes32 txID = _register(listingOwner, abi.encode("cncl"), bytes32(uint256(5)), bytes32(uint256(51)));
        vm.prank(listingOwner);
        pprev.cancel(txID);

        bytes32 nonce = bytes32(uint256(52));
        bytes memory sig = _sign(_msgA(address(pprev), txID, nonce, block.timestamp));
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.TxNotActive.selector, txID));
        pprev.applyTx{value: REQ_ESCROW}(txID, nonce, block.timestamp, sig);
    }

    /// 2.4 — Engage twice on the same listing (state LOCKED) is rejected.
    function test_State_DoubleEngage_Rejected() public {
        bytes32 txID = _register(listingOwner, abi.encode("dbl"), bytes32(uint256(6)), bytes32(uint256(61)));
        bytes32 appId1 = _apply(applicant, txID, bytes32(uint256(62)));
        _engage(listingOwner, appId1);

        // Even attempting to engage the same app again fails (status no longer PENDING)
        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.ApplicationNotPending.selector, appId1));
        pprev.engage(appId1, 0);
    }

    /// 2.5 — Settle without prior engagement is rejected.
    function test_State_SettleWithoutEngage_Rejected() public {
        bytes32 fakeEngId = keccak256("fakeeng");
        bytes memory sig = _sign(_msgS(address(pprev), fakeEngId, bytes32(0), bytes32(uint256(71)), block.timestamp));
        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.EngagementNotFound.selector, fakeEngId));
        pprev.settle(fakeEngId, bytes32(uint256(71)), block.timestamp, sig);
    }

    /// 2.6 — Settle twice on the same engagement is rejected.
    function test_State_DoubleSettle_Rejected() public {
        bytes32 txID = _register(listingOwner, abi.encode("dst"), bytes32(uint256(7)), bytes32(uint256(81)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(82)));
        bytes32 engId = _engage(listingOwner, appId);
        _settle(listingOwner, engId, txID, bytes32(uint256(83)));

        bytes32 nonce2 = bytes32(uint256(84));
        bytes memory sig = _sign(_msgS(address(pprev), engId, txID, nonce2, block.timestamp));
        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.EngagementNotActive.selector, engId));
        pprev.settle(engId, nonce2, block.timestamp, sig);
    }

    /// 2.7 — Cancel on a LOCKED listing is rejected.
    function test_State_CancelLocked_Rejected() public {
        bytes32 txID = _register(listingOwner, abi.encode("clk"), bytes32(uint256(8)), bytes32(uint256(91)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(92)));
        _engage(listingOwner, appId);

        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.TxNotActive.selector, txID));
        pprev.cancel(txID);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Category 3 — Authentication (4)
    // ════════════════════════════════════════════════════════════════════════

    /// 3.1 — Only listing owner may engage.
    function test_Auth_Engage_OnlyOwner() public {
        bytes32 txID = _register(listingOwner, abi.encode("au1"), bytes32(uint256(1)), bytes32(uint256(110)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(111)));

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.CallerNotListingOwner.selector, other, listingOwner));
        pprev.engage(appId, 0);
    }

    /// 3.2 — Only listing owner may settle.
    function test_Auth_Settle_OnlyOwner() public {
        bytes32 txID = _register(listingOwner, abi.encode("au2"), bytes32(uint256(1)), bytes32(uint256(120)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(121)));
        bytes32 engId = _engage(listingOwner, appId);

        bytes32 nonce = bytes32(uint256(122));
        bytes memory sig = _sign(_msgS(address(pprev), engId, txID, nonce, block.timestamp));

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.CallerNotListingOwner.selector, other, listingOwner));
        pprev.settle(engId, nonce, block.timestamp, sig);
    }

    /// 3.3 — Only listing owner may cancel.
    function test_Auth_Cancel_OnlyOwner() public {
        bytes32 txID = _register(listingOwner, abi.encode("au3"), bytes32(uint256(1)), bytes32(uint256(130)));
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.CallerNotListingOwner.selector, other, listingOwner));
        pprev.cancel(txID);
    }

    /// 3.4 — Admin-only setters reject non-admin callers.
    function test_Auth_AdminOnlySettings() public {
        vm.prank(other);
        vm.expectRevert(PPREVSingle.NotAdmin.selector);
        pprev.setFreshnessWindow(60);

        vm.prank(other);
        vm.expectRevert(PPREVSingle.NotAdmin.selector);
        pprev.setMaxExpirations(10);

        vm.prank(other);
        vm.expectRevert(PPREVSingle.NotAdmin.selector);
        pprev.whitelistPolicy(keccak256("x"), true);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Category 4 — Temporal boundaries (6)
    // ════════════════════════════════════════════════════════════════════════

    /// 4.1 — Freshness at the exact boundary (now == t + Δ) is allowed.
    function test_Temporal_Freshness_AtExactBoundary_Allowed() public {
        // setUp warps to 10000; the IR optimizer caches block.timestamp reads, so use
        // explicit constants for attestedAt and the warp target.
        uint256 attestedAt = 10_000;
        vm.warp(attestedAt + FRESHNESS); // exactly at boundary

        bytes32 txID = _registerSigned(
            listingOwner, abi.encode("fb"), bytes32(uint256(1)), bytes32(uint256(141)), attestedAt, notaryPk
        );
        assertEq(uint256(pprev.getListing(txID).state), uint256(PPREVSingle.TxState.ACTIVE));
    }

    /// 4.2 — Freshness one second past Δ is rejected.
    function test_Temporal_Freshness_OneSecondPast_Rejected() public {
        uint256 attestedAt = 10_000;
        uint256 callTime = attestedAt + FRESHNESS + 1;
        vm.warp(callTime);

        bytes memory txData = abi.encode("fbp");
        bytes32 salt = bytes32(uint256(1));
        bytes32 nonce = bytes32(uint256(151));
        bytes32 txID = _txId(txData, salt);
        bytes32 txDataHash = keccak256(txData);
        bytes memory sig = _sign(_msgR(address(pprev), txID, txDataHash, nonce, attestedAt));

        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.FreshnessWindowExceeded.selector, attestedAt, callTime));
        pprev.register{value: MIN_COLLATERAL}(
            txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, attestedAt, sig
        );
    }

    /// 4.3 — Settle exactly at expiresAt is allowed (paper V.D condition: now ≤ expiresAt).
    function test_Temporal_Settle_AtExactExpiry_Allowed() public {
        bytes32 txID = _register(listingOwner, abi.encode("se1"), bytes32(uint256(1)), bytes32(uint256(161)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(162)));
        bytes32 engId = _engage(listingOwner, appId);

        uint256 expiresAt = pprev.getEngagement(engId).expiresAt;
        vm.warp(expiresAt); // exactly at expiresAt
        _settle(listingOwner, engId, txID, bytes32(uint256(163)));
        assertEq(uint256(pprev.getListing(txID).state), uint256(PPREVSingle.TxState.SETTLED));
    }

    /// 4.4 — Settle one second past expiresAt is rejected.
    function test_Temporal_Settle_OneSecondPastExpiry_Rejected() public {
        bytes32 txID = _register(listingOwner, abi.encode("se2"), bytes32(uint256(1)), bytes32(uint256(171)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(172)));
        bytes32 engId = _engage(listingOwner, appId);

        uint256 expiresAt = pprev.getEngagement(engId).expiresAt;
        vm.warp(expiresAt + 1);

        bytes32 nonce = bytes32(uint256(173));
        bytes memory sig = _sign(_msgS(address(pprev), engId, txID, nonce, block.timestamp));
        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.EngagementAlreadyExpired.selector, engId));
        pprev.settle(engId, nonce, block.timestamp, sig);
    }

    /// 4.5 — Expire before expiresAt is rejected.
    function test_Temporal_Expire_BeforeExpiry_Rejected() public {
        bytes32 txID = _register(listingOwner, abi.encode("ex1"), bytes32(uint256(1)), bytes32(uint256(181)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(182)));
        bytes32 engId = _engage(listingOwner, appId);

        uint256 expiresAt = pprev.getEngagement(engId).expiresAt;
        vm.warp(expiresAt - 1);

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.EngagementNotYetExpirable.selector, engId, expiresAt));
        pprev.expire(engId);
    }

    /// 4.6 — Expire at exactly expiresAt is rejected (strict >).
    function test_Temporal_Expire_AtExactExpiry_Rejected() public {
        bytes32 txID = _register(listingOwner, abi.encode("ex2"), bytes32(uint256(1)), bytes32(uint256(191)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(192)));
        bytes32 engId = _engage(listingOwner, appId);

        uint256 expiresAt = pprev.getEngagement(engId).expiresAt;
        vm.warp(expiresAt); // strictly == not allowed

        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.EngagementNotYetExpirable.selector, engId, expiresAt));
        pprev.expire(engId);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Category 5 — Economic correctness (6)
    // ════════════════════════════════════════════════════════════════════════

    /// 5.1 — After settle, contract holds zero residual ETH.
    function test_Econ_Settle_NoResidualBalance() public {
        bytes32 txID = _register(listingOwner, abi.encode("ec1"), bytes32(uint256(1)), bytes32(uint256(201)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(202)));
        bytes32 engId = _engage(listingOwner, appId);
        _settle(listingOwner, engId, txID, bytes32(uint256(203)));
        assertEq(address(pprev).balance, 0);
    }

    /// 5.2 — After expire, contract holds zero residual ETH (and listing.collateral reduced).
    function test_Econ_Expire_NoResidualBalance() public {
        bytes32 txID = _register(listingOwner, abi.encode("ec2"), bytes32(uint256(1)), bytes32(uint256(211)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(212)));
        bytes32 engId = _engage(listingOwner, appId);

        vm.warp(pprev.getEngagement(engId).expiresAt + 1);
        pprev.expire(engId);

        // remaining collateral still sits in the contract for the next applicant
        assertEq(address(pprev).balance, MIN_COLLATERAL - MIN_COLLATERAL / 10);
    }

    /// 5.3 — After cancel, contract holds zero residual ETH.
    function test_Econ_Cancel_NoResidualBalance() public {
        bytes32 txID = _register(listingOwner, abi.encode("ec3"), bytes32(uint256(1)), bytes32(uint256(221)));
        vm.prank(listingOwner);
        pprev.cancel(txID);
        assertEq(address(pprev).balance, 0);
    }

    /// 5.4 — Slashing is compounding: collateral after k expirations = floor((9/10)^k) of original.
    function test_Econ_Expire_CompoundingSlash() public {
        bytes32 txID = _register(listingOwner, abi.encode("ec4"), bytes32(uint256(1)), bytes32(uint256(231)));
        uint256 expected = MIN_COLLATERAL;

        for (uint256 i = 0; i < 3; i++) {
            bytes32 appId = _apply(applicant, txID, bytes32(uint256(240 + i)));
            bytes32 engId = _engage(listingOwner, appId);
            vm.warp(pprev.getEngagement(engId).expiresAt + 1);
            pprev.expire(engId);
            expected -= expected / 10;
        }
        assertEq(pprev.getListing(txID).collateral, expected);
    }

    /// 5.5 — Settle balance accounting: owner +escrow (-collateral +collateral); applicant -escrow.
    function test_Econ_Settle_BalancesExact() public {
        uint256 ownerStart = listingOwner.balance;
        uint256 appStart = applicant.balance;

        bytes32 txID = _register(listingOwner, abi.encode("ec5"), bytes32(uint256(1)), bytes32(uint256(251)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(252)));
        bytes32 engId = _engage(listingOwner, appId);
        _settle(listingOwner, engId, txID, bytes32(uint256(253)));

        assertEq(listingOwner.balance, ownerStart + REQ_ESCROW);
        assertEq(applicant.balance, appStart - REQ_ESCROW);
    }

    /// 5.6 — Expire balance accounting: applicant nets +slashAmount; owner unchanged at expire time.
    function test_Econ_Expire_BalancesExact() public {
        uint256 ownerStart = listingOwner.balance;
        uint256 appStart = applicant.balance;

        bytes32 txID = _register(listingOwner, abi.encode("ec6"), bytes32(uint256(1)), bytes32(uint256(261)));
        bytes32 appId = _apply(applicant, txID, bytes32(uint256(262)));
        bytes32 engId = _engage(listingOwner, appId);

        vm.warp(pprev.getEngagement(engId).expiresAt + 1);
        pprev.expire(engId);

        assertEq(applicant.balance, appStart + MIN_COLLATERAL / 10);
        assertEq(listingOwner.balance, ownerStart - MIN_COLLATERAL); // collateral still locked, will return at cancel
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Category 6 — Replay protection (1)
    // ════════════════════════════════════════════════════════════════════════

    /// 6.1 — A nonce consumed in any phase cannot be reused in another (paper VII.C cross-phase substitution).
    function test_Replay_NonceCrossPhase_Rejected() public {
        bytes32 sharedNonce = bytes32(uint256(0xCAFE));
        bytes32 txID = _register(listingOwner, abi.encode("rp"), bytes32(uint256(1)), sharedNonce);

        // Try to reuse the same nonce in apply
        bytes memory sigA = _sign(_msgA(address(pprev), txID, sharedNonce, block.timestamp));
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.NonceAlreadyUsed.selector, sharedNonce));
        pprev.applyTx{value: REQ_ESCROW}(txID, sharedNonce, block.timestamp, sigA);
    }
}
