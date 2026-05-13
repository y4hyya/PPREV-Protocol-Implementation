// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/PPREVSingle.sol";

/// @notice Notary verifier that always returns false. Used in tests only.
contract FailingNotaryVerifier is INotaryVerifier {
    function verifySignature(bytes32, bytes calldata) external pure override returns (bool) {
        return false;
    }
}
