/**
 * PPREV Protocol — Deployment Script
 *
 * Deploys MockZKVerifier, ECDSANotaryVerifier, and PPREVSingle
 * to the local Hardhat network. Whitelists default policies and
 * saves deployed addresses for the frontend.
 */

import { ethers } from "hardhat";
import * as fs from "fs";

// Notary private key — Anvil/Hardhat account #9
const NOTARY_PRIVATE_KEY =
    "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

async function main() {
    const [deployer] = await ethers.getSigners();
    const notaryWallet = new ethers.Wallet(NOTARY_PRIVATE_KEY);

    console.log("═══════════════════════════════════════════════════════════════");
    console.log("  PPREV Protocol — Deployment");
    console.log("═══════════════════════════════════════════════════════════════");
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
    const freshnessWindow = 300;       // 5 minutes
    const expiryTimeout = 3600;        // 1 hour
    const minCollateral = ethers.parseEther("0.1");

    console.log("▸ Deploying PPREVSingle...");
    const PPREV = await ethers.getContractFactory("PPREVSingle");
    const protocol = await PPREV.deploy(
        zkAddr,
        sigAddr,
        freshnessWindow,
        expiryTimeout,
        minCollateral
    );
    await protocol.waitForDeployment();
    const protocolAddr = await protocol.getAddress();
    console.log(`  ✓ PPREVSingle deployed at: ${protocolAddr}`);

    // ── Whitelist policies ──
    console.log();
    console.log("▸ Whitelisting policies...");

    const policies: Record<string, string> = {};

    for (const key of ["rental-policy-v1", "OWN_RENT_V1", "OWN_SALE_V1"]) {
        const id = ethers.keccak256(ethers.toUtf8Bytes(key));
        await (protocol as any).whitelistPolicy(id, true);
        policies[key] = id;
        console.log(`  ✓ ${key} → ${id.slice(0, 18)}…`);
    }

    // ── Save deployed addresses for the frontend ──
    const addresses = {
        pprevSingle: protocolAddr,
        zkVerifier: zkAddr,
        sigVerifier: sigAddr,
        notaryAddress: notaryWallet.address,
        policies,
    };

    const outPath = "./frontend/deployed-addresses.json";
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
