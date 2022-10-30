// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Goo} from "art-gobblers.git/Goo.sol";

contract MockGoo is Goo {
    constructor(address _artGobblers, address _pages) Goo(_artGobblers, _pages) {}

    function mintExposed(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
