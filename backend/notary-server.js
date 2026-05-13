/**
 * ═══════════════════════════════════════════════════════════════════════════
 *  PPREV Notary Network Server
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *  Simulates the Notary Network described in the paper:
 *    1. The proving party (listing owner / applicant) makes a request after
 *       producing a TLSNotary session against the AuthRegistry.
 *    2. The notary mocks the predicate check by looking up the prover in a
 *       local registry mirror (registry-mock.json).
 *    3. On success the notary signs an ECDSA attestation (EIP-191) over the
 *       phase-specific public input x || addr_SC.
 *    4. The attestation is submitted on-chain; the contract verifies the
 *       signature against the notary's verification key.
 *
 *  Signed message layouts (must match PPREVSingle exactly):
 *    register : keccak256(txID || keccak256(txData) || policyId_R || nonce || ts || addr_SC)
 *    apply    : keccak256(txID                       || policyId_A || nonce || ts || addr_SC)
 *    settle   : keccak256(engId || txID              || policyId_S || nonce || ts || addr_SC)
 *
 *  Endpoints:
 *    GET  /notary/info                 → notary address, policy list, registry counts
 *    POST /notary/register-record      → register a new owner/applicant in the mock registry
 *    GET  /notary/record/:address      → look up identity (demo only)
 *    POST /notary/attest-register      → register-phase attestation
 *    POST /notary/attest-apply         → apply-phase attestation
 *    POST /notary/attest-settle        → settle-phase attestation
 * ═══════════════════════════════════════════════════════════════════════════
 */

const express = require("express");
const cors = require("cors");
const ethers = require("ethers");
const db = require("./registry-mock.json");

// Dynamic in-memory registry — survives until server restart.
const dynamicRegistry = { owners: {}, applicants: {} };

// Notary wallet — matches the address passed to PPREVSingle constructor.
// Anvil account index 9. Well-known test key; NOT a secret.
const NOTARY_PRIVATE_KEY =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";
const notaryWallet = new ethers.Wallet(NOTARY_PRIVATE_KEY);

const app = express();
const PORT = 3001;

app.use(cors());
app.use(express.json());

// ── Helpers ──────────────────────────────────────────────────────────────

function normalizeAddr(addr) {
  try {
    return ethers.getAddress(addr);
  } catch {
    return null;
  }
}

function reject(res, status, reason) {
  console.log(`  ✗ Rejected: ${reason}`);
  return res.status(status).json({ error: reason });
}

async function signAttestation(msgHash) {
  return notaryWallet.signMessage(ethers.getBytes(msgHash));
}

function resolveOwner(addr) {
  return dynamicRegistry.owners[addr] || db.owners[addr] || null;
}

function resolveApplicant(addr) {
  return dynamicRegistry.applicants[addr] || db.applicants[addr] || null;
}

function policyByID(policyId) {
  for (const key of Object.keys(db.whitelistedPolicies)) {
    if (ethers.keccak256(ethers.toUtf8Bytes(key)) === policyId) {
      return { key, def: db.whitelistedPolicies[key] };
    }
  }
  return null;
}

function computeTxId(txData, policyIdR, salt) {
  // C_tx = keccak256(txData || policyId_R || salt)
  return ethers.solidityPackedKeccak256(
    ["bytes", "bytes32", "bytes32"],
    [txData, policyIdR, salt],
  );
}

function buildMsgR(txID, txDataHash, policyIdR, nonce, ts, contractAddr) {
  return ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "address"],
    [txID, txDataHash, policyIdR, nonce, BigInt(ts), contractAddr],
  );
}

function buildMsgA(txID, policyIdA, nonce, ts, contractAddr) {
  return ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "uint256", "address"],
    [txID, policyIdA, nonce, BigInt(ts), contractAddr],
  );
}

function buildMsgS(engId, txID, policyIdS, nonce, ts, contractAddr) {
  return ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "address"],
    [engId, txID, policyIdS, nonce, BigInt(ts), contractAddr],
  );
}

// ── Route: info ──────────────────────────────────────────────────────────

app.get("/notary/info", (_req, res) => {
  res.json({
    notaryAddress: notaryWallet.address,
    description:
      "PPREV Notary Network — mock AuthRegistry attestation server",
    policies: Object.keys(db.whitelistedPolicies),
    owners:
      Object.keys(db.owners).length +
      Object.keys(dynamicRegistry.owners).length,
    applicants:
      Object.keys(db.applicants).length +
      Object.keys(dynamicRegistry.applicants).length,
  });
});

// ── Route: dynamic record registration ───────────────────────────────────

