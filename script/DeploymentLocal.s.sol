// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {Pages} from "art-gobblers.git/Pages.sol";
import {RandProvider} from "art-gobblers.git/utils/rand/RandProvider.sol";
import {toDaysWadUnsafe} from "solmate/utils/SignedWadMath.sol";

import {GooStew} from "src/GooStew.sol";

import {Utilities} from "test/utils/Utilities.sol";
import {MockArtGobblers} from "test/MockArtGobblers.sol";
import {MockGoo} from "test/MockGoo.sol";

contract Deployment is Script, Test, Utilities {
    using stdStorage for StdStorage;

    MockGoo internal goo;
    MockArtGobblers internal gobblers;
    GooStew internal stew;
    address internal constant feeRecipient = address(0xfee);
    address internal immutable user = address(uint160(vm.envUint("ADDRESS_USER_TEST")));
    address internal immutable npc;

    constructor() {
        string memory mnemonic = "test test test test test test test test test test test junk";
        (npc,) = deriveRememberKey(mnemonic, 0);
    }

    function setUp() public {}

    function run() public {
        vm.startBroadcast(npc);
        _deployMockGobblers();
        _deployGooStew();
        vm.stopBroadcast();

        _populateGooStew();
    }

    function _deployMockGobblers() private {
        goo = new MockGoo(
            predictContractAddress(
                address(tx.origin), // need to mimic deployer
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

        assertEq(goo.artGobblers(), address(gobblers), "goo.artGobblers mismatch");
    }

    function _deployGooStew() private {
        stew = new GooStew(address(gobblers), address(goo), feeRecipient);
    }

    function _populateGooStew() private {
        vm.startBroadcast(npc);

        uint256[] memory ids = new uint256[](3);
        ids[0] = _mintGobbler(address(npc), 6);
        ids[1] = _mintGobbler(address(npc), 7);
        ids[2] = _mintGobbler(address(npc), 8);

        _mintGoo(npc, 10e18);

        // deposit gobblers and goo to stew
        gobblers.setApprovalForAll(address(stew), true);
        goo.approve(address(stew), 10e18);
        stew.deposit(10e18, address(npc));
        stew.depositGobblers(address(npc), ids);

        // send some gobblers and goo to the user
        _mintGobbler(user, 6);
        _mintGobbler(user, 7);
        _mintGobbler(user, 8);
        _mintGoo(user, 10e18);

        vm.stopBroadcast();
    }

    function _mintGoo(address to, uint256 amount) internal {
        goo.mintExposed(to, amount);
    }

    function _mintGobbler(address to, uint32 emissionMultiple) internal returns (uint256) {
        return gobblers.mintGobblerExposed(address(to), emissionMultiple);
    }
}
