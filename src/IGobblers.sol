// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IGobblers is IERC721 {
    function getGobblerEmissionMultiple(uint256 gobblerId) external view returns (uint256);
    // g(now, user.m, user.gooVirtualBalance)
    function gooBalance(address user) external view returns (uint256);
    // ERC20 => gobbler tank
    function addGoo(uint256 gooAmount) external;
    // gobbler tank => ERC20
    function removeGoo(uint256 gooAmount) external;

    /// @notice Struct holding data relevant to each user's account.
    struct UserData {
        // The total number of gobblers currently owned by the user.
        uint32 gobblersOwned;
        // The sum of the multiples of all gobblers the user holds.
        uint32 emissionMultiple;
        // User's goo balance at time of last checkpointing.
        uint128 lastBalance;
        // Timestamp of the last goo balance checkpoint.
        uint64 lastTimestamp;
    }

    function getUserData(address owner) external view returns (UserData memory);
}
