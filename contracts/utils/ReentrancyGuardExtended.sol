// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {OwnableInternal} from "@solidstate/contracts/access/ownable/OwnableInternal.sol";
import {ReentrancyGuardStorage} from "@solidstate/contracts/security/reentrancy_guard/ReentrancyGuardStorage.sol";

import {IReentrancyGuardExtended} from "./IReentrancyGuardExtended.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {ReentrancyGuardExtendedStorage} from "./ReentrancyGuardExtendedStorage.sol";

contract ReentrancyGuardExtended is IReentrancyGuardExtended, OwnableInternal, ReentrancyGuard {
    modifier nonReentrant() override {
        bool locked = _lockReentrancyGuard(msg.data);
        _;
        if (locked) _unlockReentrancyGuard();
    }

    /// @notice Returns true if the reentrancy guard is disabled, false otherwise
    function _isReentrancyGuardDisabled() internal view virtual returns (bool) {
        return ReentrancyGuardExtendedStorage.layout().disabled;
    }

    /// @inheritdoc IReentrancyGuardExtended
    function setReentrancyGuardDisabled(bool disabled) external onlyOwner {
        ReentrancyGuardExtendedStorage.layout().disabled = disabled;
        emit SetReentrancyGuardDisabled(disabled);
    }

    /// @notice Triggers a static-call check
    /// @dev For internal use only
    function __staticCallCheck() external {
        emit ReentrancyStaticCallCheck();
    }

    /// @notice Initiates an external call to `this` to determine if the current call is static
    function _isStaticCall() internal returns (bool) {
        try this.__staticCallCheck() {
            return false;
        } catch {
            return true;
        }
    }

    /// @notice Sets the reentrancy guard status to locked and returns true if the guard is not locked, disabled, nor
    ///         is the call static
    function _lockReentrancyGuard(bytes memory msgData) internal virtual returns (bool) {
        if (_isReentrancyGuardDisabled()) return false;

        ReentrancyGuardStorage.Layout storage l = ReentrancyGuardStorage.layout();
        if (l.status == REENTRANCY_STATUS_LOCKED) revert ReentrancyGuard__ReentrantCall();
        if (_isStaticCall()) return false;

        l.status = REENTRANCY_STATUS_LOCKED;
        return true;
    }
}
