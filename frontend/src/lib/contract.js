import { ethers } from 'ethers';
import PPREV_ABI from '../abi/PPREV.json';
import { PPREV_ADDRESS } from '../config';

export function getPPREVContract(signerOrProvider) {
  return new ethers.Contract(PPREV_ADDRESS, PPREV_ABI, signerOrProvider);
}

export async function fetchAllListings(contract) {
  const count = await contract.getListingCount();
  const listings = [];
  for (let i = 0; i < Number(count); i++) {
    const id = await contract.listingIds(i);
    const data = await contract.listings(id);
    listings.push({
      adHash: id,
      owner: data.owner,
      policyId: data.policyId,
      deposit: data.deposit,
      reqEscrow: data.reqEscrow,
      status: Number(data.status),
      createdAt: Number(data.createdAt),
    });
  }
  return listings;
}

export async function fetchAllApplications(contract) {
  const count = await contract.getApplicationCount();
  const apps = [];
  for (let i = 0; i < Number(count); i++) {
    const id = await contract.applicationIds(i);
    const data = await contract.applications(id);
    apps.push({
      appId: id,
      tenant: data.tenant,
      adHash: data.adHash,
      escrowAmount: data.escrowAmount,
      status: Number(data.status),
      expiresAt: Number(data.expiresAt),
    });
  }
  return apps;
}
