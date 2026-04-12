/**
 * ═══════════════════════════════════════════════════════════════════════════
 *  PPREV Protocol — Notary Network Server
 * ═══════════════════════════════════════════════════════════════════════════
 *
 *  Simulates the Notary Network described in the paper:
 *    1. Landlord/tenant present their E-Devlet data
 *    2. The Notary verifies the data against the mock E-Devlet database
 *    3. If valid, signs an ECDSA attestation (EIP-191)
 *    4. The attestation is submitted on-chain; the contract verifies the sig
 *
 *  The notary private key corresponds to the address deployed as
 *  `notaryAddress` in PPREVSingle.  If the notary refuses to sign
 *  (invalid landlord/tenant), the on-chain transaction CANNOT succeed.
 *
 *  Endpoints:
 *    POST /notary/attest-listing     → landlord ownership attestation
 *    POST /notary/attest-application → tenant eligibility attestation
 *    POST /notary/attest-settlement  → settlement attestation
 *    GET  /notary/info               → notary address + policies
 *    GET  /notary/edevlet/:address   → lookup identity (demo only)
 * ═══════════════════════════════════════════════════════════════════════════
 */

const express = require('express');
const cors    = require('cors');
const ethers  = require('ethers');
const db      = require('./edevlet-mock.json');

// ── Dynamic in-memory registry (survives as long as the server runs) ─────
// Structure mirrors edevlet-mock.json so all lookup helpers work uniformly.
const dynamicRegistry = { landlords: {}, tenants: {} };

// ── Notary wallet ─────────────────────────────────────────────────────────
// This key matches the address passed to PPREVSingle constructor.
// Anvil account index 9.
const NOTARY_PRIVATE_KEY =
  '0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6';
const notaryWallet = new ethers.Wallet(NOTARY_PRIVATE_KEY);

const app  = express();
const PORT = 3001;

app.use(cors());
app.use(express.json());

// ── Helpers ───────────────────────────────────────────────────────────────

function normalizeAddr(addr) {
  try { return ethers.getAddress(addr); } catch { return null; }
}

function reject(res, status, reason) {
  console.log(`  ✗ Rejected: ${reason}`);
  return res.status(status).json({ error: reason });
}

/**
 * Sign `msgHash` (bytes32 hex) with EIP-191 prefix.
 * Matches MessageHashUtils.toEthSignedMessageHash in the contract.
 */
async function signAttestation(msgHash) {
  return await notaryWallet.signMessage(ethers.getBytes(msgHash));
}

// ── Helper: resolve record (dynamic first, then static DB) ───────────────

function resolveLandlord(addr) {
  return dynamicRegistry.landlords[addr] || db.landlords[addr] || null;
}
function resolveTenant(addr) {
  return dynamicRegistry.tenants[addr] || db.tenants[addr] || null;
}

// ── Route: info ───────────────────────────────────────────────────────────

app.get('/notary/info', (_req, res) => {
  res.json({
    notaryAddress: notaryWallet.address,
    description:   'PPREV Notary Network — Mock E-Devlet Attestation Server',
    policies:      Object.keys(db.whitelistedPolicies),
    landlords:     Object.keys(db.landlords).length + Object.keys(dynamicRegistry.landlords).length,
    tenants:       Object.keys(db.tenants).length   + Object.keys(dynamicRegistry.tenants).length,
  });
});

// ── Route: E-Devlet dynamic registration ────────────────────────────────

