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

contract ERC4626GooStewManualTest is ArtGobblersTest, ERC1155TokenReceiver {
    GooStew public stew;
    address[] internal _users;
    address internal immutable feeRecipient = address(0xfee);
    uint256 internal constant INITIAL_GOO = 1_000_000e18;

    function setUp() public virtual override {
        _users.push(address(0x1000));
        _users.push(address(0x1001));
        _users.push(address(0x1002));

        super.setUp();
        stew = new GooStew(address(gobblers), address(goo), feeRecipient);

        _mintGoo(address(this), type(uint128).max);
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);

        // do initial deposit s.t. updateInflation changes the index
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(address(this), uint32(9));
        stew.deposit(1e18, address(this));
        stew.depositGobblers(address(this), gobblerIds);

        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            goo.approve(address(stew), type(uint256).max);
            goo.transfer(_users[i], INITIAL_GOO);
        }
    }

    function testOnlyOwnOrApprovedGooWithdrawal() public {
        vm.prank(_users[0]);
        stew.deposit(1e18, _users[0]);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(_users[1]);
        stew.withdraw({assets: 2, receiver: _users[1], owner: _users[0]});

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(_users[1]);
        stew.redeem({shares: 1, receiver: _users[1], owner: _users[0]});

        vm.prank(_users[0]);
        stew.approve(_users[1], type(uint256).max);

        vm.startPrank(_users[1]);
        uint256 shares = stew.withdraw({assets: 2, receiver: _users[1], owner: _users[0]});
        stew.redeem({shares: 1, receiver: _users[1], owner: _users[0]});
        assertEq(goo.balanceOf(_users[1]), INITIAL_GOO + shares + 1);
    }
}

