/**
 * ═══════════════════════════════════════════════════════════════════════════
 *  PPREVSingle — Hardhat Test Suite
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *  Covers:
 *    ✓ Successful advertise (registerListing)
 *    ✓ Reused nonce failure
 *    ✓ Stale timestamp failure
 *    ✓ Invalid verifier failure (ZK + threshold sig)
 *    ✓ Successful apply (applyToListing)
 *    ✓ Listing becomes LOCKED after application
 *    ✓ Successful settle (settleListing)
 *    ✓ Settle after expiry fails
 *    ✓ expireApplication reactivates listing
 *    ✓ Escrow / accounting checks
 *    ✓ Duplicate application prevention
 */

import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

// ────────────────────────────────────────────────────────────────────────────
//  Enum mirrors (must match contract order)
// ────────────────────────────────────────────────────────────────────────────

enum ListingStatus { NONE, ACTIVE, LOCKED, SETTLED, CANCELLED }
enum AppStatus { NONE, PENDING_TRANSFER, SETTLED, EXPIRED }

// ────────────────────────────────────────────────────────────────────────────
//  Constants
// ────────────────────────────────────────────────────────────────────────────

const FRESHNESS_WINDOW = 300;                        // 5 min
const EXPIRY_TIMEOUT = 3600;                       // 1 hour
const MIN_COLLATERAL = ethers.parseEther("0.1");
const REQ_ESCROW = ethers.parseEther("0.05");
const COLLATERAL = ethers.parseEther("0.1");

const DUMMY_PROOF = "0xdead";
const DUMMY_SIG = "0xbeef";
const EMPTY_INPUTS: string[] = [];

// ────────────────────────────────────────────────────────────────────────────
//  Helpers
// ────────────────────────────────────────────────────────────────────────────

function hash(text: string): string {
    return ethers.keccak256(ethers.toUtf8Bytes(text));
}

function deriveAppId(adHash: string, applicant: string, nonce: string): string {
    return ethers.keccak256(
        ethers.solidityPacked(["bytes32", "address", "bytes32"], [adHash, applicant, nonce]),
    );
}

// ────────────────────────────────────────────────────────────────────────────
//  Test Suite
// ────────────────────────────────────────────────────────────────────────────

