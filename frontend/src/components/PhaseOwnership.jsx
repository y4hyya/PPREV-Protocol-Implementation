import { useState } from 'react';
import { ethers } from 'ethers';
import { MOCK_PROPERTIES } from '../config';
import { proveOwnership } from '../lib/prover';
import { generateProof, formatProofForContract } from '../lib/proofUtils';
import { getPPREVContract } from '../lib/contract';

export default function PhaseOwnership({ wallet, addLog, onTxComplete }) {
  const [propertyId, setPropertyId] = useState(MOCK_PROPERTIES[0].id);
  const [policyId, setPolicyId] = useState('policy-rental-standard');
  const [reqEscrow, setReqEscrow] = useState('0.01');
  const [deposit, setDeposit] = useState('0.001');
  const [loading, setLoading] = useState(false);

  const handleRegister = async () => {
    if (!wallet) return addLog('Pi_own', 'Connect wallet first', 'error');
    setLoading(true);

    try {
      // Step 1: TLSNotary attestation (mock)
      addLog('Pi_own', `Fetching property data for ${propertyId}...`);
      const adHashStr = propertyId + '|' + policyId;
      const adHash = ethers.keccak256(ethers.toUtf8Bytes(adHashStr));
      const proverResult = await proveOwnership(propertyId, adHashStr, policyId);
      addLog('Pi_own', `TLSNotary attestation complete. Transcript: ${proverResult.transcriptSize} bytes`, 'success');

      // Step 2: ZK proof generation
      addLog('Pi_own', 'Generating ZK ownership proof (snarkjs)...');
      const startTime = Date.now();
      const { proof, publicSignals } = await generateProof('ownership', proverResult.circuitInputs);
      const proofTime = Date.now() - startTime;
      addLog('Pi_own', `ZK proof generated in ${proofTime}ms (${publicSignals.length} public signals)`, 'success');

      // Step 3: Submit to contract
      addLog('Pi_own', 'Submitting registerListing tx to Sepolia...');
      const { proof_a, proof_b, proof_c, pubSignals } = formatProofForContract(proof, publicSignals);
      const contract = getPPREVContract(wallet.signer);
      const nonce = ethers.keccak256(ethers.toUtf8Bytes(proverResult.nonce));
      const tAuth = proverResult.tAuth;

      const tx = await contract.registerListing(
        adHash, ethers.keccak256(ethers.toUtf8Bytes(policyId)),
        ethers.parseEther(reqEscrow),
        nonce, tAuth,
        proof_a, proof_b, proof_c, pubSignals,
        { value: ethers.parseEther(deposit), gasLimit: 500000 }
      );
      addLog('Pi_own', `Tx sent: ${tx.hash}`, 'info');

      const receipt = await tx.wait();
      addLog('Pi_own', `Listing registered! Gas: ${receipt.gasUsed.toString()}. AdHash: ${adHash.slice(0, 16)}...`, 'success');
      onTxComplete();
    } catch (err) {
      addLog('Pi_own', `Error: ${err.message?.slice(0, 200)}`, 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="section">
      <h2>Phase 1: Register Listing (Pi_own)</h2>
      <p className="muted">Landlord proves property ownership via TLSNotary + ZK proof.</p>
      <div className="form-grid">
        <label>
          Property
          <select value={propertyId} onChange={e => setPropertyId(e.target.value)}>
            {MOCK_PROPERTIES.map(p => (
              <option key={p.id} value={p.id}>{p.id} - {p.owner} ({p.location})</option>
            ))}
          </select>
        </label>
        <label>
          Policy ID
          <input value={policyId} onChange={e => setPolicyId(e.target.value)} />
        </label>
        <label>
          Required Escrow (ETH)
          <input value={reqEscrow} onChange={e => setReqEscrow(e.target.value)} />
        </label>
        <label>
          Listing Deposit (ETH)
          <input value={deposit} onChange={e => setDeposit(e.target.value)} />
        </label>
      </div>
      <button onClick={handleRegister} disabled={loading || !wallet}>
        {loading ? 'Processing...' : 'Register Listing'}
      </button>
    </div>
  );
}
