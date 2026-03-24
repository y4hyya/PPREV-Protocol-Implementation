// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/PPREVSingle.sol";

/// @notice ZK verifier that always returns false. Used in tests only.
contract FailingZKVerifier is IZKVerifier {
    function verifyProof(bytes calldata, bytes32[] calldata) external pure override returns (bool) {
        return false;
    }
}

/// @notice Threshold sig verifier that always returns false. Used in tests only.
contract FailingThresholdSigVerifier is IThresholdSigVerifier {
    function verifySignature(bytes32, bytes calldata) external pure override returns (bool) {
        return false;
    }
}