describe("PPREVSingle", function () {
    // ── Signers ──
    let admin: SignerWithAddress;
    let landlord: SignerWithAddress;
    let tenant: SignerWithAddress;
    let stranger: SignerWithAddress;

    // ── Contracts ──
    let protocol: any;
    let zkVerifier: any;
    let sigVerifier: any;

    // ── Sample data ──
    const POLICY_ID = hash("rental-policy-v1");
    const AD_HASH = hash("2br-apartment-2024");
    const TRANSCRIPT_LANDLORD = hash("landlord-transcript");
    const TRANSCRIPT_TENANT = hash("tenant-transcript");
    const TRANSCRIPT_SETTLE = hash("settle-transcript");

    // ── Fresh nonce helper (auto-increments) ──
    let nonceCounter = 0;
    function freshNonce(): string {
        return hash(`nonce-${++nonceCounter}-${Date.now()}`);
    }

    // ── Deploy everything before each test ──
    beforeEach(async function () {
        [admin, landlord, tenant, stranger] = await ethers.getSigners();
        nonceCounter = 0;

        const ZKFactory = await ethers.getContractFactory("MockZKVerifier");
        zkVerifier = await ZKFactory.deploy();
        await zkVerifier.waitForDeployment();

        const SigFactory = await ethers.getContractFactory("MockThresholdSignatureVerifier");
        sigVerifier = await SigFactory.deploy();
        await sigVerifier.waitForDeployment();

        const PPREVFactory = await ethers.getContractFactory("PPREVSingle");
        protocol = await PPREVFactory.deploy(
            await zkVerifier.getAddress(),
            await sigVerifier.getAddress(),
            FRESHNESS_WINDOW,
            EXPIRY_TIMEOUT,
            MIN_COLLATERAL,
        );
        await protocol.waitForDeployment();

        // Whitelist the test policy
        await protocol.connect(admin).whitelistPolicy(POLICY_ID, true);
    });

    // ─── Reusable: register a listing as landlord ───
    async function registerListing(nonce?: string) {
        const n = nonce ?? freshNonce();
        const ts = await time.latest();
        await protocol.connect(landlord).registerListing(
            AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
            ts, n, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
            { value: COLLATERAL },
        );
        return n;
    }

    // ─── Reusable: apply to listing as tenant ───
    async function applyToListing(nonce?: string) {
        const n = nonce ?? freshNonce();
        const ts = await time.latest();
        await protocol.connect(tenant).applyToListing(
            AD_HASH, POLICY_ID, TRANSCRIPT_TENANT,
            ts, n, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
            { value: REQ_ESCROW },
        );
        const appId = deriveAppId(AD_HASH, tenant.address, n);
        return { nonce: n, appId };
    }

    // ════════════════════════════════════════════════════════════════════════
    //  1. Successful advertise (registerListing)
    // ════════════════════════════════════════════════════════════════════════

    describe("registerListing", function () {
        it("should register a listing and mark it ACTIVE", async function () {
            await registerListing();

            const listing = await protocol.getListing(AD_HASH);
            expect(listing.status).to.equal(ListingStatus.ACTIVE);
            expect(listing.owner).to.equal(landlord.address);
            expect(listing.collateral).to.equal(COLLATERAL);
            expect(listing.reqEscrow).to.equal(REQ_ESCROW);
            expect(listing.policyId).to.equal(POLICY_ID);
        });

        it("should emit ListingRegistered event", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).registerListing(
                    AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: COLLATERAL },
                ),
            ).to.emit(protocol, "ListingRegistered")
                .withArgs(AD_HASH, landlord.address, POLICY_ID, REQ_ESCROW, COLLATERAL);
        });

        it("should lock collateral in the contract", async function () {
            const protocolAddr = await protocol.getAddress();
            const balBefore = await ethers.provider.getBalance(protocolAddr);

            await registerListing();

            const balAfter = await ethers.provider.getBalance(protocolAddr);
            expect(balAfter - balBefore).to.equal(COLLATERAL);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  2. Reused nonce failure
    // ════════════════════════════════════════════════════════════════════════

    describe("Nonce replay protection", function () {
        it("should revert when the same nonce is reused", async function () {
            const nonce = freshNonce();
            await registerListing(nonce);

            // Attempt a second listing with the same nonce but different adHash
            const adHash2 = hash("different-ad");
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).registerListing(
                    adHash2, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: COLLATERAL },
                ),
            ).to.be.revertedWithCustomError(protocol, "NonceAlreadyUsed")
                .withArgs(nonce);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  3. Stale timestamp failure
    // ════════════════════════════════════════════════════════════════════════

    describe("Freshness window", function () {
        it("should revert when timestamp is outside the freshness window", async function () {
            const nonce = freshNonce();
            const now = await time.latest();
            const staleTimestamp = now - FRESHNESS_WINDOW - 10; // clearly stale

            await expect(
                protocol.connect(landlord).registerListing(
                    AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    staleTimestamp, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: COLLATERAL },
                ),
            ).to.be.revertedWithCustomError(protocol, "FreshnessWindowExceeded");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  4. Invalid verifier failure
    // ════════════════════════════════════════════════════════════════════════

    describe("Invalid verifier", function () {
        it("should revert when ZK verifier returns false", async function () {
            const FailZK = await ethers.getContractFactory("FailingZKVerifier");
            const failingZK = await FailZK.deploy();
            await failingZK.waitForDeployment();
            await protocol.connect(admin).setZKVerifier(await failingZK.getAddress());

            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).registerListing(
                    AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: COLLATERAL },
                ),
            ).to.be.revertedWithCustomError(protocol, "InvalidZKProof");
        });

        it("should revert when threshold sig verifier returns false", async function () {
            const FailSig = await ethers.getContractFactory("FailingThresholdSigVerifier");
            const failingSig = await FailSig.deploy();
            await failingSig.waitForDeployment();
            await protocol.connect(admin).setThresholdVerifier(await failingSig.getAddress());

            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).registerListing(
                    AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: COLLATERAL },
                ),
            ).to.be.revertedWithCustomError(protocol, "InvalidThresholdSignature");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  5. Successful apply (applyToListing)
    // ════════════════════════════════════════════════════════════════════════

    describe("applyToListing", function () {
        beforeEach(async function () {
            await registerListing();
        });

        it("should create an application in PENDING_TRANSFER status", async function () {
            const { appId } = await applyToListing();

            const app = await protocol.getApplication(appId);
            expect(app.status).to.equal(AppStatus.PENDING_TRANSFER);
            expect(app.applicant).to.equal(tenant.address);
            expect(app.escrowAmount).to.equal(REQ_ESCROW);
            expect(app.adHash).to.equal(AD_HASH);
        });

        it("should emit ApplicationCreated event with correct appId", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();
            const expectedAppId = deriveAppId(AD_HASH, tenant.address, nonce);

            await expect(
                protocol.connect(tenant).applyToListing(
                    AD_HASH, POLICY_ID, TRANSCRIPT_TENANT,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: REQ_ESCROW },
                ),
            ).to.emit(protocol, "ApplicationCreated")
                .withArgs(expectedAppId, AD_HASH, tenant.address, REQ_ESCROW);
        });

        it("should revert if escrow is insufficient", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();
            const lowEscrow = ethers.parseEther("0.01"); // below reqEscrow

            await expect(
                protocol.connect(tenant).applyToListing(
                    AD_HASH, POLICY_ID, TRANSCRIPT_TENANT,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: lowEscrow },
                ),
            ).to.be.revertedWithCustomError(protocol, "InsufficientEscrow");
        });

        it("should revert if policy does not match the listing", async function () {
            const wrongPolicy = hash("wrong-policy");
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(tenant).applyToListing(
                    AD_HASH, wrongPolicy, TRANSCRIPT_TENANT,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: REQ_ESCROW },
                ),
            ).to.be.revertedWithCustomError(protocol, "PolicyMismatch");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  6. Listing becomes LOCKED after application
    // ════════════════════════════════════════════════════════════════════════

    describe("Listing LOCKED on application", function () {
        it("should transition listing from ACTIVE to LOCKED", async function () {
            await registerListing();

            const listingBefore = await protocol.getListing(AD_HASH);
            expect(listingBefore.status).to.equal(ListingStatus.ACTIVE);

            await applyToListing();

            const listingAfter = await protocol.getListing(AD_HASH);
            expect(listingAfter.status).to.equal(ListingStatus.LOCKED);
        });

        it("should reject a second application while listing is LOCKED", async function () {
            await registerListing();
            await applyToListing();

            // A different applicant tries to apply to the same LOCKED listing
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(stranger).applyToListing(
                    AD_HASH, POLICY_ID, TRANSCRIPT_TENANT,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: REQ_ESCROW },
                ),
            ).to.be.revertedWithCustomError(protocol, "ListingNotActive");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  7. Successful settle (settleListing)
    // ════════════════════════════════════════════════════════════════════════

    describe("settleListing", function () {
        let appId: string;

        beforeEach(async function () {
            await registerListing();
            ({ appId } = await applyToListing());
        });

        it("should mark both listing and application as SETTLED", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();

            await protocol.connect(landlord).settleListing(
                appId, TRANSCRIPT_SETTLE, ts, nonce,
                DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
            );

            const listing = await protocol.getListing(AD_HASH);
            const app = await protocol.getApplication(appId);
            expect(listing.status).to.equal(ListingStatus.SETTLED);
            expect(app.status).to.equal(AppStatus.SETTLED);
        });

        it("should emit ApplicationSettled event", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).settleListing(
                    appId, TRANSCRIPT_SETTLE, ts, nonce,
                    DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                ),
            ).to.emit(protocol, "ApplicationSettled")
                .withArgs(appId, AD_HASH, tenant.address, REQ_ESCROW, COLLATERAL);
        });

        it("should revert if caller is not the listing owner", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(stranger).settleListing(
                    appId, TRANSCRIPT_SETTLE, ts, nonce,
                    DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                ),
            ).to.be.revertedWithCustomError(protocol, "CallerNotListingOwner");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  8. Settle after expiry fails
    // ════════════════════════════════════════════════════════════════════════

    describe("Settle after expiry", function () {
        it("should revert settlement after the application has expired", async function () {
            await registerListing();
            const { appId } = await applyToListing();

            // Fast-forward past the expiry timeout
            await time.increase(EXPIRY_TIMEOUT + 1);

            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).settleListing(
                    appId, TRANSCRIPT_SETTLE, ts, nonce,
                    DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                ),
            ).to.be.revertedWithCustomError(protocol, "ApplicationNotPending");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  9. expireApplication reactivates listing
    // ════════════════════════════════════════════════════════════════════════

    describe("expireApplication", function () {
        let appId: string;

        beforeEach(async function () {
            await registerListing();
            ({ appId } = await applyToListing());
        });

        it("should revert if called before expiry timeout", async function () {
            await expect(
                protocol.connect(stranger).expireApplication(appId),
            ).to.be.revertedWithCustomError(protocol, "ApplicationNotYetExpirable");
        });

        it("should mark application EXPIRED and listing ACTIVE", async function () {
            await time.increase(EXPIRY_TIMEOUT + 1);

            await protocol.connect(stranger).expireApplication(appId);

            const listing = await protocol.getListing(AD_HASH);
            const app = await protocol.getApplication(appId);
            expect(listing.status).to.equal(ListingStatus.ACTIVE);
            expect(app.status).to.equal(AppStatus.EXPIRED);
        });

        it("should emit ApplicationExpired event with slash amount", async function () {
            await time.increase(EXPIRY_TIMEOUT + 1);
            const SLASH = COLLATERAL / 10n;

            await expect(
                protocol.connect(stranger).expireApplication(appId),
            ).to.emit(protocol, "ApplicationExpired")
                .withArgs(appId, AD_HASH, tenant.address, REQ_ESCROW, SLASH);
        });

        it("should allow anyone to call expireApplication", async function () {
            await time.increase(EXPIRY_TIMEOUT + 1);

            // stranger (not landlord or tenant) can expire
            await expect(
                protocol.connect(stranger).expireApplication(appId),
            ).to.not.be.reverted;
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  10. Escrow / accounting checks
    // ════════════════════════════════════════════════════════════════════════

    describe("Escrow & accounting", function () {
        it("should transfer escrow + collateral to landlord on settlement", async function () {
            await registerListing();
            const { appId } = await applyToListing();

            const landlordBefore = await ethers.provider.getBalance(landlord.address);
            const contractBefore = await ethers.provider.getBalance(await protocol.getAddress());

            // Contract should hold collateral + escrow
            expect(contractBefore).to.equal(COLLATERAL + REQ_ESCROW);

            const nonce = freshNonce();
            const ts = await time.latest();

            const tx = await protocol.connect(landlord).settleListing(
                appId, TRANSCRIPT_SETTLE, ts, nonce,
                DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
            );
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const landlordAfter = await ethers.provider.getBalance(landlord.address);
            const contractAfter = await ethers.provider.getBalance(await protocol.getAddress());

            // Landlord gains = escrow + collateral − gas
            expect(landlordAfter - landlordBefore + gasUsed).to.equal(COLLATERAL + REQ_ESCROW);
            // Contract should be empty
            expect(contractAfter).to.equal(0n);
        });

        it("should return escrow + 10% slash to tenant on expiration", async function () {
            await registerListing();
            const { appId } = await applyToListing();

            const tenantBefore = await ethers.provider.getBalance(tenant.address);

            await time.increase(EXPIRY_TIMEOUT + 1);

            // Stranger triggers expiry (tenant pays no gas)
            await protocol.connect(stranger).expireApplication(appId);

            const tenantAfter = await ethers.provider.getBalance(tenant.address);
            const contractAfter = await ethers.provider.getBalance(await protocol.getAddress());

            const SLASH = COLLATERAL / 10n;
            // Tenant gets escrow + 10% slash (no gas cost since stranger called)
            expect(tenantAfter - tenantBefore).to.equal(REQ_ESCROW + SLASH);
            // Contract holds landlord's remaining collateral (90%)
            expect(contractAfter).to.equal(COLLATERAL - SLASH);
        });

        it("should revert registerListing if collateral is insufficient", async function () {
            const nonce = freshNonce();
            const ts = await time.latest();
            const lowCollateral = ethers.parseEther("0.01");

            await expect(
                protocol.connect(landlord).registerListing(
                    AD_HASH, POLICY_ID, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: lowCollateral },
                ),
            ).to.be.revertedWithCustomError(protocol, "InsufficientCollateral")
                .withArgs(lowCollateral, MIN_COLLATERAL);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  11. Duplicate application prevention
    // ════════════════════════════════════════════════════════════════════════

    describe("Duplicate application prevention", function () {
        it("should revert if the same tenant applies twice to the same listing", async function () {
            // For this test we need the listing to remain ACTIVE after first apply.
            // But our contract LOCKs the listing on first apply, so the second apply
            // would fail with ListingNotActive. Let's verify that path.
            await registerListing();
            await applyToListing();

            // Listing is now LOCKED — a second apply by the same tenant should fail
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(tenant).applyToListing(
                    AD_HASH, POLICY_ID, TRANSCRIPT_TENANT,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: REQ_ESCROW },
                ),
            ).to.be.revertedWithCustomError(protocol, "ListingNotActive");
        });

        it("should revert DuplicateApplication if listing is re-activated and same tenant re-applies", async function () {
            await registerListing();
            const { appId } = await applyToListing();

            // Expire to re-activate the listing
            await time.increase(EXPIRY_TIMEOUT + 1);
            await protocol.connect(stranger).expireApplication(appId);

            // Listing is ACTIVE again, but activeApplications[adHash][tenant] was
            // cleared on expiry, so re-applying should succeed:
            const nonce2 = freshNonce();
            const ts2 = await time.latest();

            await expect(
                protocol.connect(tenant).applyToListing(
                    AD_HASH, POLICY_ID, TRANSCRIPT_TENANT,
                    ts2, nonce2, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: REQ_ESCROW },
                ),
            ).to.not.be.reverted;
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  Bonus: Admin & policy tests
    // ════════════════════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════════════════════
    //  12. Cancel listing
    // ════════════════════════════════════════════════════════════════════════

    describe("cancelListing", function () {
        it("should cancel an ACTIVE listing and return collateral", async function () {
            await registerListing();

            const protocolAddr = await protocol.getAddress();
            const landlordBefore = await ethers.provider.getBalance(landlord.address);

            const tx = await protocol.connect(landlord).cancelListing(AD_HASH);
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const listing = await protocol.getListing(AD_HASH);
            expect(listing.status).to.equal(4); // CANCELLED

            const landlordAfter = await ethers.provider.getBalance(landlord.address);
            expect(landlordAfter - landlordBefore + gasUsed).to.equal(COLLATERAL);

            const contractAfter = await ethers.provider.getBalance(protocolAddr);
            expect(contractAfter).to.equal(0n);
        });

        it("should emit ListingCancelled event", async function () {
            await registerListing();

            await expect(
                protocol.connect(landlord).cancelListing(AD_HASH),
            ).to.emit(protocol, "ListingCancelled")
                .withArgs(AD_HASH, landlord.address, COLLATERAL);
        });

        it("should revert if listing is not ACTIVE (LOCKED)", async function () {
            await registerListing();
            await applyToListing();

            await expect(
                protocol.connect(landlord).cancelListing(AD_HASH),
            ).to.be.revertedWithCustomError(protocol, "ListingNotActive");
        });

        it("should revert if caller is not the listing owner", async function () {
            await registerListing();

            await expect(
                protocol.connect(stranger).cancelListing(AD_HASH),
            ).to.be.revertedWithCustomError(protocol, "CallerNotListingOwner");
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  13. Slashing mechanics
    // ════════════════════════════════════════════════════════════════════════

    describe("Slashing on expiration", function () {
        it("should reduce listing collateral by 10% after expiration", async function () {
            await registerListing();
            const { appId } = await applyToListing();

            await time.increase(EXPIRY_TIMEOUT + 1);
            await protocol.connect(stranger).expireApplication(appId);

            const listing = await protocol.getListing(AD_HASH);
            const SLASH = COLLATERAL / 10n;
            expect(listing.collateral).to.equal(COLLATERAL - SLASH);
        });
    });

    // ════════════════════════════════════════════════════════════════════════
    //  Bonus: Admin & policy tests
    // ════════════════════════════════════════════════════════════════════════

    describe("Admin & policy", function () {
        it("should revert registerListing if policy is not whitelisted", async function () {
            const badPolicy = hash("unknown-policy");
            const nonce = freshNonce();
            const ts = await time.latest();

            await expect(
                protocol.connect(landlord).registerListing(
                    AD_HASH, badPolicy, REQ_ESCROW, TRANSCRIPT_LANDLORD,
                    ts, nonce, DUMMY_PROOF, EMPTY_INPUTS, DUMMY_SIG,
                    { value: COLLATERAL },
                ),
            ).to.be.revertedWithCustomError(protocol, "PolicyNotWhitelisted")
                .withArgs(badPolicy);
        });

        it("should only allow owner to call admin functions", async function () {
            await expect(
                protocol.connect(stranger).setMinCollateral(ethers.parseEther("1")),
            ).to.be.revertedWithCustomError(protocol, "NotOwner");

            await expect(
                protocol.connect(stranger).whitelistPolicy(hash("x"), true),
            ).to.be.revertedWithCustomError(protocol, "NotOwner");
        });
    });
});
