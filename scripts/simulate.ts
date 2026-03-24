/**
 * ═══════════════════════════════════════════════════════════════════════════
 *  PPREV Protocol — Full-Flow Simulation Script
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *  This script runs the complete protocol lifecycle on Hardhat's built-in chain:
 *
 *    Step 1 — Deploy MockThresholdSignatureVerifier
 *    Step 2 — Deploy MockZKVerifier
 *    Step 3 — Deploy PPREVSingle
 *    Step 4 — Whitelist a sample policyId
 *    Step 5 — Landlord advertises a listing  (registerListing)
 *    Step 6 — Tenant applies for the listing (applyToListing)
 *    Step 7 — Landlord settles               (settleListing)
 *
 *  Prints listing/application statuses and ETH balances before & after each phase.
 */

import { ethers } from "hardhat";
import { Contract } from "ethers";

// ────────────────────────────────────────────────────────────────────────────
//  Console helpers
// ────────────────────────────────────────────────────────────────────────────

const LINE = "═".repeat(65);
const THIN = "─".repeat(65);

const LISTING_STATUS_NAMES = ["NONE", "ACTIVE", "LOCKED", "SETTLED", "CANCELLED"];
const APP_STATUS_NAMES = ["NONE", "PENDING_TRANSFER", "SETTLED", "EXPIRED"];

function banner(title: string) {
    console.log(`\n${LINE}`);
    console.log(`  ${title}`);
    console.log(LINE);
}

function section(title: string) {
    console.log(`\n  ${THIN}`);
    console.log(`  ${title}`);
    console.log(`  ${THIN}`);
}

function log(key: string, value: string) {
    console.log(`    ${key.padEnd(28)} ${value}`);
}

function listingStatusName(index: number | bigint): string {
    return LISTING_STATUS_NAMES[Number(index)] ?? `UNKNOWN(${index})`;
}

function appStatusName(index: number | bigint): string {
    return APP_STATUS_NAMES[Number(index)] ?? `UNKNOWN(${index})`;
}

async function getBalance(address: string): Promise<string> {
    const wei = await ethers.provider.getBalance(address);
    return ethers.formatEther(wei);
}

// ────────────────────────────────────────────────────────────────────────────
//  Dummy proof & signature constants  (mock verifiers always accept)
// ────────────────────────────────────────────────────────────────────────────

const DUMMY_ZK_PROOF = "0xdead";
const DUMMY_ZK_INPUTS: string[] = [];          // empty public inputs
const DUMMY_THRESHOLD_SIG = "0xbeef";

// ────────────────────────────────────────────────────────────────────────────
//  Main simulation
// ────────────────────────────────────────────────────────────────────────────

