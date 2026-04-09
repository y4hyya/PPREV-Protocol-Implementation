// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * ============================================================================
 *  PPREV Protocol — Single-File MVP
 * ============================================================================
 *  Phases:
 *    1. Listing Registration
 *    2. Application
 *    3. Settlement
 *    4. Expiration
 *
 *  This file contains:
 *    - Verifier interfaces
 *    - Mock verifier implementations (for local simulation)
 *    - The main PPREVSingle contract
 * ============================================================================
 */

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    MessageHashUtils
} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ============================================================================
//  SECTION 1: Verifier Interfaces
// ============================================================================

/// @notice Interface for zero-knowledge proof verification.
interface IZKVerifier {
    /// @param proof   Encoded ZK proof bytes.
    /// @param inputs  Public inputs to the proof circuit.
    /// @return valid  True when the proof verifies against `inputs`.
    function verifyProof(
        bytes calldata proof,
        bytes32[] calldata inputs
    ) external view returns (bool valid);
}

/// @notice Interface for threshold-signature verification.
interface IThresholdSigVerifier {
    /// @param message   The message that was signed.
    /// @param signature Aggregated threshold signature bytes.
    /// @return valid    True when the signature is valid for `message`.
    function verifySignature(
        bytes32 message,
        bytes calldata signature
    ) external view returns (bool valid);
}

// ============================================================================
//  SECTION 2: Mock Verifier Contracts (for local / Docker simulation)
// ============================================================================

/// @title MockZKVerifier
/// @notice Always-pass stub for ZK proof verification. NEVER use in production.
contract MockZKVerifier is IZKVerifier {
    function verifyProof(
        bytes calldata /* proof */,
        bytes32[] calldata /* inputs */
    ) external pure override returns (bool) {
        return true;
    }
}

/// @title MockThresholdSignatureVerifier
/// @notice Always-pass stub for threshold-signature verification. NEVER use in production.
contract MockThresholdSignatureVerifier is IThresholdSigVerifier {
    function verifySignature(
        bytes32 /* message */,
        bytes calldata /* signature */
    ) external pure override returns (bool) {
        return true;
    }
}

/// @title ECDSANotaryVerifier
/// @notice Verifies EIP-191 ECDSA signatures from a known notary address.
///         Production replacement for MockThresholdSignatureVerifier.
contract ECDSANotaryVerifier is IThresholdSigVerifier {
    address public immutable notaryAddress;

    error InvalidNotaryAddress();

    constructor(address _notaryAddress) {
        if (_notaryAddress == address(0)) revert InvalidNotaryAddress();
        notaryAddress = _notaryAddress;
    }

    /// @notice Verify that `signature` over `message` was produced by the notary.
    /// @dev Applies EIP-191 prefix before ecrecover, matching ethers.js signMessage().
    function verifySignature(
        bytes32 message,
        bytes calldata signature
    ) external view override returns (bool) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(
            message
        );
        address recovered = ECDSA.recover(ethSignedHash, signature);
        return recovered == notaryAddress;
    }
}

// ============================================================================
//  SECTION 3: PPREVSingle — Main Contract
// ============================================================================

