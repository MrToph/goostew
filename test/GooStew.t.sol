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
    address internal immutable feeRecipient = address(0xfee);

    function setUp() public virtual override {
        _users.push(address(0x1000));
        _users.push(address(0x1001));
        _users.push(address(0x1002));

        super.setUp();
        stew = new GooStew(address(gobblers), address(goo), feeRecipient);

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

contract GooStewManualTest is BasicTest, Constants {
    function setUp() public virtual override {
        super.setUp();
        vm.warp(0);

        // deposit initial goo
        stew.deposit(MIN_GOO_SHARES_INITIAL_MINT, address(this));
    }

    function testFees() public {
        // should fail if we try to turn on fees or change fee recipient
        vm.expectRevert(Unauthorized.selector);
        stew.setFeeRecipient(address(this));
        vm.expectRevert(Unauthorized.selector);
        stew.setFeeRate(0);

        // deposit initial gobbler to start earning goo
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(address(this), 7);
        stew.depositGobblers(address(this), gobblerIds);

        // initially, fee rate should be zero
        skip(1 days);
        assertEq(stew.balanceOf(feeRecipient), 0);

        // set fees
        vm.prank(feeRecipient);
        stew.setFeeRate(type(uint32).max / 10); // 10%
        skip(1 days);
        vm.recordLogs();
        stew.updateUser(address(0)); // trigger update for share price increase
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2, "unexpected events length"); // 1 Transfer to fee address, 1 InflationUpdate
        Vm.Log memory log = logs[logs.length - 1];
        assertEq(log.topics[0], keccak256("InflationUpdate(uint40,uint256,uint256,uint256)"), "unexpected event");
        (,,, uint256 rewardsFee) = abi.decode(log.data, (uint40, uint256, uint256, uint256));

        vm.prank(feeRecipient);
        uint256 gooFees = stew.redeem(type(uint256).max, feeRecipient, feeRecipient);
        assertApproxEqRel(gooFees, rewardsFee, 1e6 /* 1e-12 max error */ );
    }

    function testGobblersRedeem() public {
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(address(_users[0]), 7);

        // user deposits
        vm.prank(_users[0]);
        stew.depositGobblers(_users[0], gobblerIds);
        assertEq(gobblers.ownerOf(gobblerIds[0]), address(stew));

        // `test` cannot withdraw
        skip(1 days);
        uint256[] memory removalIndexes = new uint256[](1);
        removalIndexes[0] = 0;
        vm.expectRevert(abi.encodeWithSignature("ValueNotFound(uint256)", 1));
        stew.withdrawGobblers(address(this), removalIndexes, gobblerIds);

        // user can withdraw
        vm.prank(_users[0]);
        stew.withdrawGobblers(_users[0], removalIndexes, gobblerIds);
        assertEq(gobblers.ownerOf(gobblerIds[0]), address(_users[0]));
    }

    function testOnlyOwnGobblersDeposit() public {
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(address(_users[0]), 7);

        // try to deposit user0's gobbler
        vm.expectRevert("WRONG_FROM");
        stew.depositGobblers(address(this), gobblerIds);
    }

    function testOnlyRevealedGobblersDeposit() public {
        skip(1 days); // pass mint start
        bytes32[] memory proof;
        uint256 gobblerId = gobblers.claimGobbler(proof);
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblerId;

        vm.expectRevert(abi.encodeWithSignature("UnrevealedGobblerDeposit(uint256)", gobblerId));
        stew.depositGobblers(address(this), gobblerIds);
    }

    function testBalanceAccuracy() public {
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(address(this), 7);
        stew.depositGobblers(address(this), gobblerIds);
        stew.deposit(1e18, address(this));
        uint256 sharesAfterDeposit = stew.balanceOf(address(this));

        // skip time, no update call but balanceOf should still reflect the rewards accrued to gobbler depositors
        skip(1 days);
        uint256 shares = stew.balanceOf(address(this));
        assertGt(shares, sharesAfterDeposit, "shares should have increased");

        stew.updateUser(address(this));
        uint256 sharesAfterUpdate = stew.balanceOf(address(this));
        assertEq(shares, sharesAfterUpdate, "shares should be the same after update");
    }

    function testRewardMath() public {
        uint256[] memory userGooIds = new uint256[](2);
        userGooIds[0] = gobblers.mintGobblerExposed(address(_users[0]), 3);
        userGooIds[1] = gobblers.mintGobblerExposed(address(_users[1]), 1);
        uint256[] memory userGooDeposits = new uint256[](2);
        userGooDeposits[0] = 3e18;
        userGooDeposits[1] = 6e18;
        goo.transfer(_users[0], userGooDeposits[0]);
        goo.transfer(_users[1], userGooDeposits[1]);

        // user 0 deposits and 1 day passes
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = userGooIds[0];
        vm.startPrank(_users[0]);
        stew.depositGobblers(_users[0], gobblerIds);
        stew.deposit(userGooDeposits[0], address(_users[0]));
        skip(1 days);
        // they should have received the same amount of goo that they would have received on their own
        uint256 gooEarned = stew.redeem(type(uint256).max, _users[0], _users[0]);
        assertGe( // in practice, it's slightly more because of the initial MIN_GOO_SHARES_INITIAL_MINT
        gooEarned, LibGOO.computeGOOBalance(3, userGooDeposits[0], uint256(toDaysWadUnsafe(86400))));
        // user 0 reinvests his initial
        stew.deposit(userGooDeposits[0], address(_users[0]));
        vm.stopPrank();

        // user 1 deposits and 1 day passes
        gobblerIds[0] = userGooIds[1];
        vm.startPrank(_users[1]);
        stew.depositGobblers(_users[1], gobblerIds);
        stew.deposit(userGooDeposits[1], address(_users[1]));
        skip(1 days);
        vm.stopPrank();

        /**
         * total goo balance M / 4 + sqrt(M * GOO) + GOO = 1 + sqrt(36) + 9 = 16
         * user 0 individual balance: 3/4 + sqrt(3*3) + 3 = 6.75
         * user 1 individual balance: 1/4 + sqrt(6) + 6 = 0.25 + 2.45 + 6 = 8.7
         *
         * user0 and user1 deposited go 1:2, so their gooReward should be split 1:2
         * rewardsGoo = sqrt(36) / 2 = 3
         * user0 and user1 deposited emissions 3:1, so their gobblerReward should be split 3:1
         * rewardsGobblers = M/4 + sqrt(36) / 2 = 4
         * user0: initialGoo + reward = 3 + 3 * 1/3 + 4 * 3/4 = 7
         * user1: initialGoo + reward = 6 + 3 * 2/3 + 4 * 1/4 = 9
         */
        // user 0 withdraws
        vm.prank(_users[0]);
        gooEarned = stew.redeem(type(uint256).max, _users[0], _users[0]);
        assertGt(gooEarned, 7e18 * (1e6 - 1) / 1e6);
        // user 1 withdraws
        vm.prank(_users[1]);
        gooEarned = stew.redeem(type(uint256).max, _users[1], _users[1]);
        assertGt(gooEarned, 9e18 * (1e6 - 1) / 1e6);
    }

    function testUpdateInflationNoOverflow() public {
        // test that update inflation does not overflow after 20 years with max gobbler deposits
        uint256[] memory gobblerIds = new uint256[](1);
        uint32 maxEmissionMultiple = 10_000 * 8 * 2; // legendary gobbler minted with all gobblers using max emission multiple of 8
        gobblerIds[0] = gobblers.mintGobblerExposed(address(this), maxEmissionMultiple);

        stew.depositGobblers(address(this), gobblerIds);
        skip(20 * 365 days);

        uint256 gooAmount = stew.redeem(type(uint256).max, address(this), address(this));
        assertEq(gooAmount, 2.13160000146e30);
        (,,,, uint256 lastIndex) = stew.getGlobalInfo();
        assertEq(lastIndex, 9.125e33);
        uint256 shares = stew.deposit(gooAmount, address(this));
        assertEq(shares, 1.46e21);
    }
}

