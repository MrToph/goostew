// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

abstract contract Constants {
    uint256 public constant MIN_GOO_SHARES_INITIAL_MINT = 1e12;
    // solmate prevents us from minting to 0 address
    address internal constant BURN_ADDRESS = address(0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD);
    address internal constant LAZY_MINT_ADDRESS = address(0x1);

    error Unauthorized();
    error InvalidArguments();
    error Reentered();

    event DepositGobblers(address indexed owner, uint256[] gobblerIds, uint32 sumMultiples);
    event DepositGoo(address indexed owner, uint256 amount, uint256 shares);
}
