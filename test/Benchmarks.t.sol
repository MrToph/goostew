// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import "src/GooStew.sol";
import "src/Constants.sol";
import "src/IGobblers.sol";
import {LibGOO} from "src/LibGOO.sol";
import "./ArtGobblersTest.sol";

// cost of function = gasPriceInGwei * gasUsed / 1e9 * ethPrice

contract BenchmarksTest is ArtGobblersTest, ERC1155TokenReceiver {
    GooStew public stew;
    address internal immutable feeRecipient = address(0xfee);
    uint256 constant MINTED_GOBBLERS = 20;

    function setUp() public virtual override {
        super.setUp();
        stew = new GooStew(IGobblers(address(gobblers)), IERC20(address(goo)), feeRecipient);

        _mintGoo(address(this), type(uint128).max);
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);

        for (uint256 i = 0; i < MINTED_GOBBLERS; ++i) {
            gobblers.mintGobblerExposed(address(this), uint32(6 + (i % 3)));
        }

        // set contract into normal state: LAZY_MINT_ADDRESS balance, _gobblerSharesPerMultipleIndex, _sumMultiples not zero
        address initializer = address(0x2);
        vm.startPrank(initializer);
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);

        _mintGoo(initializer, 1e12);
        stew.depositGoo(1e12);

        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = gobblers.mintGobblerExposed(initializer, 6);
        stew.depositGobblers(gobblerIds);

        skip(1 days); // call update once

        stew.updateUser(initializer);
        vm.stopPrank();

        skip(1 days); // let each test have to do an update which is the standard case
    }

    function testDepositGooInitial() public {
        // 0 balance before
        stew.depositGoo(10e18);
    }

    function testDepositGobblerInitial() public {
        // 0 deposited gobblers before
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = 1;
        stew.depositGobblers(gobblerIds);
    }

    function testDepositGobblersInitial() public {
        // 0 deposited gobblers before
        uint256[] memory gobblerIds = new uint256[](10);
        for (uint256 i = 0; i < gobblerIds.length; ++i) {
            gobblerIds[i] = i + 1;
        }
        stew.depositGobblers(gobblerIds);
    }
}

contract BenchmarksTest2 is ArtGobblersTest, ERC1155TokenReceiver {
    GooStew public stew;
    address internal immutable feeRecipient = address(0xfee);
    uint256 constant MINTED_GOBBLERS = 20;

    function setUp() public virtual override {
        super.setUp();
        stew = new GooStew(IGobblers(address(gobblers)), IERC20(address(goo)), feeRecipient);

        _mintGoo(address(this), type(uint128).max);
        goo.approve(address(stew), type(uint256).max);
        gobblers.setApprovalForAll(address(stew), true);

        // start with deposited gobblers to better reflect gas in tests
        uint256[] memory gobblerIds = new uint256[](MINTED_GOBBLERS);
        for (uint256 i = 0; i < gobblerIds.length; ++i) {
            gobblerIds[i] = gobblers.mintGobblerExposed(address(this), uint32(6 + (i % 3)));
        }
        stew.depositGobblers(gobblerIds);
        stew.depositGoo(10e18);

        // set contract into normal state: LAZY_MINT_ADDRESS balance, _gobblerSharesPerMultipleIndex, _sumMultiples not zero
        skip(1 days);
        stew.updateUser(address(this));

        skip(1 days); // let each test have to do an update which is the standard case
    }

    function testGetUserInfo() public view {
        (uint256[] memory gobblerIds, uint256 shares, uint32 sumMultiples, uint256 lastIndex) =
            stew.getUserInfo(address(this));
    }

    function testGetGlobalInfo() public view {
        (uint256 sharesTotalSupply, uint32 sumMultiples, uint64 lastUpdate, uint256 lastIndex, uint256 price) =
            stew.getGlobalInfo();
    }

    function testSharesPrice() public view {
        uint256 price = stew.sharesPrice();
    }

    function testBalanceOf() public view {
        uint256 amount = stew.balanceOf(address(this));
    }

    function testUpdate() public {
        stew.updateUser(address(this));
    }

    function testTransfer() public {
        stew.transfer(address(0x1), 1e18);
    }

    function testRedeemGooShares() public {
        stew.redeemGooShares(type(uint256).max);
    }

    function testRedeemGobbler() public {
        uint256[] memory gobblerIds = new uint256[](1);
        gobblerIds[0] = 1;
        uint256[] memory removalIndexes = new uint256[](1);
        removalIndexes[0] = 0;
        stew.redeemGobblers(removalIndexes, gobblerIds);
    }

    function testRedeemGobblers() public {
        uint256[] memory gobblerIds = new uint256[](10);
        uint256[] memory removalIndexes = new uint256[](gobblerIds.length);
        for (uint256 i = 0; i < gobblerIds.length; ++i) {
            removalIndexes[i] = (gobblerIds.length - 1) - i;
            gobblerIds[i] = removalIndexes[i] + 1; // ids are indexes shifted by 1
        }
        stew.redeemGobblers(removalIndexes, gobblerIds);
    }
}