contract GooStewFuzzTest is BasicTest, Constants {
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
    ) public {
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
        stew.deposit(MIN_GOO_SHARES_INITIAL_MINT, address(this));

        // someone deposits some multiple and goo
        console2.log("===== User 0 =====");
        vm.startPrank(_users[0]);
        gobblerIds[0] = allGobblerIds[0];
        {
            if (gobblerIds[0] > 0) {
                stew.depositGobblers(_users[0], gobblerIds);
            }
            stew.deposit(gooDeposits[0], _users[0]);
        }
        vm.stopPrank();

        // user deposits some multiple and some goo. time passes.
        console2.log("===== User 1 =====");
        vm.startPrank(_users[1]);
        gobblerIds[0] = allGobblerIds[1];
        {
            if (gobblerIds[0] > 0) {
                stew.depositGobblers(_users[1], gobblerIds);
            }
            stew.deposit(gooDeposits[1], _users[1]);
        }
        vm.stopPrank();
        skip(delays[0]);

        // someone else deposits some multiple and goo again. time passes.
        console2.log("===== User 2 =====");
        vm.startPrank(_users[2]);
        gobblerIds[0] = allGobblerIds[2];
        {
            if (gobblerIds[0] > 0) {
                stew.depositGobblers(_users[2], gobblerIds);
            }
            stew.deposit(gooDeposits[2], _users[2]);
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
    ) internal {
        // user redeems, should have received at least as much as they would have received on their own
        console2.log("===== Redeem User %s =====", userId);
        vm.startPrank(_users[userId]);

        if (gobblerId > 0) {
            console2.log("redeeming gobblers ...");
            uint256[] memory gobblerIds = new uint256[](1);
            gobblerIds[0] = gobblerId;
            uint256[] memory removalIndexes = new uint256[](1);
            removalIndexes[0] = 0; // only have a single gobbler
            stew.withdrawGobblers(_users[userId], removalIndexes, gobblerIds);
        }
        console2.log("redeeming goo ...");
        uint256 gooAmount = stew.redeem(type(uint256).max, _users[userId], _users[userId]);
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
