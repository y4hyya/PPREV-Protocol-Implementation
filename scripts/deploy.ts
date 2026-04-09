/**
 * PPREV Protocol — Deployment Script
 *
 * Deploys MockZKVerifier, ECDSANotaryVerifier, and PPREVSingle
 * to the local Hardhat/Anvil network. Whitelists default policies,
 * verifies deployment, and saves addresses for the frontend.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.ts --network localhost
 */

import { ethers } from "hardhat";
import * as fs from "fs";

// ── Deployment Configuration ─────────────────────────────────────────────
const CONFIG = {
    freshnessWindow: 300,       // 5 minutes — max age for submitted timestamps
    expiryTimeout: 3600,        // 1 hour — before an application becomes expirable
    minCollateral: "0.1",       // ETH — minimum collateral for listing registration
    policies: ["rental-policy-v1", "OWN_RENT_V1", "OWN_SALE_V1"],
};

// Notary private key — Anvil/Hardhat account #9
const NOTARY_PRIVATE_KEY =
    "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

// ── Main ─────────────────────────────────────────────────────────────────
async function main() {
    const [deployer] = await ethers.getSigners();
    const notaryWallet = new ethers.Wallet(NOTARY_PRIVATE_KEY);
    const network = await ethers.provider.getNetwork();

    console.log("═══════════════════════════════════════════════════════════════");
    console.log("  PPREV Protocol — Deployment");
    console.log("═══════════════════════════════════════════════════════════════");
    console.log(`  Network:         ${network.name} (chainId: ${network.chainId})`);
    console.log(`  Deployer:        ${deployer.address}`);
    console.log(`  Notary address:  ${notaryWallet.address}`);
    console.log(`  Balance:         ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH`);
    console.log();

    // ── Deploy Mock ZK Verifier ──
    console.log("▸ Deploying MockZKVerifier...");
    const MockZK = await ethers.getContractFactory("MockZKVerifier");
    const zkVerifier = await MockZK.deploy();
    await zkVerifier.waitForDeployment();
    const zkAddr = await zkVerifier.getAddress();
    console.log(`  ✓ MockZKVerifier deployed at: ${zkAddr}`);

    // ── Deploy ECDSA Notary Verifier ──
    console.log("▸ Deploying ECDSANotaryVerifier...");
    const ECDSASig = await ethers.getContractFactory("ECDSANotaryVerifier");
    const sigVerifier = await ECDSASig.deploy(notaryWallet.address);
    await sigVerifier.waitForDeployment();
    const sigAddr = await sigVerifier.getAddress();
    console.log(`  ✓ ECDSANotaryVerifier deployed at: ${sigAddr}`);

    // ── Deploy PPREVSingle ──
    const minCollateral = ethers.parseEther(CONFIG.minCollateral);

    console.log("▸ Deploying PPREVSingle...");
    const PPREV = await ethers.getContractFactory("PPREVSingle");
    const protocol = await PPREV.deploy(
        zkAddr,
        sigAddr,
        CONFIG.freshnessWindow,
        CONFIG.expiryTimeout,
        minCollateral
    );
    await protocol.waitForDeployment();
    const protocolAddr = await protocol.getAddress();
    console.log(`  ✓ PPREVSingle deployed at: ${protocolAddr}`);

    // ── Verify deployment ──
    console.log();
    console.log("▸ Verifying deployment...");

    const verifiedOwner = await (protocol as any).owner();
    const verifiedNotary = await (sigVerifier as any).notaryAddress();
    const verifiedCollateral = await (protocol as any).minCollateral();

    let verified = true;
    if (verifiedOwner !== deployer.address) {
        console.log(`  ✗ Owner mismatch: expected ${deployer.address}, got ${verifiedOwner}`);
        verified = false;
    }
    if (verifiedNotary !== notaryWallet.address) {
        console.log(`  ✗ Notary mismatch: expected ${notaryWallet.address}, got ${verifiedNotary}`);
        verified = false;
    }
    if (verifiedCollateral !== minCollateral) {
        console.log(`  ✗ MinCollateral mismatch`);
        verified = false;
    }

    if (verified) {
        console.log(`  ✓ owner() = ${deployer.address}`);
        console.log(`  ✓ notaryAddress() = ${notaryWallet.address}`);
        console.log(`  ✓ minCollateral() = ${CONFIG.minCollateral} ETH`);
    } else {
        console.error("\n  ✗ DEPLOYMENT VERIFICATION FAILED — do not use these addresses");
        process.exitCode = 1;
        return;
    }

    // ── Whitelist policies ──
    console.log();
    console.log("▸ Whitelisting policies...");

    const policies: Record<string, string> = {};

    for (const key of CONFIG.policies) {
        const id = ethers.keccak256(ethers.toUtf8Bytes(key));
        await (protocol as any).whitelistPolicy(id, true);
        policies[key] = id;
        console.log(`  ✓ ${key} → ${id.slice(0, 18)}…`);
    }

    // ── Save deployed addresses for the frontend ──
    const addresses = {
        chainId: Number(network.chainId),
        network: network.name,
        deployedAt: new Date().toISOString(),
        pprevSingle: protocolAddr,
        zkVerifier: zkAddr,
        sigVerifier: sigAddr,
        notaryAddress: notaryWallet.address,
        policies,
    };

    const outDir = "./frontend";
    const outPath = `${outDir}/deployed-addresses.json`;
    fs.mkdirSync(outDir, { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(addresses, null, 2));
    console.log(`\n  ✓ Addresses saved to ${outPath}`);

    console.log();
    console.log("═══════════════════════════════════════════════════════════════");
    console.log("  Deployment complete!");
    console.log("═══════════════════════════════════════════════════════════════");

    return { zkVerifier, sigVerifier, protocol };
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
