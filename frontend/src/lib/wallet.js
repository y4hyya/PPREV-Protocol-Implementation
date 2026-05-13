import { ethers } from 'ethers';
import { SEPOLIA_CHAIN_ID } from '../config';

export async function connectWallet() {
  if (!window.ethereum) {
    throw new Error('MetaMask not detected. Please install MetaMask.');
  }

  await window.ethereum.request({ method: 'eth_requestAccounts' });
  const provider = new ethers.BrowserProvider(window.ethereum);
  const network = await provider.getNetwork();

  if (Number(network.chainId) !== SEPOLIA_CHAIN_ID) {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0x' + SEPOLIA_CHAIN_ID.toString(16) }],
      });
    } catch {
      throw new Error('Please switch MetaMask to Sepolia testnet.');
    }
    return connectWallet();
  }

  const signer = await provider.getSigner();
  const address = await signer.getAddress();
  const balance = await provider.getBalance(address);

  return { provider, signer, address, balance: ethers.formatEther(balance) };
}
