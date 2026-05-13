// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ============================================================================
 *  PPREV — Privacy-Preserving Real Estate Verification Protocol
 * ============================================================================
 *  On-chain enforcement layer for the protocol described in Section V of
 *  the PPREV IEEE conference paper.
 *
 *  Six on-chain operations (paper Sec. V):
 *    register(txData, policyId_R/A/S, salt, ...)   — Phase 1 (phi_R)
 *    applyTx(txID, ...)                            — Phase 2 application (phi_A)
 *    engage(appId, lockWindow)                     — Phase 2 engagement
 *    settle(engId, ...)                            — Phase 3 (phi_S)
 *    expire(engId)                                 — engagement timeout
 *    cancel(txID)                                  — listing-owner cancel
 *
 *  Transaction commitment (paper Eq. 1):
 *    C_tx = H(txData || policyID_R || r)
 *  Used as the transaction identifier txID throughout this implementation
 *  (paper writes txID and C_tx as separate fields; they collapse to one
 *  value here, so duplicate field references are included once).
 *
 *  Notary attestation (paper Eq. 4 / 7 / 9):
 *    sigma = Sign(sk_notary, x || addr_SC)
 *  where x is the phase-specific public statement:
 *    x_R = (C_tx, txDataHash, policyID_R, eta_R, t_auth_R)
 *    x_A = (txID,             policyID_A, eta_A, t_auth_A)
 *    x_S = (engID, txID,      policyID_S, eta_S, t_auth_S)
 *  txDataHash = keccak256(txData) substitutes for the variable-length txData
 *  field in the on-chain hash; the binding remains since H is
 *  collision-resistant. The on-chain check enforces only
 *  Verify(vk_notary, sigma, x || addr_SC). The ZK proof pi is verified by
 *  the notary off-chain and never submitted on-chain (paper Sec. V.B).
 *
 *  NOTE on signature scope: per paper V.B-V.D, the signed message does not
 *  bind msg.sender. A sigma observed in the mempool can be resubmitted by a
 *  different EOA, who would become the listing owner / applicant. This
 *  matches paper-literal behavior; a deployment that wants signature-
 *  forwarding protection would add msg.sender to the signed bytes.
 * ============================================================================
 */

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ============================================================================
//  Notary verifier interface and reference implementations
// ============================================================================

/// @notice Interface for notary attestation signature verification.
interface INotaryVerifier {
    /// @param message   keccak256 of the signed payload (x || addr_SC).
    /// @param signature Notary signature bytes.
    /// @return valid    True when the signature is valid for `message`.
    function verifySignature(bytes32 message, bytes calldata signature) external view returns (bool valid);
}

/// @title MockNotaryVerifier
/// @notice Always-pass stub. Used for baseline gas measurement. NEVER use in production.
contract MockNotaryVerifier is INotaryVerifier {
    function verifySignature(bytes32, bytes calldata) external pure override returns (bool) {
        return true;
    }
}

/// @title ECDSANotaryVerifier
/// @notice EIP-191 ECDSA verifier for a single fixed notary address.
///         Used in binding-category security tests and as the
///         single-notary reference for deployment.
contract ECDSANotaryVerifier is INotaryVerifier {
    address public immutable notaryAddress;

    error InvalidNotaryAddress();

    constructor(address _notaryAddress) {
        if (_notaryAddress == address(0)) revert InvalidNotaryAddress();
        notaryAddress = _notaryAddress;
    }

    function verifySignature(bytes32 message, bytes calldata signature) external view override returns (bool) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(message);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethSignedHash, signature);
        if (err != ECDSA.RecoverError.NoError) return false;
        return recovered == notaryAddress;
    }
}

// ============================================================================
//  PPREVSingle — Main Contract
// ============================================================================

