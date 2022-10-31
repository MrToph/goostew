// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

abstract contract Constants {
    uint256 public constant MIN_GOO_SHARES_INITIAL_MINT = 1e12;
    // solmate prevents us from minting to 0 address
    address internal constant BURN_ADDRESS = address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);

    error Unauthorized();
    error InvalidArguments();
    error UnrevealedGobblerDeposit(uint256 gobblerId);

    event DepositGobblers(address indexed owner, uint256[] gobblerIds, uint32 sumMultiples);
    event DepositGoo(address indexed owner, uint256 amount, uint256 shares);
    event InflationUpdate(uint40 timestamp, uint256 rewardsGoo, uint256 rewardsGobblers, uint256 rewardsFee);
}
