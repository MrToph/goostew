// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import "src/GooStew.sol";
import "src/Constants.sol";
import "src/IGobblers.sol";
import {LibGOO} from "src/LibGOO.sol";
import "./ArtGobblersTest.sol";

contract BasicTest is ArtGobblersTest, ERC1155TokenReceiver {
    GooStew public stew;

    function setUp() public virtual override {
        super.setUp();
        stew = new GooStew(address(gobblers), address(goo));

        _mintGoo(address(this), type(uint128).max);
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);
    }

    function xtestGobblerMint() public {
        uint256[] memory multiples = new uint256[](2);
        multiples[0] = 6;
        multiples[1] = 12423;
        uint256[] memory gobblerIds = new uint256[](2);

        for (uint256 i = 0; i < multiples.length; i++) {
            gobblerIds[i] = gobblers.mintGobblerExposed(uint32(multiples[i]));
            assertEq(gobblers.ownerOf(gobblerIds[i]), address(this));
            assertEq(
                gobblers.getGobblerEmissionMultiple(gobblerIds[i]),
                multiples[i]
            );
        }
    }

}

contract GooStewTest is BasicTest, Constants {
    function setUp() public virtual override {
        super.setUp();
        vm.warp(0);
    }

    /**
     * Scenario: someone deposits some multiple and goo. user deposits some multiple and some goo. time passes.
     * someone else deposits some multiple and goo again. time passes.
     * user redeems, should have received at least as much as they would have received on their own
     */
    function testNoLoss(
        uint16[3] memory gobblerMultiples,
        uint72[3] memory gooDeposits,
        uint24[2] memory delays // in seconds, max range ~200 days
    ) public {
        // assumes & bounds
        vm.assume(delays[0] > 0 && delays[1] > 0);
        vm.assume(gooDeposits[0] != 0);
        gooDeposits[0] = uint72(
            bound(gooDeposits[0], MIN_GOO_SHARES_INITIAL_MINT, type(uint72).max)
        );

        // preparation
        uint256 totalDelay = uint256(delays[0]) + delays[1];
        uint256[] memory allGobblerIds = new uint256[](
            gobblerMultiples.length
        );
        for (uint256 i = 0; i < gobblerMultiples.length; i++) {
            vm.assume(gobblerMultiples[i] > 0);
            allGobblerIds[i] = gobblers.mintGobblerExposed(
                gobblerMultiples[i]
            );
        }
        uint256[] memory gobblerIds = new uint256[](1);

        // someone deposits some multiple and goo
        console2.log("===== User 0 =====");
        gobblerIds[0] = allGobblerIds[0];
        stew.deposit(gobblerIds, gooDeposits[0]);

        // user deposits some multiple and some goo. time passes.
        console2.log("===== User 1 =====");
        gobblerIds[0] = allGobblerIds[1];
        (uint256 stakingId, , uint256 gooShares) = stew.deposit(
            gobblerIds,
            gooDeposits[1]
        );
        skip(delays[0]);

        // someone else deposits some multiple and goo again. time passes.
        console2.log("===== User 2 =====");
        gobblerIds[0] = allGobblerIds[2];
        stew.deposit(gobblerIds, gooDeposits[2]);
        skip(delays[1]);

        // user redeems, should have received at least as much as they would have received on their own
        console2.log("===== Redeem =====");
        gobblerIds[0] = allGobblerIds[1];
        uint256 gooAmount = stew.redeemGooShares(gooShares);
        gooAmount += stew.redeemGobblers(stakingId, gobblerIds);

        uint256 totalGooNoStake = LibGOO.computeGOOBalance(
            gobblerMultiples[1],
            gooDeposits[1], // initial deposit
            uint256(toDaysWadUnsafe(totalDelay))
        );
        assertGe(gooAmount, (totalGooNoStake * (1e6 - 1)) / 1e6); // 0.00001% rounding error allowed
    }
}