/// @title PPREVSingle
/// @notice Minimal MVP of the PPREV protocol for local Docker-based simulation.
///         Includes listing registration, application, settlement, and expiration.
contract PPREVSingle is ReentrancyGuard {
    // ────────────────────────────────────────────────────────────────────────
    //  3a. Enums
    // ────────────────────────────────────────────────────────────────────────

    enum ListingStatus {
        NONE, // default / not created
        ACTIVE, // open for applications
        LOCKED, // an application is pending
        SETTLED, // successfully settled
        CANCELLED // cancelled (future use)
    }

    enum ApplicationStatus {
        NONE, // default / not created
        PENDING_TRANSFER, // awaiting settlement
        SETTLED, // successfully settled
        EXPIRED // timed out
    }

    // ────────────────────────────────────────────────────────────────────────
    //  3b. Structs
    // ────────────────────────────────────────────────────────────────────────

    struct Listing {
        address owner;
        bytes32 adHash;
        bytes32 policyId;
        uint256 reqEscrow;
        bytes32 transcriptCommitment;
        uint256 collateral;
        uint256 createdAt;
        ListingStatus status;
        uint256 expirationCount;
    }

    struct Application {
        bytes32 appId;
        bytes32 adHash;
        address applicant;
        bytes32 policyId;
        bytes32 transcriptCommitment;
        uint256 escrowAmount;
        uint256 createdAt;
        ApplicationStatus status;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  3c. Custom Errors
    // ────────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NonceAlreadyUsed(bytes32 nonce);
    error InvalidZKProof();
    error InvalidThresholdSignature();
    error FreshnessWindowExceeded(uint256 timestamp, uint256 currentTime);
    error InsufficientCollateral(uint256 sent, uint256 required);
    error InsufficientEscrow(uint256 sent, uint256 required);
    error ListingNotActive(bytes32 adHash);
    error ListingNotLocked(bytes32 adHash);
    error PolicyMismatch(bytes32 expected, bytes32 provided);
    error DuplicateApplication(bytes32 appId);
    error ApplicationNotFound(bytes32 appId);
    error ApplicationNotPending(bytes32 appId);
    error ApplicationNotExpired(bytes32 appId);
    error CallerNotListingOwner(address caller, address owner);
    error ApplicationNotYetExpirable(bytes32 appId, uint256 expiresAt);
    error PolicyNotWhitelisted(bytes32 policyId);
    error TransferFailed();
    error ListingAlreadyExists(bytes32 adHash);
    error InvalidEscrowAmount();
    error InvalidVerifierAddress();
    error ApplicationExpiredCannotSettle(bytes32 appId);
    error CannotApplyToOwnListing();

    // ────────────────────────────────────────────────────────────────────────
    //  3d. Events
    // ────────────────────────────────────────────────────────────────────────

    event ListingRegistered(
        bytes32 indexed adHash,
        address indexed owner,
        bytes32 policyId,
        uint256 reqEscrow,
        uint256 collateral
    );

    event ApplicationCreated(
        bytes32 indexed appId,
        bytes32 indexed adHash,
        address indexed applicant,
        uint256 escrowAmount
    );

    event ApplicationSettled(
        bytes32 indexed appId,
        bytes32 indexed adHash,
        address indexed applicant,
        uint256 escrowTransferred,
        uint256 collateralReturned
    );

    event ApplicationExpired(
        bytes32 indexed appId,
        bytes32 indexed adHash,
        address indexed applicant,
        uint256 escrowReturned,
        uint256 slashAmount
    );

    event ListingCancelled(
        bytes32 indexed adHash,
        address indexed owner,
        uint256 collateralReturned
    );

    event VerifierUpdated(string verifierType, address newAddress);
    event PolicyWhitelisted(bytes32 indexed policyId, bool allowed);
    event ConfigUpdated(string key, uint256 value);

    // ────────────────────────────────────────────────────────────────────────
    //  3e. State Variables
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Contract admin / deployer.
    address public owner;

    /// @notice Reference to the ZK proof verifier contract.
    IZKVerifier public zkVerifier;

    /// @notice Reference to the threshold-signature verifier contract.
    IThresholdSigVerifier public thresholdVerifier;

    /// @notice Maximum age (in seconds) for submitted timestamps.
    uint256 public freshnessWindow;

    /// @notice Duration (in seconds) after which an application can be expired.
    uint256 public expiryTimeout;

    /// @notice Minimum collateral required for listing registration.
    uint256 public minCollateral;

    /// @notice Maximum number of expirations before a listing is auto-cancelled.
    uint256 public maxExpirations = 5;

    /// @dev adHash → Listing
    mapping(bytes32 => Listing) public listings;

    /// @dev appId → Application
    mapping(bytes32 => Application) public applications;

    /// @dev nonce → used flag  (replay protection)
    mapping(bytes32 => bool) public usedNonces;

    /// @dev policyId → whitelisted flag
    mapping(bytes32 => bool) public whitelistedPolicies;

    /// @dev adHash → (applicant → active appId), used to prevent duplicate active applications
    mapping(bytes32 => mapping(address => bytes32)) public activeApplications;

    // ────────────────────────────────────────────────────────────────────────
    //  3f. Modifiers
    // ────────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  3g. Constructor
    // ────────────────────────────────────────────────────────────────────────

    /// @param _zkVerifier          Address of the IZKVerifier implementation.
    /// @param _thresholdVerifier   Address of the IThresholdSigVerifier implementation.
    /// @param _freshnessWindow     Maximum age (seconds) for submitted timestamps.
    /// @param _expiryTimeout       Seconds before an application becomes expirable.
    /// @param _minCollateral       Minimum collateral in wei for listing registration.
    constructor(
        address _zkVerifier,
        address _thresholdVerifier,
        uint256 _freshnessWindow,
        uint256 _expiryTimeout,
        uint256 _minCollateral
    ) {
        if (_zkVerifier == address(0)) revert InvalidVerifierAddress();
        if (_thresholdVerifier == address(0)) revert InvalidVerifierAddress();
        owner = msg.sender;
        zkVerifier = IZKVerifier(_zkVerifier);
        thresholdVerifier = IThresholdSigVerifier(_thresholdVerifier);
        freshnessWindow = _freshnessWindow;
        expiryTimeout = _expiryTimeout;
        minCollateral = _minCollateral;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 4: Admin Functions
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Update the ZK verifier contract address.
    function setZKVerifier(address _zkVerifier) external onlyOwner {
        if (_zkVerifier == address(0)) revert InvalidVerifierAddress();
        zkVerifier = IZKVerifier(_zkVerifier);
        emit VerifierUpdated("ZKVerifier", _zkVerifier);
    }

    /// @notice Update the threshold-signature verifier contract address.
    function setThresholdVerifier(
        address _thresholdVerifier
    ) external onlyOwner {
        if (_thresholdVerifier == address(0)) revert InvalidVerifierAddress();
        thresholdVerifier = IThresholdSigVerifier(_thresholdVerifier);
        emit VerifierUpdated("ThresholdVerifier", _thresholdVerifier);
    }

    /// @notice Update the freshness window.
    function setFreshnessWindow(uint256 _freshnessWindow) external onlyOwner {
        freshnessWindow = _freshnessWindow;
        emit ConfigUpdated("freshnessWindow", _freshnessWindow);
    }

    /// @notice Update the expiry timeout.
    function setExpiryTimeout(uint256 _expiryTimeout) external onlyOwner {
        expiryTimeout = _expiryTimeout;
        emit ConfigUpdated("expiryTimeout", _expiryTimeout);
    }

    /// @notice Update the minimum collateral.
    function setMinCollateral(uint256 _minCollateral) external onlyOwner {
        minCollateral = _minCollateral;
        emit ConfigUpdated("minCollateral", _minCollateral);
    }

    /// @notice Update the maximum expiration count before auto-cancel.
    function setMaxExpirations(uint256 _maxExpirations) external onlyOwner {
        maxExpirations = _maxExpirations;
        emit ConfigUpdated("maxExpirations", _maxExpirations);
    }

    /// @notice Whitelist or un-whitelist a policy.
    function whitelistPolicy(
        bytes32 _policyId,
        bool _allowed
    ) external onlyOwner {
        whitelistedPolicies[_policyId] = _allowed;
        emit PolicyWhitelisted(_policyId, _allowed);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 5: Internal Verification Helpers
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Marks a nonce as used; reverts if already consumed.
    function _consumeNonce(bytes32 _nonce) internal {
        if (usedNonces[_nonce]) revert NonceAlreadyUsed(_nonce);
        usedNonces[_nonce] = true;
    }

    /// @dev Ensures the submitted timestamp is within the freshness window.
    function _verifyFreshness(uint256 _timestamp) internal view {
        if (block.timestamp > _timestamp + freshnessWindow) {
            revert FreshnessWindowExceeded(_timestamp, block.timestamp);
        }
    }

    /// @dev Delegates to the ZK verifier contract.
    function _verifyZKProof(
        bytes calldata _proof,
        bytes32[] calldata _inputs
    ) internal view {
        if (!zkVerifier.verifyProof(_proof, _inputs)) {
            revert InvalidZKProof();
        }
    }

    /// @dev Delegates to the threshold-signature verifier contract.
    function _verifyThresholdSig(
        bytes32 _message,
        bytes calldata _signature
    ) internal view {
        if (!thresholdVerifier.verifySignature(_message, _signature)) {
            revert InvalidThresholdSignature();
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 6: Phase 1 — Listing Registration
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Register a new listing.
    /// @dev Caller must send ETH >= minCollateral as collateral deposit.
    /// @param _adHash              Unique ad content hash.
    /// @param _policyId            Compliance policy identifier (must be whitelisted).
    /// @param _reqEscrow           Escrow amount applicants must deposit (in wei).
    /// @param _transcriptCommitment Commitment hash for the credential transcript.
    /// @param _timestamp           Freshness timestamp.
    /// @param _nonce               Unique nonce for replay protection.
    /// @param _zkProof             Encoded ZK proof bytes.
    /// @param _zkInputs            Public inputs for ZK proof verification.
    /// @param _thresholdSig        Threshold signature bytes.
    function registerListing(
        bytes32 _adHash,
        bytes32 _policyId,
        uint256 _reqEscrow,
        bytes32 _transcriptCommitment,
        uint256 _timestamp,
        bytes32 _nonce,
        bytes calldata _zkProof,
        bytes32[] calldata _zkInputs,
        bytes calldata _thresholdSig
    ) external payable nonReentrant {
        // --- Checks ---
        if (listings[_adHash].status != ListingStatus.NONE) {
            revert ListingAlreadyExists(_adHash);
        }
        if (!whitelistedPolicies[_policyId]) {
            revert PolicyNotWhitelisted(_policyId);
        }
        if (msg.value < minCollateral) {
            revert InsufficientCollateral(msg.value, minCollateral);
        }
        if (_reqEscrow == 0) {
            revert InvalidEscrowAmount();
        }

        _consumeNonce(_nonce);
        _verifyFreshness(_timestamp);

        // Build message for threshold-sig verification:
        // hash(caller, adHash, policyId, transcriptCommitment, timestamp, nonce)
        bytes32 sigMessage = keccak256(
            abi.encodePacked(
                msg.sender,
                _adHash,
                _policyId,
                _transcriptCommitment,
                _timestamp,
                _nonce
            )
        );
        _verifyZKProof(_zkProof, _zkInputs);
        _verifyThresholdSig(sigMessage, _thresholdSig);

        // --- Effects ---
        listings[_adHash] = Listing({
            owner: msg.sender,
            adHash: _adHash,
            policyId: _policyId,
            reqEscrow: _reqEscrow,
            transcriptCommitment: _transcriptCommitment,
            collateral: msg.value,
            createdAt: block.timestamp,
            status: ListingStatus.ACTIVE,
            expirationCount: 0
        });

        emit ListingRegistered(
            _adHash,
            msg.sender,
            _policyId,
            _reqEscrow,
            msg.value
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 7: Phase 2 — Application
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Submit an application to an active listing.
    /// @dev Caller must send ETH >= listing.reqEscrow as escrow deposit.
    /// @param _adHash              Ad hash of the target listing.
    /// @param _policyId            Policy that must match the listing.
    /// @param _transcriptCommitment Commitment hash for the applicant's transcript.
    /// @param _timestamp           Freshness timestamp.
    /// @param _nonce               Unique nonce for replay protection.
    /// @param _zkProof             Encoded ZK proof bytes.
    /// @param _zkInputs            Public inputs for ZK proof verification.
    /// @param _thresholdSig        Threshold signature bytes.
    function applyToListing(
        bytes32 _adHash,
        bytes32 _policyId,
        bytes32 _transcriptCommitment,
        uint256 _timestamp,
        bytes32 _nonce,
        bytes calldata _zkProof,
        bytes32[] calldata _zkInputs,
        bytes calldata _thresholdSig
    ) external payable nonReentrant {
        Listing storage listing = listings[_adHash];

        // --- Checks ---
        if (listing.status != ListingStatus.ACTIVE) {
            revert ListingNotActive(_adHash);
        }
        if (msg.sender == listing.owner) {
            revert CannotApplyToOwnListing();
        }
        if (listing.policyId != _policyId) {
            revert PolicyMismatch(listing.policyId, _policyId);
        }
        if (msg.value < listing.reqEscrow) {
            revert InsufficientEscrow(msg.value, listing.reqEscrow);
        }

        // Derive appId
        bytes32 appId = keccak256(
            abi.encodePacked(_adHash, msg.sender, _nonce)
        );

        // No duplicate active application by same applicant for the same listing
        if (activeApplications[_adHash][msg.sender] != bytes32(0)) {
            revert DuplicateApplication(
                activeApplications[_adHash][msg.sender]
            );
        }

        _consumeNonce(_nonce);
        _verifyFreshness(_timestamp);

        bytes32 sigMessage = keccak256(
            abi.encodePacked(
                msg.sender,
                _adHash,
                _policyId,
                _transcriptCommitment,
                _timestamp,
                _nonce
            )
        );
        _verifyZKProof(_zkProof, _zkInputs);
        _verifyThresholdSig(sigMessage, _thresholdSig);

        // --- Effects ---
        applications[appId] = Application({
            appId: appId,
            adHash: _adHash,
            applicant: msg.sender,
            policyId: _policyId,
            transcriptCommitment: _transcriptCommitment,
            escrowAmount: msg.value,
            createdAt: block.timestamp,
            status: ApplicationStatus.PENDING_TRANSFER
        });

        activeApplications[_adHash][msg.sender] = appId;
        listing.status = ListingStatus.LOCKED;

        emit ApplicationCreated(appId, _adHash, msg.sender, msg.value);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 8: Phase 3 — Settlement
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Settle a pending application. Only the listing owner may call this.
    /// @dev Transfers escrowed ETH to the listing owner and returns collateral.
    /// @param _appId               Application identifier.
    /// @param _transcriptCommitment Settlement transcript commitment.
    /// @param _timestamp           Freshness timestamp.
    /// @param _nonce               Unique nonce for replay protection.
    /// @param _zkProof             Encoded ZK proof bytes.
    /// @param _zkInputs            Public inputs for ZK proof verification.
    /// @param _thresholdSig        Threshold signature bytes.
    function settleListing(
        bytes32 _appId,
        bytes32 _transcriptCommitment,
        uint256 _timestamp,
        bytes32 _nonce,
        bytes calldata _zkProof,
        bytes32[] calldata _zkInputs,
        bytes calldata _thresholdSig
    ) external nonReentrant {
        Application storage app = applications[_appId];
        if (app.status == ApplicationStatus.NONE) {
            revert ApplicationNotFound(_appId);
        }

        Listing storage listing = listings[app.adHash];

        // --- Checks ---
        if (msg.sender != listing.owner) {
            revert CallerNotListingOwner(msg.sender, listing.owner);
        }
        if (app.status != ApplicationStatus.PENDING_TRANSFER) {
            revert ApplicationNotPending(_appId);
        }
        if (listing.status != ListingStatus.LOCKED) {
            revert ListingNotLocked(app.adHash);
        }

        _consumeNonce(_nonce);
        _verifyFreshness(_timestamp);

        // Verify not expired
        if (block.timestamp > app.createdAt + expiryTimeout) {
            revert ApplicationExpiredCannotSettle(_appId);
        }

        bytes32 sigMessage = keccak256(
            abi.encodePacked(
                msg.sender,
                _appId,
                _transcriptCommitment,
                _timestamp,
                _nonce
            )
        );
        _verifyZKProof(_zkProof, _zkInputs);
        _verifyThresholdSig(sigMessage, _thresholdSig);

        // --- Effects ---
        uint256 escrowToTransfer = app.escrowAmount;
        uint256 collateralToReturn = listing.collateral;

        app.status = ApplicationStatus.SETTLED;
        listing.status = ListingStatus.SETTLED;
        app.escrowAmount = 0;
        listing.collateral = 0;

        // Clear active-application tracker
        activeApplications[app.adHash][app.applicant] = bytes32(0);

        // --- Interactions (checks-effects-interactions) ---
        // Transfer escrowed ETH → listing owner
        (bool s1, ) = payable(listing.owner).call{value: escrowToTransfer}("");
        if (!s1) revert TransferFailed();

        // Return collateral → listing owner (they posted it)
        (bool s2, ) = payable(listing.owner).call{value: collateralToReturn}(
            ""
        );
        if (!s2) revert TransferFailed();

        emit ApplicationSettled(
            _appId,
            app.adHash,
            app.applicant,
            escrowToTransfer,
            collateralToReturn
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 9: Phase 4 — Expiration
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Expire an application after the timeout has passed.
    ///         Anyone may call this function.
    /// @dev MVP rule: escrow is returned to the applicant, listing becomes ACTIVE again.
    /// @param _appId The application to expire.
    function expireApplication(bytes32 _appId) external nonReentrant {
        Application storage app = applications[_appId];
        if (app.status == ApplicationStatus.NONE) {
            revert ApplicationNotFound(_appId);
        }
        if (app.status != ApplicationStatus.PENDING_TRANSFER) {
            revert ApplicationNotPending(_appId);
        }

        uint256 expiresAt = app.createdAt + expiryTimeout;
        if (block.timestamp <= expiresAt) {
            revert ApplicationNotYetExpirable(_appId, expiresAt);
        }

        Listing storage listing = listings[app.adHash];

        // --- Effects ---
        uint256 escrowToReturn = app.escrowAmount;
        uint256 slashAmount = listing.collateral / 10; // 10% of landlord collateral

        app.status = ApplicationStatus.EXPIRED;
        app.escrowAmount = 0;
        listing.collateral -= slashAmount;
        listing.expirationCount++;

        // Clear active-application tracker
        activeApplications[app.adHash][app.applicant] = bytes32(0);

        // Determine if listing should auto-cancel after too many expirations
        bool autoCancelled = listing.expirationCount >= maxExpirations;
        uint256 remainingCollateral = 0;

        if (autoCancelled) {
            listing.status = ListingStatus.CANCELLED;
            remainingCollateral = listing.collateral;
            listing.collateral = 0;
        } else {
            listing.status = ListingStatus.ACTIVE;
        }

        // --- Interactions ---
        // Return escrow + slash penalty to applicant
        (bool success, ) = payable(app.applicant).call{
            value: escrowToReturn + slashAmount
        }("");
        if (!success) revert TransferFailed();

        emit ApplicationExpired(
            _appId,
            app.adHash,
            app.applicant,
            escrowToReturn,
            slashAmount
        );

        // If auto-cancelled, return remaining collateral to listing owner
        if (autoCancelled) {
            if (remainingCollateral > 0) {
                (bool s2, ) = payable(listing.owner).call{
                    value: remainingCollateral
                }("");
                if (!s2) revert TransferFailed();
            }
            emit ListingCancelled(
                app.adHash,
                listing.owner,
                remainingCollateral
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 9b: Listing Cancellation
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Cancel an active listing and return collateral to the owner.
    /// @dev Only the listing owner may cancel, and only while the listing is ACTIVE.
    /// @param _adHash The listing to cancel.
    function cancelListing(bytes32 _adHash) external nonReentrant {
        Listing storage listing = listings[_adHash];

        if (listing.status != ListingStatus.ACTIVE) {
            revert ListingNotActive(_adHash);
        }
        if (msg.sender != listing.owner) {
            revert CallerNotListingOwner(msg.sender, listing.owner);
        }

        // --- Effects ---
        uint256 collateralToReturn = listing.collateral;
        listing.status = ListingStatus.CANCELLED;
        listing.collateral = 0;

        // --- Interactions ---
        (bool success, ) = payable(listing.owner).call{
            value: collateralToReturn
        }("");
        if (!success) revert TransferFailed();

        emit ListingCancelled(_adHash, listing.owner, collateralToReturn);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  SECTION 10: View / Helper Functions
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Retrieve full listing details.
    function getListing(
        bytes32 _adHash
    ) external view returns (Listing memory) {
        return listings[_adHash];
    }

    /// @notice Retrieve full application details.
    function getApplication(
        bytes32 _appId
    ) external view returns (Application memory) {
        return applications[_appId];
    }

    /// @notice Check whether a nonce has been consumed.
    function isNonceUsed(bytes32 _nonce) external view returns (bool) {
        return usedNonces[_nonce];
    }

    /// @notice Check whether a policy is whitelisted.
    function isPolicyWhitelisted(
        bytes32 _policyId
    ) external view returns (bool) {
        return whitelistedPolicies[_policyId];
    }
}
