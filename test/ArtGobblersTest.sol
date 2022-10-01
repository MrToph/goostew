// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Goo} from "art-gobblers.git/Goo.sol";
import {ArtGobblers} from "art-gobblers.git/ArtGobblers.sol";
import {Pages} from "art-gobblers.git/Pages.sol";
import {RandProvider} from "art-gobblers.git/utils/rand/RandProvider.sol";
import {toDaysWadUnsafe} from "solmate/utils/SignedWadMath.sol";
import {Utilities} from "./utils/Utilities.sol";
import {MockArtGobblers} from "./MockArtGobblers.sol";

contract ArtGobblersTest is Test {
    using stdStorage for StdStorage;

    uint256 internal randCounter = 0;

    Utilities internal utils;
    Goo internal goo;
    MockArtGobblers internal gobblers;

    function setUp() public virtual {
        utils = new Utilities();
        goo = new Goo(
            utils.predictContractAddress(
                address(this),
                1 /* offset */
            ), // gobblers
            address(0xDEAD) // pages
        );

        gobblers = new MockArtGobblers(
            keccak256(abi.encodePacked(address(this))), // merkle tree = this
            block.timestamp,
            goo,
            Pages(address(0xDEAD)), // pages
            address(0xDEAD), // team
            address(0xDEAD), // community
            RandProvider(address(this)), // randProvider
            "base",
            ""
        );

        skip(1 days); // for mint time delay to be over
    }

    function _mintGoo(address to, uint256 amount) internal {
        stdstore.target(address(goo)).sig(goo.balanceOf.selector).with_key(to).checked_write(goo.balanceOf(to) + amount);

        // Goo has a `totalSupply` which we also need to increase
        stdstore.target(address(goo)).sig(goo.totalSupply.selector).with_key(to).checked_write(
            goo.totalSupply() + amount
        );
    }

    function _nextRandom() internal returns (uint256) {
        return uint256(keccak256(abi.encodePacked(randCounter++)));
    }
}
