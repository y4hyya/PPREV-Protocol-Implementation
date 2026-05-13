/**
 * ═══════════════════════════════════════════════════════════════════════════
 *  PPREV Protocol — Full-Flow Simulation Script
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *  Runs the complete protocol lifecycle on Hardhat's built-in chain with real
 *  ECDSA notary signatures (no on-chain ZK verification; the paper's design
 *  has the notary verify the ZK proof off-chain).
 *
 *    Step 1 — Deploy ECDSANotaryVerifier
 *    Step 2 — Deploy PPREVSingle
 *    Step 3 — Whitelist three policy IDs (policyId_R, policyId_A, policyId_S)
 *    Step 4 — Prover registers a transaction (register)
 *    Step 5 — Counterparty applies (applyTx)
 *    Step 6 — Listing owner engages the application (engage)
 *    Step 7 — Listing owner settles (settle)
 */

import { ethers } from "hardhat";
import { Wallet } from "ethers";

// Notary wallet — Anvil/Hardhat account #9 (well-known test key, not a secret)
const NOTARY_PRIVATE_KEY =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

const LINE = "═".repeat(65);
const THIN = "─".repeat(65);

const TX_STATE_NAMES = ["NONE", "ACTIVE", "LOCKED", "SETTLED", "CANCELLED"];
const APP_STATUS_NAMES = ["NONE", "PENDING", "ENGAGED", "EXPIRED", "CANCELLED"];
const ENG_STATUS_NAMES = ["NONE", "ACTIVE", "SETTLED", "EXPIRED"];

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

const txStateName = (i: number | bigint) => TX_STATE_NAMES[Number(i)] ?? `?(${i})`;
const appStatusName = (i: number | bigint) => APP_STATUS_NAMES[Number(i)] ?? `?(${i})`;
const engStatusName = (i: number | bigint) => ENG_STATUS_NAMES[Number(i)] ?? `?(${i})`;

async function balanceEth(address: string): Promise<string> {
  const wei = await ethers.provider.getBalance(address);
  return ethers.formatEther(wei);
}

const notaryWallet = new Wallet(NOTARY_PRIVATE_KEY);

async function signNotary(msgHash: string): Promise<string> {
  return notaryWallet.signMessage(ethers.getBytes(msgHash));
}

async function nowTs(): Promise<bigint> {
  const block = await ethers.provider.getBlock("latest");
  return BigInt(block!.timestamp);
}

// ────────────────────────────────────────────────────────────────────────────
//  Main
// ────────────────────────────────────────────────────────────────────────────

