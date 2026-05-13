/**
 * Browser-compatible port of tlsnotary/prover/prover.js
 * Replaces Node crypto with Web Crypto API, http with fetch.
 */

const FIELD_SIZE = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

function bytesToHex(bytes) {
  return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(data) {
  const encoded = new TextEncoder().encode(data);
  const buffer = await crypto.subtle.digest('SHA-256', encoded);
  return new Uint8Array(buffer);
}

async function hashToField(data) {
  const hash = await sha256(data);
  const hex = bytesToHex(hash);
  const bigint = BigInt('0x' + hex) >> 3n;
  return bigint % FIELD_SIZE;
}

async function nameToFields(name) {
  const parts = name.split(' ');
  const fields = [];
  for (let i = 0; i < 4; i++) {
    if (i < parts.length) {
      fields.push((await hashToField(parts[i])).toString());
    } else {
      fields.push('0');
    }
  }
  return fields;
}

function generateNonce() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return '0x' + bytesToHex(bytes);
}

async function simulateNotarySignature(transcriptHash, adHash, nonce, tAuth, policyId) {
  const message = `${transcriptHash}|${adHash}|${nonce}|${tAuth}|${policyId}`;
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode('notary-threshold-key'),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return {
    signature: '0x' + bytesToHex(new Uint8Array(sig)),
    signers: ['notary-1', 'notary-2', 'notary-3'],
    threshold: '2-of-3',
    timestamp: Math.floor(Date.now() / 1000),
  };
}

export async function proveOwnership(registryId, adHash, policyId) {
  const nonce = generateNonce();

  const res = await fetch(`/api/v1/property/${registryId}?nonce=${nonce}`);
  if (!res.ok) throw new Error(`Property fetch failed: ${res.status}`);
  const response = await res.json();

  const transcriptRaw = JSON.stringify(response);
  const transcriptHash = await hashToField(transcriptRaw);

  const tAuth = response.timestamp;
  const notarySignature = await simulateNotarySignature(transcriptHash, adHash, nonce, tAuth, policyId);

  const ownerNameFields = await nameToFields(response.data.ownerName);
  const registryIdField = await hashToField(response.data.registryId);
  const ownershipStatus = response.data.ownershipStatus === 'active' ? 1 : 0;
  const registryTimestamp = new Date(response.data.registrationDate).getTime() / 1000;

  const adHashField = await hashToField(adHash);
  const nonceField = await hashToField(nonce);
  const policyIdField = await hashToField(policyId);

  const circuitInputs = {
    ownerName: ownerNameFields,
    registryId: registryIdField.toString(),
    ownershipStatus: ownershipStatus.toString(),
    registryTimestamp: Math.floor(registryTimestamp).toString(),
    adHash: adHashField.toString(),
    nonce: nonceField.toString(),
    tAuth: tAuth.toString(),
    policyId: policyIdField.toString(),
    transcriptHash: transcriptHash.toString(),
  };

  return {
    circuitInputs,
    transcriptHash: transcriptHash.toString(),
    notarySignature,
    tAuth,
    nonce,
    rawResponse: response,
    transcriptSize: new TextEncoder().encode(transcriptRaw).byteLength,
  };
}

export async function proveEligibility(citizenId, adHash, policyId, tenantAddr, rentAmount, minCreditScore) {
  const nonce = generateNonce();

  const res = await fetch(`/api/v1/tenant/${citizenId}?nonce=${nonce}`);
  if (!res.ok) throw new Error(`Tenant fetch failed: ${res.status}`);
  const response = await res.json();

  const transcriptRaw = JSON.stringify(response);
  const transcriptHash = await hashToField(transcriptRaw);

  const tAuth = response.timestamp;
  const notarySignature = await simulateNotarySignature(transcriptHash, adHash, nonce, tAuth, policyId);

  const tenantIdHash = await hashToField(response.data.citizenId);
  const adHashField = await hashToField(adHash);
  const nonceField = await hashToField(nonce);
  const policyIdField = await hashToField(policyId);
  const tenantAddrField = BigInt(tenantAddr);

  const circuitInputs = {
    monthlyIncome: response.data.monthlyIncome.toString(),
    employmentStatus: response.data.employmentStatus === 'employed' ? '1' : '0',
    creditScore: response.data.creditScore.toString(),
    tenantIdHash: tenantIdHash.toString(),
    adHash: adHashField.toString(),
    nonce: nonceField.toString(),
    tAuth: tAuth.toString(),
    policyId: policyIdField.toString(),
    transcriptHash: transcriptHash.toString(),
    tenantAddr: tenantAddrField.toString(),
    rentAmount: rentAmount.toString(),
    minCreditScore: minCreditScore.toString(),
  };

  return {
    circuitInputs,
    transcriptHash: transcriptHash.toString(),
    notarySignature,
    tAuth,
    nonce,
    rawResponse: response,
    transcriptSize: new TextEncoder().encode(transcriptRaw).byteLength,
  };
}