/// @title PPREVSingle
/// @notice Single-file on-chain enforcement layer for the PPREV protocol.
contract PPREVSingle is ReentrancyGuard {
    // ────────────────────────────────────────────────────────────────────────
    //  Enums
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Paper Sec. V.A. EXPIRED is not represented as a listing state;
    ///      after an engagement expiration the listing returns to ACTIVE
    ///      (or to CANCELLED once expirationCount reaches maxExpirations).
    enum TxState {
        NONE,
        ACTIVE,
        LOCKED,
        SETTLED,
        CANCELLED
    }

    enum AppStatus {
        NONE,
        PENDING,
        ENGAGED,
        EXPIRED,
        CANCELLED
    }

    enum EngStatus {
        NONE,
        ACTIVE,
        SETTLED,
        EXPIRED
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Structs
    // ────────────────────────────────────────────────────────────────────────

    struct Listing {
        bytes32 txID; // == C_tx by construction
        address owner;
        bytes32 policyId_R;
        bytes32 policyId_A;
        bytes32 policyId_S;
        uint256 reqEscrow;
        uint256 collateral;
        uint256 createdAt;
        TxState state;
        uint256 expirationCount;
        bytes32 txDataHash;
    }

    struct Application {
        bytes32 appId;
        bytes32 txID;
        address applicant;
        uint256 escrow;
        uint256 createdAt;
        AppStatus status;
    }

    struct Engagement {
        bytes32 engId;
        bytes32 txID;
        bytes32 appId;
        uint256 expiresAt;
        EngStatus status;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Custom Errors
    // ────────────────────────────────────────────────────────────────────────

    error NotAdmin();
    error NonceAlreadyUsed(bytes32 nonce);
    error InvalidNotarySignature();
    error FreshnessWindowExceeded(uint256 timestamp, uint256 currentTime);
    error InsufficientCollateral(uint256 sent, uint256 required);
    error InsufficientEscrow(uint256 sent, uint256 required);
    error TxNotActive(bytes32 txID);
    error TxNotLocked(bytes32 txID);
    error TxAlreadyExists(bytes32 txID);
    error ApplicationNotFound(bytes32 appId);
    error ApplicationNotPending(bytes32 appId);
    error EngagementNotFound(bytes32 engId);
    error EngagementNotActive(bytes32 engId);
    error CallerNotListingOwner(address caller, address owner);
    error EngagementAlreadyExpired(bytes32 engId);
    error EngagementNotYetExpirable(bytes32 engId, uint256 expiresAt);
    error PolicyNotWhitelisted(bytes32 policyId);
    error TransferFailed();
    error InvalidEscrowAmount();
    error InvalidVerifierAddress();
    error CannotApplyToOwnListing();
    error DuplicateApplication(bytes32 appId);
    error EmptyTxData();

    // ────────────────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────────────────

    event TxRegistered(
        bytes32 indexed txID,
        address indexed owner,
        bytes32 policyId_R,
        bytes32 policyId_A,
        bytes32 policyId_S,
        uint256 reqEscrow,
        uint256 collateral
    );

    event ApplicationCreated(bytes32 indexed appId, bytes32 indexed txID, address indexed applicant, uint256 escrow);

    event Engaged(bytes32 indexed engId, bytes32 indexed txID, bytes32 indexed appId, address owner, uint256 expiresAt);

    event Settled(
        bytes32 indexed engId,
        bytes32 indexed txID,
        address indexed applicant,
        uint256 escrowTransferred,
        uint256 collateralReturned
    );

    event Expired(
        bytes32 indexed engId,
        bytes32 indexed txID,
        address indexed applicant,
        uint256 escrowReturned,
        uint256 slashAmount
    );

    event Cancelled(bytes32 indexed txID, address indexed owner, uint256 collateralReturned);

    event NotaryVerifierUpdated(address newAddress);
    event PolicyWhitelisted(bytes32 indexed policyId, bool allowed);
    event ConfigUpdated(string key, uint256 value);

    // ────────────────────────────────────────────────────────────────────────
    //  State
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Contract administrator (deployer).
    address public admin;

    /// @notice Notary attestation signature verifier.
    INotaryVerifier public notaryVerifier;

    /// @notice Maximum age (seconds) for submitted attestation timestamps (paper Δ).
    uint256 public freshnessWindow;

    /// @notice Default lock window (seconds) applied when engage() is called with _lockWindow == 0
    ///         (paper τ_lock; per-engagement overrides take precedence).
    uint256 public defaultLockWindow;

    /// @notice Minimum collateral required at registration (in wei).
    uint256 public minCollateral;

    /// @notice Maximum number of engagement expirations before listing auto-cancels.
    uint256 public maxExpirations = 5;

    /// @dev txID (== C_tx) → Listing
    mapping(bytes32 => Listing) public listings;

    /// @dev appId → Application
    mapping(bytes32 => Application) public applications;

    /// @dev engId → Engagement
    mapping(bytes32 => Engagement) public engagements;

    /// @dev nonce → consumed flag (single-use, global across phases — see paper V.C cross-phase substitution)
    mapping(bytes32 => bool) public usedNonces;

    /// @dev policyId → whitelisted flag
    mapping(bytes32 => bool) public whitelistedPolicies;

    /// @dev txID → (applicant → currently pending appId). Cleared on engage/expire/settle.
    mapping(bytes32 => mapping(address => bytes32)) public activeApplications;

    // ────────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ────────────────────────────────────────────────────────────────────────

    /// @param _notaryVerifier    INotaryVerifier implementation address.
    /// @param _freshnessWindow   Δ in seconds.
    /// @param _defaultLockWindow Default τ_lock in seconds when engage() passes 0.
    /// @param _minCollateral     Minimum wei required at registration.
    constructor(address _notaryVerifier, uint256 _freshnessWindow, uint256 _defaultLockWindow, uint256 _minCollateral) {
        if (_notaryVerifier == address(0)) revert InvalidVerifierAddress();
        admin = msg.sender;
        notaryVerifier = INotaryVerifier(_notaryVerifier);
        freshnessWindow = _freshnessWindow;
        defaultLockWindow = _defaultLockWindow;
        minCollateral = _minCollateral;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Admin
    // ════════════════════════════════════════════════════════════════════════

    function setNotaryVerifier(address _v) external onlyAdmin {
        if (_v == address(0)) revert InvalidVerifierAddress();
        notaryVerifier = INotaryVerifier(_v);
        emit NotaryVerifierUpdated(_v);
    }

    function setFreshnessWindow(uint256 _w) external onlyAdmin {
        freshnessWindow = _w;
        emit ConfigUpdated("freshnessWindow", _w);
    }

    function setDefaultLockWindow(uint256 _w) external onlyAdmin {
        defaultLockWindow = _w;
        emit ConfigUpdated("defaultLockWindow", _w);
    }

    function setMinCollateral(uint256 _c) external onlyAdmin {
        minCollateral = _c;
        emit ConfigUpdated("minCollateral", _c);
    }

    function setMaxExpirations(uint256 _m) external onlyAdmin {
        maxExpirations = _m;
        emit ConfigUpdated("maxExpirations", _m);
    }

    function whitelistPolicy(bytes32 _p, bool _a) external onlyAdmin {
        whitelistedPolicies[_p] = _a;
        emit PolicyWhitelisted(_p, _a);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ════════════════════════════════════════════════════════════════════════

    function _consumeNonce(bytes32 _nonce) internal {
        if (usedNonces[_nonce]) revert NonceAlreadyUsed(_nonce);
        usedNonces[_nonce] = true;
    }

    function _verifyFreshness(uint256 _timestamp) internal view {
        if (block.timestamp > _timestamp + freshnessWindow) {
            revert FreshnessWindowExceeded(_timestamp, block.timestamp);
        }
    }

    function _verifyNotarySig(bytes32 _message, bytes calldata _signature) internal view {
        if (!notaryVerifier.verifySignature(_message, _signature)) {
            revert InvalidNotarySignature();
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Phase 1 — Register (paper V.B)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Register a new transaction. Caller becomes the listing owner.
    /// @dev    Requires msg.value >= minCollateral as collateral deposit.
    ///         All three policy IDs must be whitelisted.
    /// @param _txData        Public transaction parameters (paper txData).
    /// @param _policyId_R    Registration predicate identifier.
    /// @param _policyId_A    Application predicate identifier.
    /// @param _policyId_S    Settlement predicate identifier.
    /// @param _salt          Random salt r entering C_tx (paper Eq. 1).
    /// @param _reqEscrow     Escrow amount applicants must deposit (wei).
    /// @param _nonce         Single-use registration nonce η_R.
    /// @param _timestamp     Attestation timestamp t_auth,R.
    /// @param _sigma         Notary attestation σ_R over x_R || addr_SC.
    /// @return txID          Assigned transaction identifier (= C_tx).
    function register(
        bytes calldata _txData,
        bytes32 _policyId_R,
        bytes32 _policyId_A,
        bytes32 _policyId_S,
        bytes32 _salt,
        uint256 _reqEscrow,
        bytes32 _nonce,
        uint256 _timestamp,
        bytes calldata _sigma
    ) external payable nonReentrant returns (bytes32 txID) {
        // Checks
        if (_txData.length == 0) revert EmptyTxData();
        if (!whitelistedPolicies[_policyId_R]) revert PolicyNotWhitelisted(_policyId_R);
        if (!whitelistedPolicies[_policyId_A]) revert PolicyNotWhitelisted(_policyId_A);
        if (!whitelistedPolicies[_policyId_S]) revert PolicyNotWhitelisted(_policyId_S);
        if (msg.value < minCollateral) revert InsufficientCollateral(msg.value, minCollateral);
        if (_reqEscrow == 0) revert InvalidEscrowAmount();

        // C_tx = H(txData || policyID_R || r)
        txID = keccak256(abi.encodePacked(_txData, _policyId_R, _salt));
        if (listings[txID].state != TxState.NONE) revert TxAlreadyExists(txID);

        _consumeNonce(_nonce);
        _verifyFreshness(_timestamp);

        // sigma_R = Sign(sk, x_R || addr_SC), x_R = (C_tx, H(txData), policyID_R, eta_R, t_auth_R)
        bytes32 txDataHash = keccak256(_txData);
        bytes32 sigMessage =
            keccak256(abi.encodePacked(txID, txDataHash, _policyId_R, _nonce, _timestamp, address(this)));
        _verifyNotarySig(sigMessage, _sigma);

        // Effects
        listings[txID] = Listing({
            txID: txID,
            owner: msg.sender,
            policyId_R: _policyId_R,
            policyId_A: _policyId_A,
            policyId_S: _policyId_S,
            reqEscrow: _reqEscrow,
            collateral: msg.value,
            createdAt: block.timestamp,
            state: TxState.ACTIVE,
            expirationCount: 0,
            txDataHash: txDataHash
        });

        emit TxRegistered(txID, msg.sender, _policyId_R, _policyId_A, _policyId_S, _reqEscrow, msg.value);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Phase 2 — Apply (paper V.C application step)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Submit an application for an active transaction. Records the
    ///         applicant's escrow and a PENDING application; does NOT lock
    ///         the listing (engagement is a separate step, paper V.C).
    /// @param _txID       Target transaction identifier.
    /// @param _nonce      Single-use nonce η_A.
    /// @param _timestamp  Attestation timestamp t_auth,A.
    /// @param _sigma      Notary attestation σ_A over x_A || addr_SC.
    /// @return appId      Assigned application identifier.
    function applyTx(bytes32 _txID, bytes32 _nonce, uint256 _timestamp, bytes calldata _sigma)
        external
        payable
        nonReentrant
        returns (bytes32 appId)
    {
        Listing storage listing = listings[_txID];

        if (listing.state != TxState.ACTIVE) revert TxNotActive(_txID);
        if (msg.sender == listing.owner) revert CannotApplyToOwnListing();
        if (msg.value < listing.reqEscrow) revert InsufficientEscrow(msg.value, listing.reqEscrow);

        // Reject if applicant already has a PENDING application for this txID
        bytes32 existing = activeApplications[_txID][msg.sender];
        if (existing != bytes32(0) && applications[existing].status == AppStatus.PENDING) {
            revert DuplicateApplication(existing);
        }

        appId = keccak256(abi.encodePacked(_txID, msg.sender, _nonce));

        _consumeNonce(_nonce);
        _verifyFreshness(_timestamp);

        // x_A = (txID == C_tx, policyID_A, eta_A, t_auth_A); paper writes txID and C_tx as
        // separate fields, but in this implementation they are the same value (registered
        // listings are keyed by C_tx), so the field is included once.
        bytes32 sigMessage = keccak256(abi.encodePacked(_txID, listing.policyId_A, _nonce, _timestamp, address(this)));
        _verifyNotarySig(sigMessage, _sigma);

        applications[appId] = Application({
            appId: appId,
            txID: _txID,
            applicant: msg.sender,
            escrow: msg.value,
            createdAt: block.timestamp,
            status: AppStatus.PENDING
        });

        activeApplications[_txID][msg.sender] = appId;

        emit ApplicationCreated(appId, _txID, msg.sender, msg.value);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Phase 2 — Engage (paper V.C engagement step)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Listing owner accepts a pending application. Locks the listing
    ///         and starts the lock window. No notary attestation required;
    ///         authentication is via msg.sender against the recorded owner.
    /// @param _appId       Application to engage.
    /// @param _lockWindow  Engagement lock window in seconds. 0 ⇒ use defaultLockWindow.
    /// @return engId       Assigned engagement identifier.
    function engage(bytes32 _appId, uint256 _lockWindow) external nonReentrant returns (bytes32 engId) {
        Application storage app = applications[_appId];
        if (app.status == AppStatus.NONE) revert ApplicationNotFound(_appId);
        if (app.status != AppStatus.PENDING) revert ApplicationNotPending(_appId);

        Listing storage listing = listings[app.txID];
        if (msg.sender != listing.owner) revert CallerNotListingOwner(msg.sender, listing.owner);
        if (listing.state != TxState.ACTIVE) revert TxNotActive(app.txID);

        uint256 lockDuration = _lockWindow == 0 ? defaultLockWindow : _lockWindow;
        uint256 expiresAt = block.timestamp + lockDuration;

        engId = keccak256(abi.encodePacked(_appId, listing.owner, address(this)));

        engagements[engId] =
            Engagement({engId: engId, txID: app.txID, appId: _appId, expiresAt: expiresAt, status: EngStatus.ACTIVE});

        app.status = AppStatus.ENGAGED;
        listing.state = TxState.LOCKED;

        // The application is no longer "pending" for duplicate-check purposes.
        activeApplications[app.txID][app.applicant] = bytes32(0);

        emit Engaged(engId, app.txID, _appId, msg.sender, expiresAt);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Phase 3 — Settle (paper V.D)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Listing owner finalises a locked engagement.
    ///         Transfers escrow to the listing owner and returns collateral.
    /// @param _engId      Engagement to settle.
    /// @param _nonce      Single-use nonce η_S.
    /// @param _timestamp  Attestation timestamp t_auth,S.
    /// @param _sigma      Notary attestation σ_S over x_S || addr_SC.
    function settle(bytes32 _engId, bytes32 _nonce, uint256 _timestamp, bytes calldata _sigma) external nonReentrant {
        Engagement storage eng = engagements[_engId];
        if (eng.status == EngStatus.NONE) revert EngagementNotFound(_engId);
        if (eng.status != EngStatus.ACTIVE) revert EngagementNotActive(_engId);

        Listing storage listing = listings[eng.txID];
        Application storage app = applications[eng.appId];

        if (msg.sender != listing.owner) revert CallerNotListingOwner(msg.sender, listing.owner);
        if (listing.state != TxState.LOCKED) revert TxNotLocked(eng.txID);
        if (block.timestamp > eng.expiresAt) revert EngagementAlreadyExpired(_engId);

        _consumeNonce(_nonce);
        _verifyFreshness(_timestamp);

        // x_S = (engID, txID == C_tx, policyID_S, eta_S, t_auth_S); txID and C_tx collapse here
        bytes32 sigMessage =
            keccak256(abi.encodePacked(_engId, eng.txID, listing.policyId_S, _nonce, _timestamp, address(this)));
        _verifyNotarySig(sigMessage, _sigma);

        // Effects
        uint256 escrowToTransfer = app.escrow;
        uint256 collateralToReturn = listing.collateral;

        eng.status = EngStatus.SETTLED;
        listing.state = TxState.SETTLED;
        app.escrow = 0;
        listing.collateral = 0;

        // Interactions
        (bool s1,) = payable(listing.owner).call{value: escrowToTransfer}("");
        if (!s1) revert TransferFailed();

        (bool s2,) = payable(listing.owner).call{value: collateralToReturn}("");
        if (!s2) revert TransferFailed();

        emit Settled(_engId, eng.txID, app.applicant, escrowToTransfer, collateralToReturn);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Phase 3 — Expire (paper V.D expiration)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Anyone may invoke after engagement.expiresAt has passed.
    ///         Returns escrow + 10% of remaining collateral to the applicant.
    ///         Slashing is compounding (paper V.D): after k expirations the
    ///         listing owner's collateral is 0.9^k of the original.
    /// @param _engId Engagement to expire.
    function expire(bytes32 _engId) external nonReentrant {
        Engagement storage eng = engagements[_engId];
        if (eng.status == EngStatus.NONE) revert EngagementNotFound(_engId);
        if (eng.status != EngStatus.ACTIVE) revert EngagementNotActive(_engId);
        if (block.timestamp <= eng.expiresAt) revert EngagementNotYetExpirable(_engId, eng.expiresAt);

        Listing storage listing = listings[eng.txID];
        Application storage app = applications[eng.appId];

        uint256 escrowToReturn = app.escrow;
        uint256 slashAmount = listing.collateral / 10;

        eng.status = EngStatus.EXPIRED;
        app.status = AppStatus.EXPIRED;
        app.escrow = 0;
        listing.collateral -= slashAmount;
        listing.expirationCount += 1;

        bool autoCancelled = listing.expirationCount >= maxExpirations;
        uint256 remainingCollateral = 0;

        if (autoCancelled) {
            listing.state = TxState.CANCELLED;
            remainingCollateral = listing.collateral;
            listing.collateral = 0;
        } else {
            listing.state = TxState.ACTIVE;
        }

        // Interactions
        (bool s,) = payable(app.applicant).call{value: escrowToReturn + slashAmount}("");
        if (!s) revert TransferFailed();

        emit Expired(_engId, eng.txID, app.applicant, escrowToReturn, slashAmount);

        if (autoCancelled) {
            if (remainingCollateral > 0) {
                (bool s2,) = payable(listing.owner).call{value: remainingCollateral}("");
                if (!s2) revert TransferFailed();
            }
            emit Cancelled(eng.txID, listing.owner, remainingCollateral);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Cancel (paper V.E)
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Listing owner cancels an active listing (no engagement in progress).
    /// @param _txID The listing to cancel.
    function cancel(bytes32 _txID) external nonReentrant {
        Listing storage listing = listings[_txID];
        if (listing.state != TxState.ACTIVE) revert TxNotActive(_txID);
        if (msg.sender != listing.owner) revert CallerNotListingOwner(msg.sender, listing.owner);

        uint256 collateralToReturn = listing.collateral;
        listing.state = TxState.CANCELLED;
        listing.collateral = 0;

        (bool s,) = payable(listing.owner).call{value: collateralToReturn}("");
        if (!s) revert TransferFailed();

        emit Cancelled(_txID, listing.owner, collateralToReturn);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Views
    // ════════════════════════════════════════════════════════════════════════

    function getListing(bytes32 _txID) external view returns (Listing memory) {
        return listings[_txID];
    }

    function getApplication(bytes32 _appId) external view returns (Application memory) {
        return applications[_appId];
    }

    function getEngagement(bytes32 _engId) external view returns (Engagement memory) {
        return engagements[_engId];
    }

    function isNonceUsed(bytes32 _nonce) external view returns (bool) {
        return usedNonces[_nonce];
    }

    function isPolicyWhitelisted(bytes32 _policyId) external view returns (bool) {
        return whitelistedPolicies[_policyId];
    }
}
