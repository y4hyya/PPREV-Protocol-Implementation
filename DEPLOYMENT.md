# PPREV Protocol — Local Deployment & Simulation Guide

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `anvil`, `cast`)
- Solidity 0.8.24 (auto-downloaded by Forge)

---

## 1. Compile

```bash
forge build
```

## 2. Run Tests

```bash
forge test -vvv
```

All 8 tests should pass, covering the full lifecycle plus revert conditions.

## 3. Deploy Locally (Anvil)

### Start a local node

```bash
# Terminal 1
anvil
```

This starts a local Ethereum node on `http://127.0.0.1:8545` with pre-funded accounts.

### Deploy mock verifiers + protocol

```bash
# Use Anvil's first pre-funded private key
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC=http://127.0.0.1:8545

# Deploy MockZKVerifier
ZK_VERIFIER=$(forge create src/PPREVSingle.sol:MockZKVerifier \
  --private-key $PRIVATE_KEY --rpc-url $RPC \
  --json | jq -r '.deployedTo')

echo "ZK Verifier: $ZK_VERIFIER"

# Deploy MockThresholdSignatureVerifier
SIG_VERIFIER=$(forge create src/PPREVSingle.sol:MockThresholdSignatureVerifier \
  --private-key $PRIVATE_KEY --rpc-url $RPC \
  --json | jq -r '.deployedTo')

echo "Sig Verifier: $SIG_VERIFIER"

# Deploy PPREVSingle
# Args: zkVerifier, sigVerifier, freshnessWindow(300s), expiryTimeout(3600s), minCollateral(0.1 ether)
PROTOCOL=$(forge create src/PPREVSingle.sol:PPREVSingle \
  --private-key $PRIVATE_KEY --rpc-url $RPC \
  --constructor-args $ZK_VERIFIER $SIG_VERIFIER 300 3600 100000000000000000 \
  --json | jq -r '.deployedTo')

echo "Protocol: $PROTOCOL"
```

## 4. Simulate the Full Flow

```bash
# ── Variables ──
ADMIN_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
LISTER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
APPLICANT_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

# ── Step 1: Whitelist a policy ──
POLICY_ID=$(cast keccak "test-policy")
cast send $PROTOCOL "whitelistPolicy(bytes32,bool)" $POLICY_ID true \
  --private-key $ADMIN_KEY --rpc-url $RPC

# ── Step 2: Register a listing ──
AD_HASH=$(cast keccak "test-ad")
NONCE1=$(cast keccak "nonce-1")
TIMESTAMP=$(date +%s)

cast send $PROTOCOL \
  "registerListing(bytes32,bytes32,uint256,bytes32,uint256,bytes32,bytes,bytes32[],bytes)" \
  $AD_HASH $POLICY_ID 50000000000000000 $(cast keccak "transcript") \
  $TIMESTAMP $NONCE1 0x1234 "[]" 0x5678 \
  --value 0.1ether --private-key $LISTER_KEY --rpc-url $RPC

# Verify listing
cast call $PROTOCOL "getListing(bytes32)" $AD_HASH --rpc-url $RPC

# ── Step 3: Apply to listing ──
NONCE2=$(cast keccak "nonce-2")
TIMESTAMP2=$(date +%s)

cast send $PROTOCOL \
  "applyToListing(bytes32,bytes32,bytes32,uint256,bytes32,bytes,bytes32[],bytes)" \
  $AD_HASH $POLICY_ID $(cast keccak "applicant-transcript") \
  $TIMESTAMP2 $NONCE2 0x1234 "[]" 0x5678 \
  --value 0.05ether --private-key $APPLICANT_KEY --rpc-url $RPC

# Derive appId
APPLICANT_ADDR=$(cast wallet address $APPLICANT_KEY)
APP_ID=$(cast keccak $(cast abi-encode "f(bytes32,address,bytes32)" $AD_HASH $APPLICANT_ADDR $NONCE2))

# ── Step 4: Settle ──
NONCE3=$(cast keccak "nonce-3")
TIMESTAMP3=$(date +%s)

cast send $PROTOCOL \
  "settleListing(bytes32,bytes32,uint256,bytes32,bytes,bytes32[],bytes)" \
  $APP_ID $(cast keccak "settlement-transcript") \
  $TIMESTAMP3 $NONCE3 0x1234 "[]" 0x5678 \
  --private-key $LISTER_KEY --rpc-url $RPC
```

### Simulating Expiration

Instead of settling, skip step 4 and warp time:

```bash
# Advance Anvil time by 3601 seconds
cast rpc evm_increaseTime 3601 --rpc-url $RPC
cast rpc evm_mine --rpc-url $RPC

# Expire (anyone can call)
cast send $PROTOCOL "expireApplication(bytes32)" $APP_ID \
  --private-key $ADMIN_KEY --rpc-url $RPC
```

---

## 5. Docker Simulation (Hardhat)

A complete Node.js + Hardhat Docker environment is provided for full lifecycle simulation.

### Quick Start with Docker Compose

Run the full end-to-end simulation flow:
```bash
docker compose up --build
```

Run specific Hardhat commands:
```bash
# Compile contracts only
docker compose run pprev compile

# Run Hardhat tests
docker compose run pprev test

# Run deployment script only
docker compose run pprev deploy
```

### Manual Docker Build & Run

```bash
docker build -t pprev-simulation .
docker run --rm pprev-simulation
```

The default command executes `npx hardhat run scripts/simulate.ts`, which runs the full protocol lifecycle and prints balances and contract states at each step.

---

## 6. Limitations of This Single-File MVP

| Area | Limitation |
|---|---|
| **ZK Proofs** | Mock verifiers always return `true`. Real circuits (Groth16/PLONK) need proper verifier contracts. |
| **Threshold Signatures** | Mock stub. Production requires BLS or Shamir-based aggregation with on-chain verification. |
| **Single Applicant per Listing** | Listing locks on first application. Real protocol needs a queue or multi-applicant handling. |
| **Escrow Model** | Simple ETH transfers. Production should use pull-over-push, ERC-20 support, and partial refunds. |
| **Access Control** | Basic `onlyOwner`. Production should use `AccessControl` with multiple roles. |
| **Gas Efficiency** | `via_ir` required due to stack depth. Struct packing and calldata optimization not performed. |
| **Upgradeability** | No proxy pattern. Real deployment should use UUPS or Transparent Proxy. |
| **Policy Verification** | Policies are just whitelisted `bytes32` IDs. No on-chain logic to enforce policy semantics. |
| **Collateral Slashing** | Not implemented. Listing owner collateral is simply returned on settlement. |
| **Events** | Minimal. Production needs richer event data for indexing (The Graph, etc.). |