app.post('/notary/edevlet/register', (req, res) => {
  const { address, role, ad, tcKimlik, properties, aylikGelir, krediSkoru } = req.body;

  const addr = normalizeAddr(address);
  if (!addr)                        return reject(res, 400, 'Invalid address');
  if (!role || !ad || !tcKimlik)    return reject(res, 400, 'Missing required fields: role, ad, tcKimlik');
  if (!/^\d{11}$/.test(tcKimlik))  return reject(res, 400, 'TC Kimlik No must be exactly 11 digits');
  if (role !== 'landlord' && role !== 'tenant')
                                    return reject(res, 400, 'Role must be landlord or tenant');

  // Prevent re-registration (block both static and dynamic)
  if (resolveLandlord(addr) || resolveTenant(addr))
    return reject(res, 409, 'Address already registered in E-Devlet');

  if (role === 'landlord') {
    if (!properties || !Array.isArray(properties) || properties.length === 0)
      return reject(res, 400, 'Landlord must provide at least one property');
    for (const p of properties) {
      if (!p.tapuNo || !p.adres || !p.tip || !p.metrekare)
        return reject(res, 400, 'Each property must have tapuNo, adres, tip, metrekare');
      if (!['rent','sale'].includes(p.tip))
        return reject(res, 400, 'Property tip must be rent or sale');
      if (isNaN(p.metrekare) || p.metrekare <= 0)
        return reject(res, 400, 'metrekare must be a positive number');
    }
    dynamicRegistry.landlords[addr] = {
      ad,
      tcKimlik,
      verified: true,
      properties: properties.map(p => ({
        tapuNo:    p.tapuNo,
        adres:     p.adres,
        tip:       p.tip,
        metrekare: Number(p.metrekare),
      })),
    };
    console.log(`\n[edevlet/register] Landlord: ${ad} (${addr}) — ${properties.length} property`);
    return res.json({
      success: true,
      role:    'landlord',
      record:  dynamicRegistry.landlords[addr],
    });
  }

  // tenant
  const gelir  = Number(aylikGelir);
  const kredi  = Number(krediSkoru);
  if (isNaN(gelir) || gelir < 0)   return reject(res, 400, 'aylikGelir must be a non-negative number');
  if (isNaN(kredi) || kredi < 0 || kredi > 1900)
                                    return reject(res, 400, 'krediSkoru must be 0–1900');

  dynamicRegistry.tenants[addr] = {
    ad,
    tcKimlik,
    verified:   true,
    aylikGelir: gelir,
    krediSkoru: kredi,
  };
  console.log(`\n[edevlet/register] Tenant: ${ad} (${addr}) — income: ${gelir} TRY, credit: ${kredi}`);
  return res.json({
    success: true,
    role:    'tenant',
    record:  dynamicRegistry.tenants[addr],
  });
});

// ── Route: E-Devlet lookup (demo) ─────────────────────────────────────────

app.get('/notary/edevlet/:address', (req, res) => {
  const addr = normalizeAddr(req.params.address);
  if (!addr) return reject(res, 400, 'Invalid address');

  const landlord = resolveLandlord(addr);
  const tenant   = resolveTenant(addr);

  if (landlord) return res.json({ role: 'landlord', record: landlord });
  if (tenant)   return res.json({ role: 'tenant',   record: tenant   });
  return res.json({ role: 'unknown', record: null });
});

// ── Route: Attest Listing Registration ────────────────────────────────────

app.post('/notary/attest-listing', async (req, res) => {
  const { landlordAddress, adHash, policyId, transcriptCommitment, timestamp, nonce } = req.body;

  console.log(`\n[attest-listing] ${landlordAddress}`);

  const addr = normalizeAddr(landlordAddress);
  if (!addr)                    return reject(res, 400, 'Invalid landlordAddress');
  if (!adHash)                  return reject(res, 400, 'Missing adHash');
  if (!policyId || !transcriptCommitment || !timestamp || !nonce)
                                return reject(res, 400, 'Missing required fields');

  // ── E-Devlet check: is this address a verified landlord? ──
  const record = resolveLandlord(addr);
  if (!record)
    return reject(res, 403,
      `Address ${addr} not found in E-Devlet as a property owner. ` +
      'Only verified landlords can register listings.');

  if (!record.verified)
    return reject(res, 403, 'Landlord identity not yet verified by E-Devlet.');

  if (!record.properties || record.properties.length === 0)
    return reject(res, 403, 'No registered properties found for this address in E-Devlet.');

  console.log(`  ✓ Landlord verified: ${record.ad} (${record.properties.length} property/properties)`);

  // ── Build message: keccak256(caller‖contract‖chainId‖adHash‖policyId‖transcript‖ts‖nonce) ──
  let msgHash;
  try {
    msgHash = ethers.solidityPackedKeccak256(
      ['address', 'address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256', 'bytes32'],
      [addr, contractAddress, BigInt(chainId), adHash, policyId, transcriptCommitment, BigInt(timestamp), nonce]
    );
  } catch (err) {
    return reject(res, 400, `Invalid bytes32 field: ${err.shortMessage || err.message}`);
  }

  const signature = await signAttestation(msgHash);
  console.log(`  ✓ Attestation signed: ${signature.slice(0, 20)}...`);

  res.json({
    signature,
    notaryAddress:  notaryWallet.address,
    landlord:       { ad: record.ad, propertyCount: record.properties.length },
    attestedFields: { adHash, policyId, transcriptCommitment, timestamp, nonce },
  });
});

// ── Route: Attest Application ─────────────────────────────────────────────