contract ERC4626GooStewFuzzTest is ArtGobblersTest, ERC1155TokenReceiver {
    GooStew public stew;
    address[] internal _users;
    address internal immutable feeRecipient = address(0xfee);
    uint256 internal constant INITIAL_GOO = type(uint120).max; // this is a realistic goo cap

    function setUp() public virtual override {
        _users.push(address(0x1000));
        _users.push(address(0x1001));
        _users.push(address(0x1002));

        super.setUp();
        stew = new GooStew(address(gobblers), address(goo), feeRecipient);

        _mintGoo(address(this), type(uint224).max * (_users.length + 1));
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);

        // do initial deposit s.t. updateInflation changes the index
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(address(this), uint32(9));
        stew.deposit(1e18, address(this));
        stew.depositGobblers(address(this), gobblerIds);

        for (uint256 i = 0; i < _users.length; i++) {
            vm.prank(_users[i]);
            goo.approve(address(stew), type(uint256).max);
            goo.transfer(_users[i], INITIAL_GOO);
        }
    }

    function testCannotWithdrawMoreThanBalance(uint120 assets) public {
        vm.assume(assets > 0);
        vm.startPrank(_users[0]);

        uint256 shares = stew.deposit(assets, _users[0]);
        vm.expectRevert(stdError.arithmeticError);
        stew.withdraw({assets: uint256(assets) + 1, receiver: _users[0], owner: _users[0]});
        vm.expectRevert(stdError.arithmeticError);
        stew.redeem({shares: shares + 1, receiver: _users[0], owner: _users[0]});

        vm.stopPrank();
    }

    function testDepositWithdraw(
        uint120[2] memory assets, // uint120 s.t. assets * shares fits into uint256
        uint120[2] memory withdrawAssets,
        uint24[3] memory delays // in seconds, max range ~200 days
    ) public {
        vm.assume(assets[0] > 0 && assets[1] > 0);

        {
            uint256 expectedShares = stew.previewDeposit(assets[0]);
            vm.prank(_users[0]);
            uint256 shares = stew.deposit(assets[0], _users[0]);
            assertEq(shares, expectedShares, "unexpected user0 deposit");
        }

        skip(delays[0]);

        {
            uint256 expectedShares = stew.previewDeposit(assets[1]);
            vm.prank(_users[1]);
            uint256 shares = stew.deposit(assets[1], _users[1]);
            assertEq(shares, expectedShares, "unexpected user1 deposit");
        }

        skip(delays[1]);

        {
            // when withdrawing, the shares are rounded up, so it can happen that they received 0 shares when depositing 1 amount, but when withdrawing it requires 1 share
            withdrawAssets[0] = uint120(bound(withdrawAssets[0], 0, stew.maxWithdraw(_users[0])));
            uint256 expectedShares = stew.previewWithdraw(withdrawAssets[0]);
            uint256 prevSharesBalance = stew.balanceOf(_users[0]);
            uint256 prevGooBalance = goo.balanceOf(_users[2]);
            vm.prank(_users[0]);
            uint256 shares = stew.withdraw(withdrawAssets[0], _users[2], _users[0]); // withdraw to user 2
            uint256 withdrawnShares = prevSharesBalance - stew.balanceOf(_users[0]);
            uint256 withdrawnGoo = goo.balanceOf(_users[2]) - prevGooBalance;
            assertEq(shares, expectedShares, "unexpected user0 withdraw");
            assertEq(withdrawnShares, expectedShares, "unexpected user0 withdraw user0 shares balance");
            assertEq(withdrawnGoo, withdrawAssets[0], "unexpected user0 withdraw user2 goo balance");
        }

        skip(delays[2]);

        {
            // when withdrawing, the shares are rounded up, so it can happen that they received 0 shares when depositing 1 amount, but when withdrawing it requires 1 share
            withdrawAssets[1] = uint120(bound(withdrawAssets[1], 0, stew.maxWithdraw(_users[1])));
            uint256 expectedShares = stew.previewWithdraw(withdrawAssets[1]);
            uint256 prevSharesBalance = stew.balanceOf(_users[1]);
            uint256 prevGooBalance = goo.balanceOf(_users[2]);
            vm.prank(_users[1]);
            uint256 shares = stew.withdraw(withdrawAssets[1], _users[2], _users[1]); // withdraw to user 2
            uint256 withdrawnShares = prevSharesBalance - stew.balanceOf(_users[1]);
            uint256 withdrawnGoo = goo.balanceOf(_users[2]) - prevGooBalance;
            assertEq(shares, expectedShares, "unexpected user1 withdraw");
            assertEq(withdrawnShares, expectedShares, "unexpected user1 withdraw user1 shares balance");
            assertEq(withdrawnGoo, withdrawAssets[1], "unexpected user1 withdraw user2 goo balance");
        }
    }

    function testMintRedeem(
        uint120[2] memory shares, // uint120 s.t. assets * shares fits into uint256
        uint120[2] memory withdrawShares,
        uint24[3] memory delays // in seconds, max range ~200 days
    ) public {
        vm.assume(shares[0] > 0 && shares[1] > 0);

        {
            // we need to restrict the shares to a realistic goo value to avoid overflows in ArtGobblers.gooBalance
            shares[0] = uint120(bound(shares[0], 1, stew.convertToShares(INITIAL_GOO)));
            uint256 expectedAssets = stew.previewMint(shares[0]);
            vm.prank(_users[0]);
            uint256 assets = stew.mint(shares[0], _users[0]);
            assertEq(assets, expectedAssets, "unexpected user0 mint");
        }

        skip(delays[0]);

        {
            // we need to restrict the shares to a realistic goo value to avoid overflows in ArtGobblers.gooBalance
            shares[1] = uint120(bound(shares[1], 1, stew.convertToShares(INITIAL_GOO)));
            uint256 expectedAssets = stew.previewMint(shares[1]);
            vm.prank(_users[1]);
            uint256 assets = stew.mint(shares[1], _users[1]);
            assertEq(assets, expectedAssets, "unexpected user1 mint");
        }

        skip(delays[1]);

        {
            withdrawShares[0] = uint120(bound(withdrawShares[0], 0, shares[0]));
            uint256 expectedAssets = stew.previewRedeem(withdrawShares[0]);
            uint256 prevSharesBalance = stew.balanceOf(_users[0]);
            uint256 prevGooBalance = goo.balanceOf(_users[2]);
            vm.prank(_users[0]);
            uint256 assets = stew.redeem(withdrawShares[0], _users[2], _users[0]); // withdraw to user 2
            uint256 withdrawnShares = prevSharesBalance - stew.balanceOf(_users[0]);
            uint256 withdrawnGoo = goo.balanceOf(_users[2]) - prevGooBalance;
            assertEq(assets, expectedAssets, "unexpected user0 redeem");
            assertEq(withdrawnShares, withdrawShares[0], "unexpected user0 redeem user0 shares balance");
            assertEq(withdrawnGoo, expectedAssets, "unexpected user0 redeem user2 goo balance");
        }

        skip(delays[2]);

        {
            withdrawShares[1] = uint120(bound(withdrawShares[1], 0, shares[1]));
            uint256 expectedAssets = stew.previewRedeem(withdrawShares[1]);
            uint256 prevSharesBalance = stew.balanceOf(_users[1]);
            uint256 prevGooBalance = goo.balanceOf(_users[2]);
            vm.prank(_users[1]);
            uint256 assets = stew.redeem(withdrawShares[1], _users[2], _users[1]); // withdraw to user 2
            uint256 withdrawnShares = prevSharesBalance - stew.balanceOf(_users[1]);
            uint256 withdrawnGoo = goo.balanceOf(_users[2]) - prevGooBalance;
            assertEq(assets, expectedAssets, "unexpected user1 redeem");
            assertEq(withdrawnShares, withdrawShares[1], "unexpected user1 redeem user1 shares balance");
            assertEq(withdrawnGoo, expectedAssets, "unexpected user1 redeem user2 goo balance");
        }
    }
}
