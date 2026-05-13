import { ethers } from 'ethers';
import { LISTING_STATUS, APP_STATUS } from '../config';

export default function ListingsView({ listings, applications }) {
  return (
    <div className="section">
      <h2>On-Chain Data</h2>

      <h3>Listings ({listings.length})</h3>
      {listings.length === 0 ? (
        <p className="muted">No listings registered yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Ad Hash</th>
              <th>Owner</th>
              <th>Escrow Required</th>
              <th>Deposit</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {listings.map((l) => (
              <tr key={l.adHash}>
                <td className="mono">{l.adHash.slice(0, 10)}...</td>
                <td className="mono">{l.owner.slice(0, 8)}...</td>
                <td>{ethers.formatEther(l.reqEscrow)} ETH</td>
                <td>{ethers.formatEther(l.deposit)} ETH</td>
                <td><span className={`status status-${LISTING_STATUS[l.status]?.toLowerCase()}`}>{LISTING_STATUS[l.status]}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h3>Applications ({applications.length})</h3>
      {applications.length === 0 ? (
        <p className="muted">No applications submitted yet.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>App ID</th>
              <th>Tenant</th>
              <th>Ad Hash</th>
              <th>Escrow</th>
              <th>Status</th>
              <th>Expires</th>
            </tr>
          </thead>
          <tbody>
            {applications.map((a) => (
              <tr key={a.appId}>
                <td className="mono">{a.appId.slice(0, 10)}...</td>
                <td className="mono">{a.tenant.slice(0, 8)}...</td>
                <td className="mono">{a.adHash.slice(0, 10)}...</td>
                <td>{ethers.formatEther(a.escrowAmount)} ETH</td>
                <td><span className={`status status-${APP_STATUS[a.status]?.toLowerCase().replace('_', '-')}`}>{APP_STATUS[a.status]}</span></td>
                <td>{a.expiresAt > 0 ? new Date(a.expiresAt * 1000).toLocaleString() : '-'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
