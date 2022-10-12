// SPDX-License-Identifier: MIT
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
    address[] internal _users;

    function setUp() public virtual override {
        _users.push(address(0x1000));
        _users.push(address(0x1001));
        _users.push(address(0x1002));

        super.setUp();
        stew = new GooStew(address(gobblers), address(goo));

        _mintGoo(address(this), type(uint128).max);
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);
        for (uint256 i = 0; i < _users.length; i++) {
            vm.startPrank(_users[i]);
            goo.approve(address(stew), type(uint256).max);
            gobblers.setApprovalForAll(address(stew), true);
            vm.stopPrank();
        }
    }

    function xtestGobblerMint() public {
        uint256[] memory multiples = new uint256[](2);
        multiples[0] = 6;
        multiples[1] = 12423;
        uint256[] memory gobblerIds = new uint256[](2);

        for (uint256 i = 0; i < multiples.length; i++) {
            gobblerIds[i] = gobblers.mintGobblerExposed(address(this), uint32(multiples[i]));
            assertEq(gobblers.ownerOf(gobblerIds[i]), address(this));
            assertEq(gobblers.getGobblerEmissionMultiple(gobblerIds[i]), multiples[i]);
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
        uint24[2] memory delays, // in seconds, max range ~200 days
        uint16[3] memory gobblerMultiples,
        uint72[3] memory gooDeposits
    )
        public
    {
        // assumes & bounds
        vm.assume(delays[0] > 0 && delays[1] > 0);
        vm.assume(gooDeposits[0] != 0);
        // lower-bound user goo deposits to not fuzz test with tiny values that lead to rounding errors.
        for (uint256 i = 0; i < gooDeposits.length; i++) {
            if (gooDeposits[i] > 0) {
                gooDeposits[i] = uint72(bound(gooDeposits[0], 1e18, type(uint72).max));
                goo.transfer(_users[i], gooDeposits[i]);
            }
        }

        // preparation
        uint256 totalDelay = uint256(delays[0]) + delays[1];
        uint256[] memory allGobblerIds = new uint256[](gobblerMultiples.length);
        for (uint256 i = 0; i < gobblerMultiples.length; i++) {
            if (gobblerMultiples[i] > 0) {
                allGobblerIds[i] = gobblers.mintGobblerExposed(_users[i], gobblerMultiples[i]);
            }
        }
        uint256[] memory gobblerIds = new uint256[](1);

        // deposit initial mint that is sent to burn address because first deposit can actually lead to a loss
        // in practice we will bootstrap the contract with this tiny amount of goo
        stew.depositGoo(MIN_GOO_SHARES_INITIAL_MINT);

        // someone deposits some multiple and goo
        console2.log("===== User 0 =====");
        vm.startPrank(_users[0]);
        gobblerIds[0] = allGobblerIds[0];
        {
            if (gobblerIds[0] > 0) {
                stew.depositGobblers(gobblerIds);
            }
            stew.depositGoo(gooDeposits[0]);
        }
        vm.stopPrank();

        // user deposits some multiple and some goo. time passes.
        console2.log("===== User 1 =====");
        vm.startPrank(_users[1]);
        gobblerIds[0] = allGobblerIds[1];
        {
            if (gobblerIds[0] > 0) {
                stew.depositGobblers(gobblerIds);
            }
            stew.depositGoo(gooDeposits[1]);
        }
        vm.stopPrank();
        skip(delays[0]);

        // someone else deposits some multiple and goo again. time passes.
        console2.log("===== User 2 =====");
        vm.startPrank(_users[2]);
        gobblerIds[0] = allGobblerIds[2];
        {
            if (gobblerIds[0] > 0) {
                stew.depositGobblers(gobblerIds);
            }
            stew.depositGoo(gooDeposits[2]);
        }
        vm.stopPrank();
        skip(delays[1]);

        redeemAndAssertNoLoss(1, allGobblerIds[1], gobblerMultiples[1], gooDeposits[1], totalDelay);
        redeemAndAssertNoLoss(0, allGobblerIds[0], gobblerMultiples[0], gooDeposits[0], totalDelay);
        redeemAndAssertNoLoss(2, allGobblerIds[2], gobblerMultiples[2], gooDeposits[2], delays[1]);
    }

    function redeemAndAssertNoLoss(
        uint256 userId,
        uint256 gobblerId,
        uint256 gobblerMultiple,
        uint256 gooDepositAmount,
        uint256 delay
    )
        internal
    {
        // user redeems, should have received at least as much as they would have received on their own
        console2.log("===== Redeem User %s =====", userId);
        vm.startPrank(_users[userId]);

        if (gobblerId > 0) {
            console2.log("redeeming gobblers ...");
            uint256[] memory gobblerIds = new uint256[](1);
            gobblerIds[0] = gobblerId;
            uint256[] memory removalIndexes = new uint256[](1);
            removalIndexes[0] = 0; // only have a single gobbler
            stew.redeemGobblers(removalIndexes, gobblerIds);
        }
        console2.log("redeeming goo ...");
        uint256 gooAmount = stew.redeemGooShares(type(uint256).max);
        vm.stopPrank();

        uint256 totalGooNoStake = LibGOO.computeGOOBalance(
            gobblerMultiple,
            gooDepositAmount, // initial deposit
            uint256(toDaysWadUnsafe(delay))
        );
        // 1 bips (0.01%) rounding error allowed. happens with tiny goo deposits
        assertGe(gooAmount, (totalGooNoStake * (1e4 - 1)) / 1e4);
    }
}
