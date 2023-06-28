// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

interface IOptionReward {
    error OptionReward__InvalidSettlement();
    error OptionReward__LockupNotExpired(uint256 lockupEnd);
    error OptionReward__NotCallOption(address option);
    error OptionReward__NotEnoughRedeemableLongs(UD60x18 redeemableLongs, UD60x18 amount);
    error OptionReward__UnderwriterNotAuthorized(address sender);
    error OptionReward__ExercisePeriodNotEnded(uint256 maturity, uint256 exercisePeriodEnd);
    error OptionReward__OptionNotExpired(uint256 maturity);
    error OptionReward__OptionInTheMoney(UD60x18 settlementPrice, UD60x18 strike);
    error OptionReward__OptionOutTheMoney(UD60x18 settlementPrice, UD60x18 strike);
    error OptionReward__PriceIsStale(uint256 blockTimestamp, uint256 timestamp);
    error OptionReward__PriceIsZero();

    event OptionClaimed(address indexed user, UD60x18 contractSize);
    event RewardsClaimed(
        address indexed user,
        UD60x18 strike,
        uint64 maturity,
        UD60x18 contractSize,
        UD60x18 baseAmount
    );
    event Settled(
        UD60x18 strike,
        uint64 maturity,
        UD60x18 contractSize,
        UD60x18 intrinsicValuePerContract,
        UD60x18 maxRedeemableLongs,
        UD60x18 baseAmountPaid,
        UD60x18 baseAmountFee,
        UD60x18 quoteAmountPaid,
        UD60x18 quoteAmountFee,
        UD60x18 baseAmountReserved
    );

    struct SettleVarsInternal {
        UD60x18 intrinsicValuePerContract;
        UD60x18 totalUnderwritten;
        UD60x18 maxRedeemableLongs;
        UD60x18 baseAmountReserved;
        uint256 fee;
    }

    /// @notice ToDo
    function underwrite(address longReceiver, UD60x18 contractSize) external;

    /// @notice ToDo
    function claimRewards(UD60x18 strike, uint64 maturity, UD60x18 contractSize) external;

    /// @notice ToDo
    function settle(UD60x18 strike, uint64 maturity) external;

    /// @notice Returns the amount of base tokens allocated for `claimRewards`
    function getTotalBaseAllocated() external view returns (uint256);
}
