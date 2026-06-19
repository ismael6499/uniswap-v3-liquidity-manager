// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReentrancyGuard
/// @author Agustin Acosta
/// @notice Gas-optimized reentrancy protection modifier
/// @dev Implements a custom reentrancy check using low-gas status variables.
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    /// @notice Reverted when an external call attempts to reenter the locked execution context.
    error ReentrancyGuard__ReentrantCall();

    constructor() {
        _status = _NOT_ENTERED;
    }

    /// @notice Prevents a contract from calling itself, directly or indirectly.
    modifier nonReentrant() {
        if (_status == _ENTERED) {
            revert ReentrancyGuard__ReentrantCall();
        }
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}
