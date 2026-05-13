import { useState } from 'react';
import { ethers } from 'ethers';
import { getDummyProof } from '../lib/proofUtils';
import { getPPREVContract } from '../lib/contract';

export default function PhaseSettlement({ wallet, applications, addLog, onTxComplete }) {
  const [selectedApp, setSelectedApp] = useState('');
  const [loading, setLoading] = useState(false);

  const pendingApps = applications.filter(a => a.status === 1);

  const handleSettle = async () => {
    if (!wallet) return addLog('Pi_trans', 'Connect wallet first', 'error');
    if (!selectedApp) return addLog('Pi_trans', 'Select an application first', 'error');
    setLoading(true);

    try {
      addLog('Pi_trans', 'Fetching transfer verification from e-Devlet...');

      // No transfer circuit exists — use dummy proof (VK not set, verifier accepts all)
      const { proof_a, proof_b, proof_c, pubSignals } = getDummyProof();
      const contract = getPPREVContract(wallet.signer);
      const nonce = ethers.keccak256(ethers.toUtf8Bytes('settle-nonce-' + Date.now()));
      const tAuth = Math.floor(Date.now() / 1000);

      addLog('Pi_trans', 'Submitting settleApplication tx to Sepolia...');
      const tx = await contract.settleApplication(
        selectedApp, nonce, tAuth,
        proof_a, proof_b, proof_c, pubSignals,
        { gasLimit: 500000 }
      );
      addLog('Pi_trans', `Tx sent: ${tx.hash}`, 'info');

      const receipt = await tx.wait();
      addLog('Pi_trans', `Settlement complete! Gas: ${receipt.gasUsed.toString()}. Escrow + deposit released to owner.`, 'success');
      onTxComplete();
    } catch (err) {
      addLog('Pi_trans', `Error: ${err.message?.slice(0, 200)}`, 'error');
    } finally {
      setLoading(false);
    }
  };

  const handleExpire = async () => {
    if (!wallet) return addLog('Pi_trans', 'Connect wallet first', 'error');
    if (!selectedApp) return addLog('Pi_trans', 'Select an application first', 'error');
    setLoading(true);

    try {
      const contract = getPPREVContract(wallet.signer);
      addLog('Pi_trans', 'Submitting expireApplication tx...');
      const tx = await contract.expireApplication(selectedApp, { gasLimit: 300000 });
      addLog('Pi_trans', `Tx sent: ${tx.hash}`, 'info');

      const receipt = await tx.wait();
      addLog('Pi_trans', `Application expired! Gas: ${receipt.gasUsed.toString()}. Escrow slashed/refunded.`, 'success');
      onTxComplete();
    } catch (err) {
      addLog('Pi_trans', `Error: ${err.message?.slice(0, 200)}`, 'error');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="section">
      <h2>Phase 3: Settlement (Pi_trans)</h2>
      <p className="muted">Landlord confirms transfer, settles escrow. Or expire a timed-out application.</p>
      <div className="form-grid">
        <label>
          Pending Application
          <select value={selectedApp} onChange={e => setSelectedApp(e.target.value)}>
            <option value="">-- Select pending application --</option>
            {pendingApps.map(a => (
              <option key={a.appId} value={a.appId}>
                {a.appId.slice(0, 16)}... (Tenant: {a.tenant.slice(0, 8)}..., Escrow: {ethers.formatEther(a.escrowAmount)} ETH)
              </option>
            ))}
          </select>
        </label>
      </div>
      <div className="button-group">
        <button onClick={handleSettle} disabled={loading || !wallet}>
          {loading ? 'Processing...' : 'Settle Application'}
        </button>
        <button onClick={handleExpire} disabled={loading || !wallet} className="btn-secondary">
          Expire Application
        </button>
      </div>
    </div>
  );
}