app.post("/notary/register-record", (req, res) => {
  const {
    address,
    role,
    name,
    registryId,
    properties,
    monthlyIncome,
    creditScore,
  } = req.body;

  const addr = normalizeAddr(address);
  if (!addr) return reject(res, 400, "Invalid address");
  if (!role || !name || !registryId)
    return reject(res, 400, "Missing required fields: role, name, registryId");
  if (role !== "owner" && role !== "applicant")
    return reject(res, 400, "Role must be 'owner' or 'applicant'");

  if (resolveOwner(addr) || resolveApplicant(addr))
    return reject(res, 409, "Address already registered in AuthRegistry");

  if (role === "owner") {
    if (!properties || !Array.isArray(properties) || properties.length === 0)
      return reject(res, 400, "Owner must provide at least one property");
    for (const p of properties) {
      if (!p.deedId || !p.address || !p.kind || !p.areaSqm)
        return reject(
          res,
          400,
          "Each property must have deedId, address, kind, areaSqm",
        );
      if (!["rental", "sale"].includes(p.kind))
        return reject(res, 400, "Property kind must be 'rental' or 'sale'");
      if (isNaN(p.areaSqm) || p.areaSqm <= 0)
        return reject(res, 400, "areaSqm must be a positive number");
    }
    dynamicRegistry.owners[addr] = {
      name,
      registryId,
      verified: true,
      properties: properties.map((p) => ({
        deedId: p.deedId,
        address: p.address,
        kind: p.kind,
        areaSqm: Number(p.areaSqm),
      })),
    };
    console.log(
      `\n[register-record] Owner: ${name} (${addr}) — ${properties.length} property/properties`,
    );
    return res.json({ success: true, role: "owner", record: dynamicRegistry.owners[addr] });
  }

  // applicant
  const income = Number(monthlyIncome);
  const credit = Number(creditScore);
  if (isNaN(income) || income < 0)
    return reject(res, 400, "monthlyIncome must be a non-negative number");
  if (isNaN(credit) || credit < 0 || credit > 1900)
    return reject(res, 400, "creditScore must be 0–1900");

  dynamicRegistry.applicants[addr] = {
    name,
    registryId,
    verified: true,
    monthlyIncome: income,
    creditScore: credit,
  };
  console.log(
    `\n[register-record] Applicant: ${name} (${addr}) — income ${income}, credit ${credit}`,
  );
  return res.json({ success: true, role: "applicant", record: dynamicRegistry.applicants[addr] });
});

// ── Route: lookup (demo) ──────────────────────────────────────────────────

app.get("/notary/record/:address", (req, res) => {
  const addr = normalizeAddr(req.params.address);
  if (!addr) return reject(res, 400, "Invalid address");

  const owner = resolveOwner(addr);
  const applicant = resolveApplicant(addr);

  if (owner) return res.json({ role: "owner", record: owner });
  if (applicant) return res.json({ role: "applicant", record: applicant });
  return res.json({ role: "unknown", record: null });
});

// ── Route: attest-register ────────────────────────────────────────────────

app.post("/notary/attest-register", async (req, res) => {
  const {
    proverAddress,
    txData,
    policyIdR,
    policyIdA,
    policyIdS,
    salt,
    nonce,
    timestamp,
    contractAddress,
  } = req.body;

  console.log(`\n[attest-register] ${proverAddress}`);

  const addr = normalizeAddr(proverAddress);
  const sc = normalizeAddr(contractAddress);
  if (!addr) return reject(res, 400, "Invalid proverAddress");
  if (!sc) return reject(res, 400, "Invalid contractAddress");
  if (!txData || !policyIdR || !policyIdA || !policyIdS || !salt || !nonce || !timestamp)
    return reject(res, 400, "Missing required fields");

  // AuthRegistry predicate check
  const record = resolveOwner(addr);
  if (!record || !record.verified)
    return reject(
      res,
      403,
      `Address ${addr} is not a verified property owner in the AuthRegistry.`,
    );
  if (!record.properties || record.properties.length === 0)
    return reject(res, 403, "No registered properties for this address.");

  // Policy check: registration policy must be whitelisted in the registry mirror
  const polR = policyByID(policyIdR);
  if (!polR) return reject(res, 400, `Unknown policyId_R: ${policyIdR}`);
  if (polR.def.phase !== "R")
    return reject(res, 400, `policyId_R points to a non-R policy (phase=${polR.def.phase})`);

  console.log(
    `  ✓ Owner verified: ${record.name} (${record.properties.length} property/properties)`,
  );

  // Compute txID = C_tx
  let txID, txDataHash, msgHash;
  try {
    txID = computeTxId(txData, policyIdR, salt);
    txDataHash = ethers.keccak256(txData);
    msgHash = buildMsgR(txID, txDataHash, policyIdR, nonce, timestamp, sc);
  } catch (err) {
    return reject(res, 400, `Bad encoding: ${err.shortMessage || err.message}`);
  }

  const signature = await signAttestation(msgHash);
  console.log(`  ✓ σ_R signed: ${signature.slice(0, 20)}...`);

  res.json({
    signature,
    txID,
    txDataHash,
    notaryAddress: notaryWallet.address,
    attestedFields: { txID, policyIdR, policyIdA, policyIdS, nonce, timestamp, contractAddress: sc },
  });
});

