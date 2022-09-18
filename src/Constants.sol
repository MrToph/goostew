// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

abstract contract Constants {
    uint256 public constant GOO_SHARES_ID = 0;
    uint256 public constant GOBBLER_STAKING_ID_START = GOO_SHARES_ID + 1;
    uint256 public constant MIN_GOO_SHARES_INITIAL_MINT = 1e12;
    // solmate prevents us from minting to 0 address
    address internal constant BURN_ADDRESS = address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);

    error Unauthorized();
    error InvalidStakingId();
    error MismatchedGobblers();
    error Reentered();

    event DepositGobblers(address indexed owner, uint256 indexed stakingId, uint256[] gobblerIds, uint32 sumMultiples);
    event DepositGoo(address indexed owner, uint256 amount, uint256 shares);
}
