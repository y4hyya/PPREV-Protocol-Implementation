import { useState, useEffect, useCallback } from 'react';
import WalletBar from './components/WalletBar';
import PhaseOwnership from './components/PhaseOwnership';
import PhaseEligibility from './components/PhaseEligibility';
import PhaseSettlement from './components/PhaseSettlement';
import ListingsView from './components/ListingsView';
import StatusLog from './components/StatusLog';
import { getPPREVContract, fetchAllListings, fetchAllApplications } from './lib/contract';

export default function App() {
  const [wallet, setWallet] = useState(null);
  const [logs, setLogs] = useState([]);
  const [listings, setListings] = useState([]);
  const [applications, setApplications] = useState([]);

  const addLog = useCallback((phase, message, type = 'info') => {
    setLogs(prev => [{ timestamp: new Date().toISOString(), phase, message, type }, ...prev]);
  }, []);

  const refreshData = useCallback(async () => {
    if (!wallet) return;
    try {
      const contract = getPPREVContract(wallet.provider);
      const [l, a] = await Promise.all([
        fetchAllListings(contract),
        fetchAllApplications(contract),
      ]);
      setListings(l);
      setApplications(a);
    } catch (err) {
      addLog('Data', `Failed to refresh: ${err.message}`, 'error');
    }
  }, [wallet, addLog]);

  useEffect(() => {
    if (wallet) refreshData();
  }, [wallet, refreshData]);

  return (
    <div className="app">
      <WalletBar wallet={wallet} setWallet={setWallet} addLog={addLog} />
      <div className="container">
        <PhaseOwnership wallet={wallet} addLog={addLog} onTxComplete={refreshData} />
        <PhaseEligibility wallet={wallet} listings={listings} addLog={addLog} onTxComplete={refreshData} />
        <PhaseSettlement wallet={wallet} applications={applications} addLog={addLog} onTxComplete={refreshData} />
        <ListingsView listings={listings} applications={applications} />
        <StatusLog logs={logs} />
      </div>
    </div>
  );
}
