import { useState } from 'react';
import { ethers } from 'ethers';
import { MOCK_TENANTS } from '../config';
import { proveEligibility } from '../lib/prover';
import { generateProof, formatProofForContract } from '../lib/proofUtils';
import { getPPREVContract } from '../lib/contract';

export default function PhaseEligibility({ wallet, listings, addLog, onTxComplete }) {
  const [tenantId, setTenantId] = useState(MOCK_TENANTS[0].id);
  const [selectedListing, setSelectedListing] = useState('');
  const [rentAmount, setRentAmount] = useState('10000');
  const [minCredit, setMinCredit] = useState('600');
  const [loading, setLoading] = useState(false);

  const activeListings = listings.filter(l => l.status === 1);

  const handleApply = async () => {
    if (!wallet) return addLog('Pi_elig', 'Connect wallet first', 'error');
    if (!selectedListing) return addLog('Pi_elig', 'Select a listing first', 'error');
    setLoading(true);

    try {
      const listing = listings.find(l => l.adHash === selectedListing);
      const adHashStr = selectedListing;
      const policyId = 'policy-rental-standard';

      // Step 1: TLSNotary attestation (mock)
      addLog('Pi_elig', `Fetching eligibility data for tenant ${tenantId}...`);
      const proverResult = await proveEligibility(
        tenantId, adHashStr, policyId,
        wallet.address,
        parseInt(rentAmount),
        parseInt(minCredit)
      );
      addLog('Pi_elig', `TLSNotary attestation complete. Transcript: ${proverResult.transcriptSize} bytes`, 'success');

      // Step 2: ZK proof generation
      addLog('Pi_elig', 'Generating ZK eligibility proof (snarkjs)...');
      const startTime = Date.now();
      const { proof, publicSignals } = await generateProof('eligibility', proverResult.circuitInputs);
      const proofTime = Date.now() - startTime;
      addLog('Pi_elig', `ZK proof generated in ${proofTime}ms (${publicSignals.length} public signals)`, 'success');

      // Step 3: Submit to contract
      addLog('Pi_elig', 'Submitting applyForListing tx to Sepolia...');
      const { proof_a, proof_b, proof_c, pubSignals } = formatProofForContract(proof, publicSignals);
      const contract = getPPREVContract(wallet.signer);
      const nonce = ethers.keccak256(ethers.toUtf8Bytes(proverResult.nonce));
      const tAuth = proverResult.tAuth;

      const escrowValue = listing ? listing.reqEscrow : ethers.parseEther('0.01');

      const tx = await contract.applyForListing(
        selectedListing, nonce, tAuth,
        proof_a, proof_b, proof_c, pubSignals,
        { value: escrowValue, gasLimit: 500000 }
      );
      addLog('Pi_elig', `Tx sent: ${tx.hash}`, 'info');

      const receipt = await tx.wait();
      addLog('Pi_elig', `Application submitted! Gas: ${receipt.gasUsed.toString()}`, 'success');
      onTxComplete();
    } catch (err) {
      addLog('Pi_elig', `Error: ${err.message?.slice(0, 200)}`, 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="section">
      <h2>Phase 2: Apply for Listing (Pi_elig)</h2>
      <p className="muted">Tenant proves income/credit eligibility via TLSNotary + ZK proof, deposits escrow.</p>
      <div className="form-grid">
        <label>
          Tenant Identity
          <select value={tenantId} onChange={e => setTenantId(e.target.value)}>
            {MOCK_TENANTS.map(t => (
              <option key={t.id} value={t.id}>{t.name} - Income: {t.income} TRY, Credit: {t.credit}</option>
            ))}
          </select>
        </label>
        <label>
          Target Listing
          <select value={selectedListing} onChange={e => setSelectedListing(e.target.value)}>
            <option value="">-- Select active listing --</option>
            {activeListings.map(l => (
              <option key={l.adHash} value={l.adHash}>
                {l.adHash.slice(0, 16)}... (Owner: {l.owner.slice(0, 8)}...)
              </option>
            ))}
          </select>
        </label>
        <label>
          Rent Amount (TRY)
          <input value={rentAmount} onChange={e => setRentAmount(e.target.value)} />
        </label>
        <label>
          Min Credit Score
          <input value={minCredit} onChange={e => setMinCredit(e.target.value)} />
        </label>
      </div>
      <button onClick={handleApply} disabled={loading || !wallet}>
        {loading ? 'Processing...' : 'Apply for Listing'}
      </button>
    </div>
  );
}
