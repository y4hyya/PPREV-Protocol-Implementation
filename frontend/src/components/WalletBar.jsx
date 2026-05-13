import { connectWallet } from '../lib/wallet';

export default function WalletBar({ wallet, setWallet, addLog }) {
  const handleConnect = async () => {
    try {
      const w = await connectWallet();
      setWallet(w);
      addLog('Wallet', `Connected: ${w.address} (${w.balance} ETH)`, 'success');
    } catch (err) {
      addLog('Wallet', err.message, 'error');
    }
  };

  return (
    <div className="wallet-bar">
      <span className="logo">PPREV Protocol</span>
      {wallet ? (
        <div className="wallet-info">
          <span className="badge">Sepolia</span>
          <span className="address">{wallet.address.slice(0, 6)}...{wallet.address.slice(-4)}</span>
          <span className="balance">{parseFloat(wallet.balance).toFixed(4)} ETH</span>
        </div>
      ) : (
        <button onClick={handleConnect}>Connect MetaMask</button>
      )}
    </div>
  );
}