async function main() {
    // ── Signers ──
    const [admin, landlord, tenant] = await ethers.getSigners();

    banner("PPREV Protocol — Full-Flow Simulation");
    log("Admin (deployer)", admin.address);
    log("Landlord", landlord.address);
    log("Tenant", tenant.address);

    // ════════════════════════════════════════════════════════════════════════
    //  Step 1 — Deploy MockThresholdSignatureVerifier
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 1 — Deploy MockThresholdSignatureVerifier");

    const SigFactory = await ethers.getContractFactory("MockThresholdSignatureVerifier");
    const sigVerifier = await SigFactory.deploy();
    await sigVerifier.waitForDeployment();
    const sigAddr = await sigVerifier.getAddress();
    log("Deployed at", sigAddr);

    // ════════════════════════════════════════════════════════════════════════
    //  Step 2 — Deploy MockZKVerifier
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 2 — Deploy MockZKVerifier");

    const ZKFactory = await ethers.getContractFactory("MockZKVerifier");
    const zkVerifier = await ZKFactory.deploy();
    await zkVerifier.waitForDeployment();
    const zkAddr = await zkVerifier.getAddress();
    log("Deployed at", zkAddr);

    // ════════════════════════════════════════════════════════════════════════
    //  Step 3 — Deploy PPREVSingle
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 3 — Deploy PPREVSingle");

    const FRESHNESS_WINDOW = 300;            // 5 minutes
    const EXPIRY_TIMEOUT = 3600;           // 1 hour
    const MIN_COLLATERAL = ethers.parseEther("0.1");

    const PPREVFactory = await ethers.getContractFactory("PPREVSingle");
    const protocol = await PPREVFactory.deploy(
        zkAddr, sigAddr, FRESHNESS_WINDOW, EXPIRY_TIMEOUT, MIN_COLLATERAL,
    );
    await protocol.waitForDeployment();
    const protocolAddr = await protocol.getAddress();
    log("Deployed at", protocolAddr);
    log("Freshness window", `${FRESHNESS_WINDOW}s`);
    log("Expiry timeout", `${EXPIRY_TIMEOUT}s`);
    log("Min collateral", `${ethers.formatEther(MIN_COLLATERAL)} ETH`);

    // Cast to `any` once because ethers v6 `.connect()` drops typed methods
    const asAdmin = protocol.connect(admin) as any;
    const asLandlord = protocol.connect(landlord) as any;
    const asTenant = protocol.connect(tenant) as any;

    // ════════════════════════════════════════════════════════════════════════
    //  Step 4 — Whitelist a sample policyId
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 4 — Whitelist Policy");

    const policyId = ethers.keccak256(ethers.toUtf8Bytes("rental-policy-v1"));
    await asAdmin.whitelistPolicy(policyId, true);
    log("Policy ID", policyId);
    log("Whitelisted", "✓");

    // ════════════════════════════════════════════════════════════════════════
    //  Step 5 — Landlord advertises a listing (registerListing)
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 5 — Landlord Advertises Listing");

    const adHash = ethers.keccak256(ethers.toUtf8Bytes("2br-apartment-istanbul-2024"));
    const reqEscrow = ethers.parseEther("0.05");
    const transcriptListing = ethers.keccak256(ethers.toUtf8Bytes("landlord-credential-transcript"));
    const nonceListing = ethers.keccak256(ethers.toUtf8Bytes("nonce-landlord-listing-001"));
    const block1 = await ethers.provider.getBlock("latest");
    const timestampListing = block1!.timestamp;
    const collateral = ethers.parseEther("0.1");

    // ── Before ──
    section("Before registerListing");
    const listingBefore = await (protocol as any).getListing(adHash);
    log("Listing status", listingStatusName(listingBefore.status));
    log("Landlord balance", `${await getBalance(landlord.address)} ETH`);
    log("Contract balance", `${await getBalance(protocolAddr)} ETH`);

    // ── Execute ──
    const txReg = await asLandlord.registerListing(
        adHash,
        policyId,
        reqEscrow,
        transcriptListing,
        timestampListing,
        nonceListing,
        DUMMY_ZK_PROOF,
        DUMMY_ZK_INPUTS,
        DUMMY_THRESHOLD_SIG,
        { value: collateral },
    );
    await txReg.wait();

    // ── After ──
    section("After registerListing");
    const listingAfterReg = await (protocol as any).getListing(adHash);
    log("Listing status", listingStatusName(listingAfterReg.status));
    log("Listing owner", listingAfterReg.owner);
    log("Collateral locked", `${ethers.formatEther(listingAfterReg.collateral)} ETH`);
    log("Required escrow", `${ethers.formatEther(listingAfterReg.reqEscrow)} ETH`);
    log("Landlord balance", `${await getBalance(landlord.address)} ETH`);
    log("Contract balance", `${await getBalance(protocolAddr)} ETH`);

    // ════════════════════════════════════════════════════════════════════════
    //  Step 6 — Tenant applies for the listing (applyToListing)
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 6 — Tenant Applies for Listing");

    const transcriptTenant = ethers.keccak256(ethers.toUtf8Bytes("tenant-credential-transcript"));
    const nonceApply = ethers.keccak256(ethers.toUtf8Bytes("nonce-tenant-apply-001"));
    const block2 = await ethers.provider.getBlock("latest");
    const timestampApply = block2!.timestamp;

    // Derive appId off-chain (same formula as the contract)
    const appId = ethers.keccak256(
        ethers.solidityPacked(
            ["bytes32", "address", "bytes32"],
            [adHash, tenant.address, nonceApply],
        ),
    );

    // ── Before ──
    section("Before applyToListing");
    const listingBeforeApply = await (protocol as any).getListing(adHash);
    log("Listing status", listingStatusName(listingBeforeApply.status));
    log("Tenant balance", `${await getBalance(tenant.address)} ETH`);
    log("Contract balance", `${await getBalance(protocolAddr)} ETH`);

    // ── Execute ──
    const txApply = await asTenant.applyToListing(
        adHash,
        policyId,
        transcriptTenant,
        timestampApply,
        nonceApply,
        DUMMY_ZK_PROOF,
        DUMMY_ZK_INPUTS,
        DUMMY_THRESHOLD_SIG,
        { value: reqEscrow },
    );
    const rcApply = await txApply.wait();

    // ── After ──
    section("After applyToListing");
    const listingAfterApply = await (protocol as any).getListing(adHash);
    const appAfterApply = await (protocol as any).getApplication(appId);
    log("Listing status", listingStatusName(listingAfterApply.status));
    log("Application status", appStatusName(appAfterApply.status));
    log("Emitted appId", appId);
    log("Applicant", appAfterApply.applicant);
    log("Escrow locked", `${ethers.formatEther(appAfterApply.escrowAmount)} ETH`);
    log("Tenant balance", `${await getBalance(tenant.address)} ETH`);
    log("Contract balance", `${await getBalance(protocolAddr)} ETH`);

    // Also try to extract appId from the ApplicationCreated event log
    const appCreatedTopic = protocol.interface.getEvent("ApplicationCreated");
    if (appCreatedTopic && rcApply.logs) {
        for (const logEntry of rcApply.logs) {
            try {
                const parsed = protocol.interface.parseLog({
                    topics: logEntry.topics as string[],
                    data: logEntry.data,
                });
                if (parsed && parsed.name === "ApplicationCreated") {
                    log("Event appId", parsed.args[0]);
                    log("Event escrow", `${ethers.formatEther(parsed.args[3])} ETH`);
                }
            } catch { /* skip non-matching logs */ }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  Step 7 — Landlord settles (settleListing)
    // ════════════════════════════════════════════════════════════════════════

    banner("Step 7 — Landlord Settles");

    const transcriptSettle = ethers.keccak256(ethers.toUtf8Bytes("settlement-transcript"));
    const nonceSettle = ethers.keccak256(ethers.toUtf8Bytes("nonce-landlord-settle-001"));
    const block3 = await ethers.provider.getBlock("latest");
    const timestampSettle = block3!.timestamp;

    // ── Before ──
    section("Before settleListing");
    const listingBeforeSettle = await (protocol as any).getListing(adHash);
    const appBeforeSettle = await (protocol as any).getApplication(appId);
    log("Listing status", listingStatusName(listingBeforeSettle.status));
    log("Application status", appStatusName(appBeforeSettle.status));
    log("Landlord balance", `${await getBalance(landlord.address)} ETH`);
    log("Contract balance", `${await getBalance(protocolAddr)} ETH`);

    // ── Execute ──
    const txSettle = await asLandlord.settleListing(
        appId,
        transcriptSettle,
        timestampSettle,
        nonceSettle,
        DUMMY_ZK_PROOF,
        DUMMY_ZK_INPUTS,
        DUMMY_THRESHOLD_SIG,
    );
    await txSettle.wait();

    // ── After ──
    section("After settleListing");
    const listingAfterSettle = await (protocol as any).getListing(adHash);
    const appAfterSettle = await (protocol as any).getApplication(appId);
    log("Listing status", listingStatusName(listingAfterSettle.status));
    log("Application status", appStatusName(appAfterSettle.status));
    log("Landlord balance", `${await getBalance(landlord.address)} ETH`);
    log("Tenant balance", `${await getBalance(tenant.address)} ETH`);
    log("Contract balance", `${await getBalance(protocolAddr)} ETH`);

    // ════════════════════════════════════════════════════════════════════════
    //  Summary
    // ════════════════════════════════════════════════════════════════════════

    banner("✅  Simulation Complete — Summary");
    console.log();
    console.log("    Listing   : ACTIVE → LOCKED → SETTLED");
    console.log("    Application: (none) → PENDING_TRANSFER → SETTLED");
    console.log();
    console.log("    Funds flow:");
    console.log("      • Landlord deposited 0.1 ETH collateral");
    console.log("      • Tenant deposited 0.05 ETH escrow");
    console.log("      • On settlement, landlord received escrow + collateral back");
    console.log("      • Contract balance returned to 0 ETH");
    console.log();
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