// ── Route: attest-apply ───────────────────────────────────────────────────

app.post("/notary/attest-apply", async (req, res) => {
  const { applicantAddress, txID, policyIdA, nonce, timestamp, contractAddress } = req.body;

  console.log(`\n[attest-apply] ${applicantAddress}`);

  const addr = normalizeAddr(applicantAddress);
  const sc = normalizeAddr(contractAddress);
  if (!addr) return reject(res, 400, "Invalid applicantAddress");
  if (!sc) return reject(res, 400, "Invalid contractAddress");
  if (!txID || !policyIdA || !nonce || !timestamp)
    return reject(res, 400, "Missing required fields");

  const record = resolveApplicant(addr);
  if (!record || !record.verified)
    return reject(
      res,
      403,
      `Address ${addr} is not a verified applicant in the AuthRegistry.`,
    );

  const polA = policyByID(policyIdA);
  if (!polA) return reject(res, 400, `Unknown policyId_A: ${policyIdA}`);
  if (polA.def.phase !== "A")
    return reject(res, 400, `policyId_A points to a non-A policy (phase=${polA.def.phase})`);

  if (
    typeof polA.def.minMonthlyIncome === "number" &&
    record.monthlyIncome < polA.def.minMonthlyIncome
  ) {
    return reject(
      res,
      403,
      `Monthly income ${record.monthlyIncome} below threshold ${polA.def.minMonthlyIncome} for policy ${polA.key}`,
    );
  }
  if (
    typeof polA.def.minCreditScore === "number" &&
    record.creditScore < polA.def.minCreditScore
  ) {
    return reject(
      res,
      403,
      `Credit score ${record.creditScore} below threshold ${polA.def.minCreditScore} for policy ${polA.key}`,
    );
  }

  console.log(
    `  ✓ Applicant verified: ${record.name} (income: ${record.monthlyIncome}, credit: ${record.creditScore})`,
  );

  let msgHash;
  try {
    msgHash = buildMsgA(txID, policyIdA, nonce, timestamp, sc);
  } catch (err) {
    return reject(res, 400, `Bad encoding: ${err.shortMessage || err.message}`);
  }

  const signature = await signAttestation(msgHash);
  console.log(`  ✓ σ_A signed: ${signature.slice(0, 20)}...`);

  res.json({
    signature,
    notaryAddress: notaryWallet.address,
    attestedFields: { txID, policyIdA, nonce, timestamp, contractAddress: sc },
  });
});

// ── Route: attest-settle ──────────────────────────────────────────────────

app.post("/notary/attest-settle", async (req, res) => {
  const { proverAddress, engId, txID, policyIdS, nonce, timestamp, contractAddress } = req.body;

  console.log(`\n[attest-settle] eng=${engId?.slice(0, 12)}... prover=${proverAddress}`);

  const addr = normalizeAddr(proverAddress);
  const sc = normalizeAddr(contractAddress);
  if (!addr) return reject(res, 400, "Invalid proverAddress");
  if (!sc) return reject(res, 400, "Invalid contractAddress");
  if (!engId || !txID || !policyIdS || !nonce || !timestamp)
    return reject(res, 400, "Missing required fields");

  const record = resolveOwner(addr);
  if (!record) return reject(res, 403, `Address ${addr} is not a verified owner.`);

  const polS = policyByID(policyIdS);
  if (!polS) return reject(res, 400, `Unknown policyId_S: ${policyIdS}`);
  if (polS.def.phase !== "S")
    return reject(res, 400, `policyId_S points to a non-S policy (phase=${polS.def.phase})`);

  console.log(`  ✓ Settlement requested by: ${record.name}`);

  let msgHash;
  try {
    msgHash = buildMsgS(engId, txID, policyIdS, nonce, timestamp, sc);
  } catch (err) {
    return reject(res, 400, `Bad encoding: ${err.shortMessage || err.message}`);
  }

  const signature = await signAttestation(msgHash);
  console.log(`  ✓ σ_S signed: ${signature.slice(0, 20)}...`);

  res.json({
    signature,
    notaryAddress: notaryWallet.address,
    attestedFields: { engId, txID, policyIdS, nonce, timestamp, contractAddress: sc },
  });
});

// ── Start ─────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("  PPREV Notary Network Server");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log(`  Port          : ${PORT}`);
  console.log(`  Notary address: ${notaryWallet.address}`);
  console.log(`  Owners        : ${Object.keys(db.owners).length} in AuthRegistry mirror`);
  console.log(`  Applicants    : ${Object.keys(db.applicants).length} in AuthRegistry mirror`);
  console.log(`  Policies      : ${Object.keys(db.whitelistedPolicies).length}`);
  console.log("═══════════════════════════════════════════════════════════════");
});
