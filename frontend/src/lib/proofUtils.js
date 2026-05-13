import * as snarkjs from 'snarkjs';
import { CIRCUIT_PATHS } from '../config';

/**
 * Generate a Groth16 ZK proof using snarkjs in the browser.
 */
export async function generateProof(circuitType, circuitInputs) {
  const paths = CIRCUIT_PATHS[circuitType];
  if (!paths) throw new Error(`Unknown circuit type: ${circuitType}`);

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    circuitInputs,
    paths.wasm,
    paths.zkey
  );

  return { proof, publicSignals };
}

/**
 * Format snarkjs proof output for Solidity contract calldata.
 * Note: pi_b coordinates must be reversed for the on-chain verifier.
 */
export function formatProofForContract(proof, publicSignals) {
  const proof_a = [proof.pi_a[0], proof.pi_a[1]];
  const proof_b = [
    [proof.pi_b[0][1], proof.pi_b[0][0]],
    [proof.pi_b[1][1], proof.pi_b[1][0]],
  ];
  const proof_c = [proof.pi_c[0], proof.pi_c[1]];
  const pubSignals = publicSignals.map(s => s.toString());

  return { proof_a, proof_b, proof_c, pubSignals };
}

/**
 * Dummy proof for phases without a circuit (Pi_trans).
 * Verifier accepts because VK is not set on-chain.
 */
export function getDummyProof() {
  return {
    proof_a: [0, 0],
    proof_b: [[0, 0], [0, 0]],
    proof_c: [0, 0],
    pubSignals: [1],
  };
}