async function main() {
  const [admin, lister, counterparty] = await ethers.getSigners();

  banner("PPREV Protocol — Full-Flow Simulation (Real ECDSA Notary)");
  log("Admin (deployer)", admin.address);
  log("Lister (prover)", lister.address);
  log("Counterparty", counterparty.address);
  log("Notary", notaryWallet.address);

  // ── Step 1 — Deploy ECDSANotaryVerifier ──────────────────────────────
  banner("Step 1 — Deploy ECDSANotaryVerifier");
  const VerifierFactory = await ethers.getContractFactory("ECDSANotaryVerifier");
  const verifier = await VerifierFactory.deploy(notaryWallet.address);
  await verifier.waitForDeployment();
  const verifierAddr = await verifier.getAddress();
  log("Deployed at", verifierAddr);

  // ── Step 2 — Deploy PPREVSingle ──────────────────────────────────────
  banner("Step 2 — Deploy PPREVSingle");
  const FRESHNESS = 300; // 5 min
  const DEFAULT_LOCK = 3600; // 1 hour
  const MIN_COLLATERAL = ethers.parseEther("0.1");

  const PPREVFactory = await ethers.getContractFactory("PPREVSingle");
  const protocol = await PPREVFactory.deploy(
    verifierAddr,
    FRESHNESS,
    DEFAULT_LOCK,
    MIN_COLLATERAL,
  );
  await protocol.waitForDeployment();
  const protocolAddr = await protocol.getAddress();
  log("Deployed at", protocolAddr);
  log("Freshness window", `${FRESHNESS}s`);
  log("Default lock window", `${DEFAULT_LOCK}s`);
  log("Min collateral", `${ethers.formatEther(MIN_COLLATERAL)} ETH`);

  const asAdmin = protocol.connect(admin) as any;
  const asLister = protocol.connect(lister) as any;
  const asCounterparty = protocol.connect(counterparty) as any;

  // ── Step 3 — Whitelist three policy IDs ──────────────────────────────
  banner("Step 3 — Whitelist Policies (R / A / S)");
  const policyIdR = ethers.keccak256(ethers.toUtf8Bytes("rental-ownership-v1"));
  const policyIdA = ethers.keccak256(ethers.toUtf8Bytes("rental-eligibility-v1"));
  const policyIdS = ethers.keccak256(ethers.toUtf8Bytes("rental-settlement-v1"));
  await asAdmin.whitelistPolicy(policyIdR, true);
  await asAdmin.whitelistPolicy(policyIdA, true);
  await asAdmin.whitelistPolicy(policyIdS, true);
  log("policyId_R", policyIdR);
  log("policyId_A", policyIdA);
  log("policyId_S", policyIdS);

  // ── Step 4 — Register a transaction (Phase 1 / phi_R) ────────────────
  banner("Step 4 — Register Transaction");

  // Public transaction parameters (txData) — abi-encode a representative payload
  const txData = ethers.AbiCoder.defaultAbiCoder().encode(
    ["string", "string", "uint256", "uint256"],
    ["rental", "PROPERTY-IST-2026-001", 1500, 12],
  );
  const salt = ethers.keccak256(ethers.toUtf8Bytes("salt-listing-001"));
  const nonceR = ethers.keccak256(ethers.toUtf8Bytes("nonce-register-001"));
  const reqEscrow = ethers.parseEther("0.05");
  const collateral = ethers.parseEther("0.1");

  // txID == C_tx = keccak256(txData || policyId_R || salt)
  const txID = ethers.solidityPackedKeccak256(
    ["bytes", "bytes32", "bytes32"],
    [txData, policyIdR, salt],
  );
  const txDataHash = ethers.keccak256(txData);
  const tsR = await nowTs();

  // x_R = (C_tx, H(txData), policyId_R, eta_R, t_auth_R); sigma_R signs x_R || addr_SC
  const msgR = ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "address"],
    [txID, txDataHash, policyIdR, nonceR, tsR, protocolAddr],
  );
  const sigmaR = await signNotary(msgR);
  log("Notary σ_R", sigmaR.slice(0, 20) + "…");
  log("txID (C_tx)", txID);

  section("Before register");
  log("Lister balance", `${await balanceEth(lister.address)} ETH`);
  log("Contract balance", `${await balanceEth(protocolAddr)} ETH`);

  const txReg = await asLister.register(
    txData,
    policyIdR,
    policyIdA,
    policyIdS,
    salt,
    reqEscrow,
    nonceR,
    tsR,
    sigmaR,
    { value: collateral },
  );
  await txReg.wait();

  section("After register");
  const l1 = await asAdmin.getListing(txID);
  log("Listing state", txStateName(l1.state));
  log("Listing owner", l1.owner);
  log("Collateral", `${ethers.formatEther(l1.collateral)} ETH`);
  log("Required escrow", `${ethers.formatEther(l1.reqEscrow)} ETH`);
  log("Lister balance", `${await balanceEth(lister.address)} ETH`);
  log("Contract balance", `${await balanceEth(protocolAddr)} ETH`);

  // ── Step 5 — Counterparty applies (Phase 2 / phi_A) ──────────────────
  banner("Step 5 — Counterparty Applies");
  const nonceA = ethers.keccak256(ethers.toUtf8Bytes("nonce-apply-001"));
  const tsA = await nowTs();

  // x_A = (txID, policyId_A, eta_A, t_auth_A); sigma_A signs x_A || addr_SC
  const msgA = ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "uint256", "address"],
    [txID, policyIdA, nonceA, tsA, protocolAddr],
  );
  const sigmaA = await signNotary(msgA);
  log("Notary σ_A", sigmaA.slice(0, 20) + "…");

  // Predict appId (mirrors contract derivation)
  const appId = ethers.solidityPackedKeccak256(
    ["bytes32", "address", "bytes32"],
    [txID, counterparty.address, nonceA],
  );

  section("Before applyTx");
  log("Counterparty balance", `${await balanceEth(counterparty.address)} ETH`);
  log("Contract balance", `${await balanceEth(protocolAddr)} ETH`);

  const txApply = await asCounterparty.applyTx(txID, nonceA, tsA, sigmaA, {
    value: reqEscrow,
  });
  await txApply.wait();

  section("After applyTx");
  const app1 = await asAdmin.getApplication(appId);
  const l2 = await asAdmin.getListing(txID);
  log("Application status", appStatusName(app1.status));
  log("Listing state", txStateName(l2.state));
  log("appId", appId);
  log("Applicant", app1.applicant);
  log("Escrow", `${ethers.formatEther(app1.escrow)} ETH`);
  log("Counterparty balance", `${await balanceEth(counterparty.address)} ETH`);
  log("Contract balance", `${await balanceEth(protocolAddr)} ETH`);

  // ── Step 6 — Listing owner engages (Phase 2 engagement) ──────────────
  banner("Step 6 — Listing Owner Engages");
  const txEngage = await asLister.engage(appId, 0); // 0 = use default lock window
  const rcEngage = await txEngage.wait();

  // Extract engId from the Engaged event (engId = engagement identifier)
  let engId = "0x";
  for (const logEntry of rcEngage.logs) {
    try {
      const parsed = protocol.interface.parseLog({
        topics: logEntry.topics as string[],
        data: logEntry.data,
      });
      if (parsed && parsed.name === "Engaged") {
        engId = parsed.args[0] as string;
        break;
      }
    } catch {
      /* skip non-matching logs */
    }
  }

  section("After engage");
  const eng1 = await asAdmin.getEngagement(engId);
  const l3 = await asAdmin.getListing(txID);
  const app2 = await asAdmin.getApplication(appId);
  log("Engagement status", engStatusName(eng1.status));
  log("Listing state", txStateName(l3.state));
  log("Application status", appStatusName(app2.status));
  log("engId", engId);
  log("expiresAt", `${eng1.expiresAt} (in ${Number(eng1.expiresAt) - Number(await nowTs())}s)`);

  // ── Step 7 — Listing owner settles (Phase 3 / phi_S) ─────────────────
  banner("Step 7 — Listing Owner Settles");
  const nonceS = ethers.keccak256(ethers.toUtf8Bytes("nonce-settle-001"));
  const tsS = await nowTs();

  // x_S = (engId, txID, policyId_S, eta_S, t_auth_S); sigma_S signs x_S || addr_SC
  const msgS = ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "address"],
    [engId, txID, policyIdS, nonceS, tsS, protocolAddr],
  );
  const sigmaS = await signNotary(msgS);
  log("Notary σ_S", sigmaS.slice(0, 20) + "…");

  section("Before settle");
  log("Lister balance", `${await balanceEth(lister.address)} ETH`);
  log("Counterparty balance", `${await balanceEth(counterparty.address)} ETH`);
  log("Contract balance", `${await balanceEth(protocolAddr)} ETH`);

  const txSettle = await asLister.settle(engId, nonceS, tsS, sigmaS);
  await txSettle.wait();

  section("After settle");
  const l4 = await asAdmin.getListing(txID);
  const eng2 = await asAdmin.getEngagement(engId);
  log("Listing state", txStateName(l4.state));
  log("Engagement status", engStatusName(eng2.status));
  log("Lister balance", `${await balanceEth(lister.address)} ETH`);
  log("Counterparty balance", `${await balanceEth(counterparty.address)} ETH`);
  log("Contract balance", `${await balanceEth(protocolAddr)} ETH`);

  // ── Summary ──────────────────────────────────────────────────────────
  banner("✅  Simulation Complete — Summary");
  console.log();
  console.log("    Listing      : ACTIVE → LOCKED → SETTLED");
  console.log("    Application  : (none) → PENDING → ENGAGED");
  console.log("    Engagement   : (none) → ACTIVE → SETTLED");
  console.log();
  console.log("    Notary signatures: σ_R, σ_A, σ_S (real ECDSA, ecrecover on-chain)");
  console.log("    ZK proofs are verified off-chain by the notary (not on-chain).");
  console.log();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
