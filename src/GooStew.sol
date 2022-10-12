// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// import "forge-std/console2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {LibString} from "solmate/utils/LibString.sol";
import {toDaysWadUnsafe} from "solmate/utils/SignedWadMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Constants} from "./Constants.sol";
import {LibGOO} from "./LibGOO.sol";
import {LibPackedArray} from "./LibPackedArray.sol";
import {IGobblers} from "./IGobblers.sol";
import {ERC20} from "./ERC20.sol";

contract GooStew is ERC20, Constants {
    using LibString for uint256;
    using LibPackedArray for uint256[];
    using FixedPointMathLib for uint256;

    // accounting related
    string internal constant BASE_URI = "https://nft.goostew.com/";
    address internal immutable _gobblers;
    address internal immutable _goo;
    uint256 internal _ENTERED = 1;
    uint256 internal _lastUpdate; // last time _updateInflation (deposit/redeem) was called

    // Goo related
    // @note we use ERC20.totalSupply as _totalShares
    uint256 internal _totalGoo; // includes deposited + earned inflation (for both gobblers and goo stakers)

    // Gobbler related
    struct GobblerDepositInfo {
        uint256 lastIndex;
        uint256[] packedIds;
        uint32 sumMultiples;
    }

    mapping(address => GobblerDepositInfo) public gobblerDeposits;
    uint256 internal _gobblerSharesPerMultipleIndex;
    uint32 internal _sumMultiples; // sum of emissionMultiples of all deposited gobblers

    constructor(address gobblers, address goo) ERC20("Inflation-bearing Goo", "ibGOO", 18) {
        _gobblers = gobblers;
        _goo = goo;
        IERC20(goo).approve(gobblers, type(uint256).max);
        // ArtGobblers always has approval to take gobblers, no need to set
    }

    modifier noReenter() {
        if (_ENTERED != 1) revert Reentered();
        _ENTERED = 2;
        _;
        _ENTERED = 1;
    }

    /*//////////////////////////////////////////////////////////////
                        GOO INFLATION RELATED LOGIC
    //////////////////////////////////////////////////////////////*/
    modifier updateInflation() {
        _updateInflation();

        // goo is "staked" in _pullGoo, gobblers are "staked" in _pullGobblers
        _;
    }

    function _updateInflation() internal {
        // if we updated this block, there won't be any new rewards. can exit early
        if (_lastUpdate == block.timestamp) return;

        (, uint256 rewardsGoo, uint256 rewardsGobblers) = _calculateUpdate();
        _lastUpdate = block.timestamp; // update can now be set as following functions don't use it anymore

        // 1. update goo rewards: this updates _sharesPrice
        _totalGoo += rewardsGoo;

        // 2. update gobbler rewards
        // if there were no deposited gobblers, rewards should be zero anyway, can skip
        if (_sumMultiples > 0) {
            // act as if we deposited rewardsGobblers for goo shares and distributed among current gobbler stakers
            // i.e., mint new goo shares with rewardsGobblers, keeping the _sharesPrice the same
            uint256 mintShares = (rewardsGobblers * 1e18) / _sharesPrice();
            _totalGoo += rewardsGobblers;
            // mintShares is rounded down, new shares price should never decrease because of a rounding error
            _mint(LAZY_MINT_ADDRESS, mintShares);
            _gobblerSharesPerMultipleIndex += (mintShares * 1e18) / _sumMultiples;
        }

    }

    function _calculateUpdate()
        internal
        view
        returns (uint256 newTotalGoo, uint256 rewardsGoo, uint256 rewardsGobblers)
    {
        // other people can compound us by triggering `updateUserGooBalance(gooStew)`, for example, in ArtGobblers._transferFrom
        // however, as g(t) is auto-compounding it doesn't change the final value computed here in `gooBalance()`
        // exception: someone adds goo or gobblers. goo cannot be added as `addGoo` always adds to `msg.sender`
        // gobblers can be added increasing our emissionMultiple.
        // TODO: how much of an issue is this? in practice, we would gain more goo than expected but compute distribution on our snapshot. excess would go to gobblers. worst case, can just deploy the contract again, tell people to migrate, and griefer lost a gobbler

        // newTotalGoo = g(t, M, GOO) = t^2 / 4 + t * sqrt(_sumMultiples * lastTotalGoo) + lastTotalGoo
        newTotalGoo = IGobblers(_gobblers).gooBalance(address(this));

        uint256 lastTotalGoo = _totalGoo;
        uint256 timeElapsedWad = uint256(toDaysWadUnsafe(block.timestamp - _lastUpdate));
        // uint256 recomputedNewTotalGoo = LibGOO.computeGOOBalance(
        //     _sumMultiples,
        //     lastTotalGoo,
        //     timeElapsedWad
        // );

        // rewardsGoo = t * sqrt(M*GOO) / 2
        rewardsGoo = timeElapsedWad.mulWadDown((_sumMultiples * lastTotalGoo * 1e18).sqrt()) / 2;
        // rewardsGobblers = t^2 * M + t * sqrt(M*GOO) / 2 = g(t, M, GOO) - GOO - rewardsGoo
        rewardsGobblers = newTotalGoo - lastTotalGoo - rewardsGoo;
    }

    /// anyone can update anyone
    function updateUser(address user) external updateInflation {
        _updateUser(user);
    }

    function _updateUser(address user) internal {
        // accrue user's gobbler inflation: (diff of inflation / totalMultiple) * stakingMultiple
        // these tokens have already been minted in `_updateInflation`.
        uint256 currentGlobalIndex = _gobblerSharesPerMultipleIndex;
        uint256 lastUserIndex = gobblerDeposits[user].lastIndex;
        // early exit if already updated
        if (currentGlobalIndex == lastUserIndex) return;

        uint256 userSumMultiples = gobblerDeposits[user].sumMultiples;
        uint256 shares = _computeUnmintedShares(currentGlobalIndex, lastUserIndex, userSumMultiples);
        gobblerDeposits[user].lastIndex = currentGlobalIndex;
        if (shares > 0) {
            _transfer(LAZY_MINT_ADDRESS, user, shares);
        }
    }

    function _computeUnmintedShares(uint256 currentGlobalIndex, uint256 lastUserIndex, uint256 userSumMultiples)
        internal
        pure
        returns (uint256 shares)
    {
        // works for first deposit as `gobblerDeposits[user].sumMultiples` is zero and thus gooShares = 0
        shares = ((currentGlobalIndex - lastUserIndex) * userSumMultiples) / 1e18;
    }

    /// @notice Returns the user's accrued ibGoo balance up to the last time the contract's inflation update was triggered
    function balanceOf(address account) public view virtual override returns (uint256) {
        // gobbler depositors earn ibGoo on every update inflation, account for that
        uint256 userSumMultiples = gobblerDeposits[account].sumMultiples;
        // short-circuit as most ibGoo holders didn't deposit a gobbler and are therefore not lazy-minted any additional shares
        if (userSumMultiples == 0) {
            return _balanceOf[account];
        }
        return _balanceOf[account]
            + _computeUnmintedShares(_gobblerSharesPerMultipleIndex, gobblerDeposits[account].lastIndex, userSumMultiples);
    }

    function _beforeTokenTransfer(address from, address /* to */, uint256 /* amount */) internal virtual override {
        // as `balanceOf` reflects an optimistic balance, we need to update `from` here s.t. users can transfer entire balance.
        // `to` does not need to be updated because correctness of user's inflation update logic is based only on gobbler emissionMultiple, not on balance
        _updateInflation();
        _updateUser(from);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSITS & REDEEMS
    //////////////////////////////////////////////////////////////*/
    function depositGobblers(uint256[] calldata gobblerIds)
        external
        noReenter
        updateInflation
        returns (
            // sum of gobblerIds emissionMultiples. acts as "gobblerShares", proportional to total _sumMultiples
            uint32 sumMultiples
        )
    {
        _updateUser(msg.sender);

        if (gobblerIds.length == 0) revert InvalidArguments();

        unchecked {
            for (uint256 i = 0; i < gobblerIds.length; i++) {
                // no overflow as uint32 is the same type ArtGobblers uses
                sumMultiples += uint32(IGobblers(_gobblers).getGobblerEmissionMultiple(gobblerIds[i]));
            }
        }

        // gobblerIds does not contain duplicates as `_pullGobblers` would fail. `add` is safe
        gobblerDeposits[msg.sender].packedIds.add(gobblerIds);
        gobblerDeposits[msg.sender].sumMultiples += sumMultiples;
        _sumMultiples += sumMultiples;
        // when pulling gobblers, the goo in tank stays at `from` and is not given to us
        // and our emissionMultiple is automatically updated, earning the new rate
        _pullGobblers(gobblerIds);
        emit DepositGobblers(msg.sender, gobblerIds, sumMultiples);
    }

    function depositGoo(uint256 amount) external noReenter updateInflation returns (uint256 shares) {
        _updateUser(msg.sender);

        // TODO: do we need FullMath everywhere because goo amount can easily be >= 1e59? ArtGobblers also does not use FullMath but do they * 1e18 anywhere?
        shares = (amount * 1e18) / _sharesPrice();
        if (totalSupply == 0) {
            // we send some tokens to the burn address to ensure gooSharePrice is never decreaasing (as it can't be reset by redeeming all shares)
            _mint(BURN_ADDRESS, MIN_GOO_SHARES_INITIAL_MINT);
            shares -= MIN_GOO_SHARES_INITIAL_MINT;
        }
        _totalGoo += amount;
        _mint(msg.sender, shares);

        // _pullGoo also adds the amount to ArtGobblers to earn goo inflation
        _pullGoo(amount);
        emit DepositGoo(msg.sender, amount, shares);
    }

    /// redeems all gobblers of the caller
    function redeemGobblers(uint256[] calldata removalIndexesDescending, uint256[] calldata expectedGobblerIds) external noReenter updateInflation {
        _updateUser(msg.sender);

        uint32 sumMultiples = 0;
        unchecked {
            for (uint256 i = 0; i < expectedGobblerIds.length; i++) {
                // no overflow as uint32 is the same type ArtGobblers uses
                sumMultiples += uint32(IGobblers(_gobblers).getGobblerEmissionMultiple(expectedGobblerIds[i]));
            }
        }

        // expectedGobblerIds does not contain duplicates as `_pushGobblers` would fail. remove is safe
        // remove fails if an id is not in packedIds
        gobblerDeposits[msg.sender].packedIds.remove(removalIndexesDescending, expectedGobblerIds);
        gobblerDeposits[msg.sender].sumMultiples -= sumMultiples;
        _sumMultiples -= sumMultiples;

        _pushGobblers(msg.sender, expectedGobblerIds);
    }

    function redeemGooShares(uint256 shares) external noReenter updateInflation returns (uint256 gooAmount) {
        _updateUser(msg.sender);
        // can directly read from _balanceOf instead of balanceOf as it has been accrued in `_updateUser`
        if (shares == type(uint256).max) shares = _balanceOf[msg.sender];
        gooAmount = (shares * _sharesPrice()) / 1e18; // rounding down is correct

        _burn(msg.sender, shares);
        _totalGoo -= gooAmount;

        _pushGoo(msg.sender, gooAmount);
    }


    /// @dev goo shares price denominated in goo: totalGoo * 1e18 / totalShares
    function _sharesPrice() internal view returns (uint256) {
        // when every goo share is redeemed this would reset and might cause issues for gobbler staking which also uses the goo price
        // but not all shares can ever be withdrawn because we minted MIN_GOO_SHARES_INITIAL_MINT to a dead address
        if (totalSupply == 0) return 1e18;
        return (_totalGoo * 1e18) / totalSupply;
    }

    /// @dev also adds `amount` to our virtual goo balance in ArtGobblers
    function _pullGoo(uint256 amount) internal {
        IERC20(_goo).transferFrom(msg.sender, address(this), amount);
        // always store all received goo in ArtGobblers as a virtual balance. this contract never holds any goo except by users doing direct transfers
        IGobblers(_gobblers).addGoo(amount);
    }

    function _pushGoo(address to, uint256 amount) internal {
        // defensive programming, should never happen that we miscalculated. but in unforseen issues, we don't want to revert and just withdraw what we can
        uint256 gooBalance = IGobblers(_gobblers).gooBalance(address(this));
        uint256 toTransfer = gooBalance < amount ? gooBalance : amount;
        IGobblers(_gobblers).removeGoo(toTransfer);
        IERC20(_goo).transfer(to, toTransfer);
    }

    /// @dev reverts on duplicates in `gobblerIds` or if gobbler cannot be transferred from msg.sender
    function _pullGobblers(uint256[] memory gobblerIds) internal {
        unchecked {
            for (uint256 i = 0; i < gobblerIds.length; i++) {
                // also "stakes" these gobblers to ArtGobblers, we gain their emissionMultiples
                IERC721(_gobblers).transferFrom(msg.sender, address(this), gobblerIds[i]);
            }
        }
    }

    function _pushGobblers(address to, uint256[] memory gobblerIds) internal {
        unchecked {
            for (uint256 i = 0; i < gobblerIds.length; i++) {
                // this also accrues inflation for us and
                // "unstakes" them from ArtGobblers, we lose the emissionMultiples
                // no `safeTransferFrom` because if you call this function we expect you can handle receiving the NFT (to == msg.sender)
                IERC721(_gobblers).transferFrom(address(this), to, gobblerIds[i]);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getUserInfo(address user) external view returns (uint256[] memory gobblerIds, uint256 shares, uint32 sumMultiples, uint256 lastIndex) {
        shares = balanceOf(user);
        gobblerIds = gobblerDeposits[user].packedIds.getValues();
        sumMultiples = gobblerDeposits[user].sumMultiples;
        lastIndex = gobblerDeposits[user].lastIndex;
    }

    function getGlobalInfo() external view returns (uint256 sharesTotalSupply, uint32 sumMultiples, uint64 lastUpdate, uint256 lastIndex, uint256 price) {
        sharesTotalSupply = totalSupply;
        sumMultiples = _sumMultiples;
        lastUpdate = uint64(_lastUpdate);
        lastIndex = _gobblerSharesPerMultipleIndex;
        price = _sharesPrice();
    }

    /// @notice returns the ibGOO price (denominated in goo)
    /// @return price Goo per ibGoo computed as totalGooAmount * 1e18 / totalSupply
    function sharesPrice() external view returns (uint256 price) {
        price = _sharesPrice();
    }
}
