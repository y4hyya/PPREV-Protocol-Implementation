export const PPREV_ADDRESS = '0x9cA8236e5Aa3152ac81C067e3BB40797125f521F';
export const VERIFIER_ADDRESS = '0xC28E620aDe34AB04cF646c63d8612406c87045CD';
export const SEPOLIA_CHAIN_ID = 11155111;

export const CIRCUIT_PATHS = {
  ownership: {
    wasm: '/circuits/ownership/ownership.wasm',
    zkey: '/circuits/ownership/ownership_final.zkey',
  },
  eligibility: {
    wasm: '/circuits/eligibility/eligibility.wasm',
    zkey: '/circuits/eligibility/eligibility_final.zkey',
  },
};

export const MOCK_PROPERTIES = [
  { id: 'PROP-2024-001', owner: 'Ahmet Yilmaz', location: 'Kadikoy, Istanbul', area: 120 },
  { id: 'PROP-2024-002', owner: 'Mehmet Demir', location: 'Besiktas, Istanbul', area: 85 },
  { id: 'PROP-2024-003', owner: 'Fatma Kaya', location: 'Uskudar, Istanbul', area: 200 },
];

export const MOCK_TENANTS = [
  { id: 'TC-11111111111', name: 'Ali Ozturk', income: 45000, credit: 720 },
  { id: 'TC-22222222222', name: 'Zeynep Arslan', income: 35000, credit: 680 },
  { id: 'TC-33333333333', name: 'Can Polat', income: 15000, credit: 550 },
];

export const LISTING_STATUS = ['NONE', 'ACTIVE', 'LOCKED', 'SETTLED', 'EXPIRED'];
export const APP_STATUS = ['NONE', 'PENDING_TRANSFER', 'EXPIRED', 'SETTLED'];