app.post('/notary/attest-application', async (req, res) => {
  const { tenantAddress, adHash, policyId, transcriptCommitment, timestamp, nonce, reqEscrowEth } = req.body;

  console.log(`\n[attest-application] ${tenantAddress}`);

  const addr = normalizeAddr(tenantAddress);
  if (!addr)   return reject(res, 400, 'Invalid tenantAddress');
  if (!adHash || !policyId || !transcriptCommitment || !timestamp || !nonce)
               return reject(res, 400, 'Missing required fields');

  // ── E-Devlet check: is this address a verified tenant? ──
  const record = resolveTenant(addr);
  if (!record)
    return reject(res, 403,
      `Address ${addr} not found in E-Devlet as an eligible tenant. ` +
      'Only verified individuals can apply to listings.');

  if (!record.verified)
    return reject(res, 403, 'Tenant identity not yet verified by E-Devlet.');

  // ── Policy-specific eligibility checks ──
  const policyKey = Object.keys(db.whitelistedPolicies).find(k =>
    ethers.keccak256(ethers.toUtf8Bytes(k)) === policyId
  );
  if (!policyKey)
    return reject(res, 400,
      `Unknown policy: ${policyId}. Cannot verify eligibility — policy not found in E-Devlet registry.`);

  const policy = db.whitelistedPolicies[policyKey];
  if (policy.minTenantIncome && record.aylikGelir < policy.minTenantIncome)
    return reject(res, 403,
      `Monthly income ${record.aylikGelir} TRY is below the required ${policy.minTenantIncome} TRY for policy ${policyKey}.`);
  if (policy.minCreditScore && record.krediSkoru < policy.minCreditScore)
    return reject(res, 403,
      `Credit score ${record.krediSkoru} is below the required ${policy.minCreditScore} for policy ${policyKey}.`);

  console.log(`  ✓ Tenant verified: ${record.ad} (income: ${record.aylikGelir} TRY/mo, credit: ${record.krediSkoru})`);

  let msgHash2;
  try {
    msgHash2 = ethers.solidityPackedKeccak256(
      ['address', 'address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256', 'bytes32'],
      [addr, contractAddress, BigInt(chainId), adHash, policyId, transcriptCommitment, BigInt(timestamp), nonce]
    );
  } catch (err) {
    return reject(res, 400, `Invalid bytes32 field: ${err.shortMessage || err.message}`);
  }

  const signature = await signAttestation(msgHash2);
  console.log(`  ✓ Attestation signed: ${signature.slice(0, 20)}...`);

  res.json({
    signature,
    notaryAddress:  notaryWallet.address,
    tenant:         { ad: record.ad, aylikGelir: record.aylikGelir, krediSkoru: record.krediSkoru },
    attestedFields: { adHash, policyId, transcriptCommitment, timestamp, nonce },
  });
});

// ── Route: Attest Settlement ──────────────────────────────────────────────

app.post('/notary/attest-settlement', async (req, res) => {
  const { landlordAddress, appId, transcriptCommitment, timestamp, nonce } = req.body;

  console.log(`\n[attest-settlement] appId=${appId?.slice(0,12)}... landlord=${landlordAddress}`);

  const addr = normalizeAddr(landlordAddress);
  if (!addr)  return reject(res, 400, 'Invalid landlordAddress');
  if (!appId || !transcriptCommitment || !timestamp || !nonce)
              return reject(res, 400, 'Missing required fields');

  // Settlement: just verify caller is a known landlord
  const record = resolveLandlord(addr);
  if (!record)
    return reject(res, 403, `Address ${addr} is not a verified landlord.`);

  console.log(`  ✓ Settlement by: ${record.ad}`);

  // Settlement message: keccak256(caller‖contract‖chainId‖appId‖transcript‖timestamp‖nonce)
  let msgHash;
  try {
    msgHash = ethers.solidityPackedKeccak256(
      ['address', 'address', 'uint256', 'bytes32', 'bytes32', 'uint256', 'bytes32'],
      [addr, contractAddress, BigInt(chainId), appId, transcriptCommitment, BigInt(timestamp), nonce]
    );
  } catch (err) {
    return reject(res, 400, `Invalid bytes32 field: ${err.shortMessage || err.message}`);
  }

  const signature = await signAttestation(msgHash);
  console.log(`  ✓ Settlement attestation signed: ${signature.slice(0, 20)}...`);

  res.json({
    signature,
    notaryAddress:  notaryWallet.address,
    attestedFields: { appId, transcriptCommitment, timestamp, nonce },
  });
});

// ── Start ─────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log('═══════════════════════════════════════════════════════════════');
  console.log('  PPREV Notary Network Server');
  console.log('═══════════════════════════════════════════════════════════════');
  console.log(`  Port          : ${PORT}`);
  console.log(`  Notary address: ${notaryWallet.address}`);
  console.log(`  Landlords     : ${Object.keys(db.landlords).length} in E-Devlet`);
  console.log(`  Tenants       : ${Object.keys(db.tenants).length} in E-Devlet`);
  console.log('═══════════════════════════════════════════════════════════════');
});
