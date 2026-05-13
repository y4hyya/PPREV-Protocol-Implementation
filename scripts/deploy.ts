/**
 * PPREV Protocol — Deployment Script
 *
 * Deploys ECDSANotaryVerifier and PPREVSingle to the local Hardhat/Anvil
 * network. Whitelists the six default phase policies (rental + sale × R/A/S),
 * verifies the deployment, and writes deployed-addresses.json for the frontend.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.ts --network localhost
 */

import { ethers } from "hardhat";
import * as fs from "fs";

const CONFIG = {
  freshnessWindow: 300, // 5 minutes — max age for submitted attestation timestamps (paper Δ)
  defaultLockWindow: 3600, // 1 hour — default τ_lock if engage() passes 0
  minCollateral: "0.1", // ETH — minimum collateral at registration
  policies: [
    "rental-ownership-v1",
    "rental-eligibility-v1",
    "rental-settlement-v1",
    "sale-ownership-v1",
    "sale-eligibility-v1",
    "sale-settlement-v1",
  ],
};

// Notary private key — Anvil/Hardhat account #9 (well-known test key)
const NOTARY_PRIVATE_KEY =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

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
  console.log(
    `  Balance:         ${ethers.formatEther(
      await ethers.provider.getBalance(deployer.address),
    )} ETH`,
  );
  console.log();

  // ── Deploy ECDSA Notary Verifier ──
  console.log("▸ Deploying ECDSANotaryVerifier...");
  const ECDSASig = await ethers.getContractFactory("ECDSANotaryVerifier");
  const verifier = await ECDSASig.deploy(notaryWallet.address);
  await verifier.waitForDeployment();
  const verifierAddr = await verifier.getAddress();
  console.log(`  ✓ ECDSANotaryVerifier deployed at: ${verifierAddr}`);

  // ── Deploy PPREVSingle ──
  const minCollateral = ethers.parseEther(CONFIG.minCollateral);

  console.log("▸ Deploying PPREVSingle...");
  const PPREV = await ethers.getContractFactory("PPREVSingle");
  const protocol = await PPREV.deploy(
    verifierAddr,
    CONFIG.freshnessWindow,
    CONFIG.defaultLockWindow,
    minCollateral,
  );
  await protocol.waitForDeployment();
  const protocolAddr = await protocol.getAddress();
  console.log(`  ✓ PPREVSingle deployed at: ${protocolAddr}`);

  // ── Verify deployment ──
  console.log();
  console.log("▸ Verifying deployment...");

  const verifiedAdmin = await (protocol as any).admin();
  const verifiedNotary = await (verifier as any).notaryAddress();
  const verifiedCollateral = await (protocol as any).minCollateral();

  let ok = true;
  if (verifiedAdmin !== deployer.address) {
    console.log(`  ✗ admin mismatch: expected ${deployer.address}, got ${verifiedAdmin}`);
    ok = false;
  }
  if (verifiedNotary !== notaryWallet.address) {
    console.log(`  ✗ notary mismatch`);
    ok = false;
  }
  if (verifiedCollateral !== minCollateral) {
    console.log(`  ✗ minCollateral mismatch`);
    ok = false;
  }

  if (ok) {
    console.log(`  ✓ admin() = ${deployer.address}`);
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
    console.log(`  ✓ ${key.padEnd(28)} → ${id.slice(0, 18)}…`);
  }

  // ── Save addresses for the frontend ──
  const addresses = {
    chainId: Number(network.chainId),
    network: network.name,
    deployedAt: new Date().toISOString(),
    pprevSingle: protocolAddr,
    notaryVerifier: verifierAddr,
    notaryAddress: notaryWallet.address,
    policies,
    config: {
      freshnessWindow: CONFIG.freshnessWindow,
      defaultLockWindow: CONFIG.defaultLockWindow,
      minCollateral: CONFIG.minCollateral,
    },
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

  return { verifier, protocol };
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
