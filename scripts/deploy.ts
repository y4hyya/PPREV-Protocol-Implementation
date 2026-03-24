/**
 * PPREV Protocol — Deployment Script
 *
 * Deploys MockZKVerifier, MockThresholdSignatureVerifier, and PPREVSingle
 * to the local Hardhat network.
 */

import { ethers } from "hardhat";

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("═══════════════════════════════════════════════════════════════");
    console.log("  PPREV Protocol — Deployment");
    console.log("═══════════════════════════════════════════════════════════════");
    console.log(`  Deployer: ${deployer.address}`);
    console.log(`  Balance:  ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH`);
    console.log();

    // ── Deploy Mock Verifiers ──
    console.log("▸ Deploying MockZKVerifier...");
    const MockZK = await ethers.getContractFactory("MockZKVerifier");
    const zkVerifier = await MockZK.deploy();
    await zkVerifier.waitForDeployment();
    const zkAddr = await zkVerifier.getAddress();
    console.log(`  ✓ MockZKVerifier deployed at: ${zkAddr}`);

    console.log("▸ Deploying MockThresholdSignatureVerifier...");
    const MockSig = await ethers.getContractFactory("MockThresholdSignatureVerifier");
    const sigVerifier = await MockSig.deploy();
    await sigVerifier.waitForDeployment();
    const sigAddr = await sigVerifier.getAddress();
    console.log(`  ✓ MockThresholdSignatureVerifier deployed at: ${sigAddr}`);

    // ── Deploy PPREVSingle ──
    const freshnessWindow = 300;       // 5 minutes
    const expiryTimeout = 3600;      // 1 hour
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
