// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PPREVSingle.sol";

/// @title PPREVSingle — Functional Tests
/// @notice Happy-path lifecycle and basic revert coverage using MockNotaryVerifier.
contract PPREVSingleTest is Test {
    PPREVSingle internal pprev;
    MockNotaryVerifier internal notary;

    address internal admin = address(0xA0);
    address internal listingOwner = address(0xB1);
    address internal applicant = address(0xC2);
    address internal otherApplicant = address(0xC3);

    bytes32 internal constant POLICY_R = keccak256("policy.ownership");
    bytes32 internal constant POLICY_A = keccak256("policy.eligibility");
    bytes32 internal constant POLICY_S = keccak256("policy.settlement");

    uint256 internal constant FRESHNESS = 300;
    uint256 internal constant DEFAULT_LOCK = 7 days;
    uint256 internal constant MIN_COLLATERAL = 1 ether;
    uint256 internal constant REQ_ESCROW = 0.5 ether;

    bytes internal constant DUMMY_SIG = hex"00";

    function setUp() public {
        vm.startPrank(admin);
        notary = new MockNotaryVerifier();
        pprev = new PPREVSingle(address(notary), FRESHNESS, DEFAULT_LOCK, MIN_COLLATERAL);
        pprev.whitelistPolicy(POLICY_R, true);
        pprev.whitelistPolicy(POLICY_A, true);
        pprev.whitelistPolicy(POLICY_S, true);
        vm.stopPrank();

        vm.deal(listingOwner, 100 ether);
        vm.deal(applicant, 100 ether);
        vm.deal(otherApplicant, 100 ether);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ────────────────────────────────────────────────────────────────────────

    function _computeTxId(bytes memory txData, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(txData, POLICY_R, salt));
    }

    function _register(address owner_, bytes memory txData, bytes32 salt, bytes32 nonce)
        internal
        returns (bytes32 txID)
    {
        vm.prank(owner_);
        txID = pprev.register{value: MIN_COLLATERAL}(
            txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, block.timestamp, DUMMY_SIG
        );
    }

    function _applyTx(address who, bytes32 txID, bytes32 nonce) internal returns (bytes32 appId) {
        vm.prank(who);
        appId = pprev.applyTx{value: REQ_ESCROW}(txID, nonce, block.timestamp, DUMMY_SIG);
    }

    function _engage(address owner_, bytes32 appId, uint256 lockWindow) internal returns (bytes32 engId) {
        vm.prank(owner_);
        engId = pprev.engage(appId, lockWindow);
    }

    function _settle(address owner_, bytes32 engId, bytes32 nonce) internal {
        vm.prank(owner_);
        pprev.settle(engId, nonce, block.timestamp, DUMMY_SIG);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Functional Tests
    // ────────────────────────────────────────────────────────────────────────

    /// 1) Register happy path
    function test_Register_Succeeds() public {
        bytes memory txData = abi.encode("listing#1", uint256(1500));
        bytes32 salt = bytes32(uint256(1));
        bytes32 txID = _register(listingOwner, txData, salt, bytes32(uint256(101)));

        PPREVSingle.Listing memory l = pprev.getListing(txID);
        assertEq(l.owner, listingOwner);
        assertEq(l.policyId_R, POLICY_R);
        assertEq(l.policyId_A, POLICY_A);
        assertEq(l.policyId_S, POLICY_S);
        assertEq(l.reqEscrow, REQ_ESCROW);
        assertEq(l.collateral, MIN_COLLATERAL);
        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.ACTIVE));
        assertEq(l.txID, _computeTxId(txData, salt));
        assertTrue(pprev.isNonceUsed(bytes32(uint256(101))));
    }

    /// 2) Register reverts on duplicate C_tx
    function test_Register_Reverts_OnDuplicate() public {
        bytes memory txData = abi.encode("listing#1");
        bytes32 salt = bytes32(uint256(7));
        bytes32 txID = _register(listingOwner, txData, salt, bytes32(uint256(1)));

        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.TxAlreadyExists.selector, txID));
        pprev.register{value: MIN_COLLATERAL}(
            txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, bytes32(uint256(2)), block.timestamp, DUMMY_SIG
        );
    }

    /// 3) Register reverts on non-whitelisted policy
    function test_Register_Reverts_OnUnwhitelistedPolicy() public {
        bytes32 badPolicy = keccak256("policy.unknown");
        vm.prank(listingOwner);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.PolicyNotWhitelisted.selector, badPolicy));
        pprev.register{value: MIN_COLLATERAL}(
            abi.encode("x"),
            badPolicy,
            POLICY_A,
            POLICY_S,
            bytes32(uint256(1)),
            REQ_ESCROW,
            bytes32(uint256(11)),
            block.timestamp,
            DUMMY_SIG
        );
    }

    /// 4) Register reverts on insufficient collateral
    function test_Register_Reverts_OnInsufficientCollateral() public {
        vm.prank(listingOwner);
        vm.expectRevert(
            abi.encodeWithSelector(PPREVSingle.InsufficientCollateral.selector, MIN_COLLATERAL - 1, MIN_COLLATERAL)
        );
        pprev.register{value: MIN_COLLATERAL - 1}(
            abi.encode("x"),
            POLICY_R,
            POLICY_A,
            POLICY_S,
            bytes32(uint256(1)),
            REQ_ESCROW,
            bytes32(uint256(12)),
            block.timestamp,
            DUMMY_SIG
        );
    }

    /// 5) Apply happy path
    function test_Apply_Succeeds() public {
        bytes32 txID = _register(listingOwner, abi.encode("a"), bytes32(uint256(1)), bytes32(uint256(20)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(21)));

        PPREVSingle.Application memory a = pprev.getApplication(appId);
        assertEq(a.applicant, applicant);
        assertEq(a.txID, txID);
        assertEq(a.escrow, REQ_ESCROW);
        assertEq(uint256(a.status), uint256(PPREVSingle.AppStatus.PENDING));

        // Listing stays ACTIVE — engagement is a separate step
        PPREVSingle.Listing memory l = pprev.getListing(txID);
        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.ACTIVE));
    }

    /// 6) Apply by listing owner is rejected
    function test_Apply_Reverts_WhenOwnerApplies() public {
        bytes32 txID = _register(listingOwner, abi.encode("b"), bytes32(uint256(1)), bytes32(uint256(30)));

        vm.prank(listingOwner);
        vm.expectRevert(PPREVSingle.CannotApplyToOwnListing.selector);
        pprev.applyTx{value: REQ_ESCROW}(txID, bytes32(uint256(31)), block.timestamp, DUMMY_SIG);
    }

    /// 7) Apply rejected on insufficient escrow
    function test_Apply_Reverts_OnInsufficientEscrow() public {
        bytes32 txID = _register(listingOwner, abi.encode("c"), bytes32(uint256(1)), bytes32(uint256(40)));

        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.InsufficientEscrow.selector, REQ_ESCROW - 1, REQ_ESCROW));
        pprev.applyTx{value: REQ_ESCROW - 1}(txID, bytes32(uint256(41)), block.timestamp, DUMMY_SIG);
    }

    /// 8) Apply rejected on duplicate pending application by same applicant
    function test_Apply_Reverts_OnDuplicateApplication() public {
        bytes32 txID = _register(listingOwner, abi.encode("d"), bytes32(uint256(1)), bytes32(uint256(50)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(51)));

        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.DuplicateApplication.selector, appId));
        pprev.applyTx{value: REQ_ESCROW}(txID, bytes32(uint256(52)), block.timestamp, DUMMY_SIG);
    }

    /// 9) Engage happy path: listing → LOCKED, app → ENGAGED, engagement recorded
    function test_Engage_Succeeds() public {
        bytes32 txID = _register(listingOwner, abi.encode("e"), bytes32(uint256(1)), bytes32(uint256(60)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(61)));

        bytes32 engId = _engage(listingOwner, appId, 0);

        PPREVSingle.Listing memory l = pprev.getListing(txID);
        PPREVSingle.Application memory a = pprev.getApplication(appId);
        PPREVSingle.Engagement memory e = pprev.getEngagement(engId);

        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.LOCKED));
        assertEq(uint256(a.status), uint256(PPREVSingle.AppStatus.ENGAGED));
        assertEq(uint256(e.status), uint256(PPREVSingle.EngStatus.ACTIVE));
        assertEq(e.txID, txID);
        assertEq(e.appId, appId);
        assertEq(e.expiresAt, block.timestamp + DEFAULT_LOCK);
    }

    /// 10) Engage rejected when caller is not listing owner
    function test_Engage_Reverts_WhenNotOwner() public {
        bytes32 txID = _register(listingOwner, abi.encode("f"), bytes32(uint256(1)), bytes32(uint256(70)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(71)));

        vm.prank(otherApplicant);
        vm.expectRevert(
            abi.encodeWithSelector(PPREVSingle.CallerNotListingOwner.selector, otherApplicant, listingOwner)
        );
        pprev.engage(appId, 0);
    }

    /// 11) Settle happy path
    function test_Settle_Succeeds() public {
        bytes32 txID = _register(listingOwner, abi.encode("g"), bytes32(uint256(1)), bytes32(uint256(80)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(81)));
        bytes32 engId = _engage(listingOwner, appId, 0);

        _settle(listingOwner, engId, bytes32(uint256(82)));

        PPREVSingle.Listing memory l = pprev.getListing(txID);
        PPREVSingle.Engagement memory e = pprev.getEngagement(engId);
        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.SETTLED));
        assertEq(uint256(e.status), uint256(PPREVSingle.EngStatus.SETTLED));
    }

    /// 12) Settle accounting: owner receives escrow + collateral; applicant pays escrow
    function test_Settle_TransfersEscrowAndCollateral() public {
        uint256 ownerStart = listingOwner.balance;
        uint256 applicantStart = applicant.balance;

        bytes32 txID = _register(listingOwner, abi.encode("h"), bytes32(uint256(1)), bytes32(uint256(90)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(91)));
        bytes32 engId = _engage(listingOwner, appId, 0);
        _settle(listingOwner, engId, bytes32(uint256(92)));

        assertEq(listingOwner.balance, ownerStart + REQ_ESCROW); // -collateral + collateral + escrow
        assertEq(applicant.balance, applicantStart - REQ_ESCROW);
    }

    /// 13) Expire happy path: status transitions, escrow + slash transferred to applicant
    function test_Expire_Succeeds() public {
        bytes32 txID = _register(listingOwner, abi.encode("i"), bytes32(uint256(1)), bytes32(uint256(100)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(101)));
        bytes32 engId = _engage(listingOwner, appId, 0);

        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        PPREVSingle.Listing memory l = pprev.getListing(txID);
        PPREVSingle.Engagement memory e = pprev.getEngagement(engId);
        PPREVSingle.Application memory a = pprev.getApplication(appId);

        assertEq(uint256(e.status), uint256(PPREVSingle.EngStatus.EXPIRED));
        assertEq(uint256(a.status), uint256(PPREVSingle.AppStatus.EXPIRED));
        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.ACTIVE)); // ready for next applicant
        assertEq(l.expirationCount, 1);
        assertEq(l.collateral, MIN_COLLATERAL - MIN_COLLATERAL / 10);
    }

    /// 14) Expire economics: applicant receives escrow + 10% of collateral
    function test_Expire_SlashesCollateral_AndReturnsEscrow() public {
        uint256 applicantStart = applicant.balance;

        bytes32 txID = _register(listingOwner, abi.encode("j"), bytes32(uint256(1)), bytes32(uint256(110)));
        bytes32 appId = _applyTx(applicant, txID, bytes32(uint256(111)));
        bytes32 engId = _engage(listingOwner, appId, 0);

        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        // applicant paid REQ_ESCROW then got back REQ_ESCROW + 10% of MIN_COLLATERAL
        assertEq(applicant.balance, applicantStart + MIN_COLLATERAL / 10);
    }

    /// 15) Cancel happy path: collateral returned, state CANCELLED
    function test_Cancel_Succeeds() public {
        uint256 ownerStart = listingOwner.balance;
        bytes32 txID = _register(listingOwner, abi.encode("k"), bytes32(uint256(1)), bytes32(uint256(120)));

        vm.prank(listingOwner);
        pprev.cancel(txID);

        PPREVSingle.Listing memory l = pprev.getListing(txID);
        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.CANCELLED));
        assertEq(l.collateral, 0);
        assertEq(listingOwner.balance, ownerStart);
    }

    /// 16) Max expirations auto-cancels the listing; remaining collateral returned to owner
    function test_MaxExpirations_AutoCancelsListing() public {
        bytes32 txID = _register(listingOwner, abi.encode("m"), bytes32(uint256(1)), bytes32(uint256(200)));

        bytes32 appId;
        bytes32 engId;

        appId = _applyTx(applicant, txID, bytes32(uint256(300)));
        engId = _engage(listingOwner, appId, 0);
        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        appId = _applyTx(applicant, txID, bytes32(uint256(301)));
        engId = _engage(listingOwner, appId, 0);
        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        appId = _applyTx(applicant, txID, bytes32(uint256(302)));
        engId = _engage(listingOwner, appId, 0);
        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        appId = _applyTx(applicant, txID, bytes32(uint256(303)));
        engId = _engage(listingOwner, appId, 0);
        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        appId = _applyTx(applicant, txID, bytes32(uint256(304)));
        engId = _engage(listingOwner, appId, 0);
        vm.warp(block.timestamp + DEFAULT_LOCK + 1);
        pprev.expire(engId);

        PPREVSingle.Listing memory l = pprev.getListing(txID);
        assertEq(uint256(l.state), uint256(PPREVSingle.TxState.CANCELLED));
        assertEq(l.expirationCount, 5);
        assertEq(l.collateral, 0);

        // Further applications now fail
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(PPREVSingle.TxNotActive.selector, txID));
        pprev.applyTx{value: REQ_ESCROW}(txID, bytes32(uint256(999)), block.timestamp, DUMMY_SIG);
    }
}
