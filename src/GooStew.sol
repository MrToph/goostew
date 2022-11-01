// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// import "forge-std/console2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {LibString} from "solmate/utils/LibString.sol";
import {toDaysWadUnsafe} from "solmate/utils/SignedWadMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IGobblers} from "./IGobblers.sol";
import {Constants} from "./Constants.sol";
import {BoringBatchable} from "./BoringBatchable.sol";
import {LibGOO} from "./LibGOO.sol";
import {LibPackedArray} from "./LibPackedArray.sol";
import {ERC20} from "./ERC20.sol";

contract GooStew is ERC20, BoringBatchable, Constants {
    using LibString for uint256;
    using LibPackedArray for uint256[];
    using FixedPointMathLib for uint256;

    // accounting related
    string internal constant BASE_URI = "https://nft.goostew.com/";
    IGobblers internal immutable _gobblers;
    IERC20 internal immutable _goo;
    // all 3 in a single slot
    uint64 internal _lastUpdate; // last time _updateInflation (deposit/redeem) was called
    address public feeRecipient; // fee on the goo rewards, 1e18 = 100%
    uint32 public feeRate; // fee on the goo rewards, type(uint32).max = 100%

    // Goo related
    // @note we use ERC20._totalSupply as _totalShares
    uint256 internal _totalGoo; // includes deposited + earned inflation (for both gobblers and goo stakers)

    // Gobbler related
    struct GobblerDepositInfo {
        uint224 lastIndex;
        uint32 sumMultiples;
        uint256[] packedIds;
    }
    // shares * 1e18 / sumMultiples. shares is expected to be <= maxGooAmount ~ 2e30 => index <= 2e48 fits in 224 bits

    uint224 internal _gobblerSharesPerMultipleIndex;
    uint32 internal _sumMultiples; // sum of emissionMultiples of all deposited gobblers
    mapping(address => GobblerDepositInfo) public gobblerDeposits;

    constructor(address gobblers, address goo, address initialFeeRecipient)
        ERC20("Inflation-bearing Goo", "ibGOO", 18)
    {
        _gobblers = IGobblers(gobblers);
        _goo = IERC20(goo);
        // ArtGobblers.addGoo(uint256) does not require approvals, no allowance need to be given
        // ArtGobblers always has approval to take gobblers, no need to set

        feeRecipient = initialFeeRecipient;
        // feeRate is initially zero
    }

    /*//////////////////////////////////////////////////////////////
                        GOO INFLATION RELATED LOGIC
    //////////////////////////////////////////////////////////////*/
    modifier updateInflation() {
        _updateInflation();

        // goo is "staked" in _pullGoo, gobblers are "staked" in _pullGobblers
        _;
    }

    // @dev: defensive programming: this function is called before any gobbler redeems, therefore we'd rather have an unexpected overflow than an unexpected overflow revert due to checked math. (we treat the gobblers as more valuable than the goo in this contract.)
    function _updateInflation() internal {
        (
            bool requiresUpdate,
            uint256 newTotalGoo,
            uint256 newTotalShares,
            uint224 newGobblerSharesPerMultipleIndex,
            address feeReceiver,
            uint256 sharesAllocatedToFeeReceiver,
            uint256 rewardsGoo,
            uint256 rewardsGobblers,
            uint256 rewardsFee
        ) = _calculateUpdate();

        _lastUpdate = uint64(block.timestamp);
        if (!requiresUpdate) return;

        if (sharesAllocatedToFeeReceiver > 0) {
            // note: this sets totalSupply but we will overwrite it later. `totalShares` already includes `sharesAllocatedToFeeReceiver`
            _mint(feeReceiver, sharesAllocatedToFeeReceiver);
        }

        // set new values
        _totalGoo = newTotalGoo;
        _totalSupply = newTotalShares;
        _gobblerSharesPerMultipleIndex = newGobblerSharesPerMultipleIndex;

        emit InflationUpdate({
            timestamp: uint40(block.timestamp), // safe for human years
            rewardsGoo: rewardsGoo,
            rewardsGobblers: rewardsGobblers,
            rewardsFee: rewardsFee
        });
    }

    // if `requiresUpdate` is false, the other return variables are all zero
    function _calculateUpdate()
        internal
        view
        returns (
            bool requiresUpdate,
            uint256 newTotalGoo,
            uint256 newTotalShares,
            uint224 newGobblerSharesPerMultipleIndex,
            address feeReceiver,
            uint256 sharesAllocatedToFeeReceiver,
            uint256 rewardsGoo,
            uint256 rewardsGobblers,
            uint256 rewardsFee
        )
    {
        // load from same storage slot
        uint64 lastUpdate = _lastUpdate;
        feeReceiver = feeRecipient;
        uint32 feePercentage = feeRate;

        // if we updated this block, there won't be any new rewards
        if (lastUpdate != block.timestamp) {
            requiresUpdate = true;

            newTotalGoo = _totalGoo;
            newTotalShares = _totalSupply;

            // load from same storage slot
            newGobblerSharesPerMultipleIndex = _gobblerSharesPerMultipleIndex;
            uint32 sumMultiples = _sumMultiples;

            (rewardsGoo, rewardsGobblers, rewardsFee) = _calculateRewards({
                lastTotalGoo: newTotalGoo,
                lastUpdate: lastUpdate,
                sumMultiples: sumMultiples,
                feePercentage: feePercentage
            });

            // 1. update goo rewards: this updates _sharesPrice
            unchecked {
                // unchecked: rewardsGoo is derived from gooBalance() which is capped by maxGooAmount
                newTotalGoo += rewardsGoo;
            }

            // 2. update gobbler rewards
            // if there were no deposited gobblers, rewards should be zero anyway, can skip
            if (sumMultiples > 0) {
                // act as if we deposited rewardsGobblers for goo shares and distributed among current gobbler stakers
                // i.e., mint new goo shares with rewardsGobblers, keeping the _sharesPrice the same
                // we can assume that totalSupply > 0, i.e., fees turned on only after there's a goo deposit. saves 1 sload
                unchecked {
                    // unchecked: rewardsGobblers is derived from gooBalance() which is capped by maxGooAmount. mintShares is therefore also capped.
                    uint256 mintShares =
                        (rewardsGobblers * 1e18) / _sharesPrice({totalShares: newTotalShares, totalGoo: newTotalGoo});
                    newTotalGoo += rewardsGobblers;
                    // mintShares is rounded down, new shares price should never decrease because of a rounding error
                    // we're delay-allocating the new shares for _all_ users here without actually minting to an address
                    newTotalShares += mintShares; // update cached totalShares instead of reading totalSupply from storage
                    newGobblerSharesPerMultipleIndex += uint224((mintShares * 1e18) / sumMultiples);
                }
            }

            // 3. deposit rewardsFee goo amount for feeRecipient
            if (rewardsFee > 0) {
                unchecked {
                    // unchecked: rewardsFee is derived from gooBalance() which is capped by maxGooAmount. shares is therefore also capped.
                    // we can assume that totalSupply > 0, i.e., fees turned on only after there's a goo deposit. saves 1 sload
                    sharesAllocatedToFeeReceiver =
                        (rewardsFee * 1e18) / _sharesPrice({totalShares: newTotalShares, totalGoo: newTotalGoo});
                    newTotalGoo += rewardsFee;
                    newTotalShares += sharesAllocatedToFeeReceiver;
                }
            }
        }
    }

    function _calculateRewards(uint256 lastTotalGoo, uint64 lastUpdate, uint32 sumMultiples, uint32 feePercentage)
        internal
        view
        returns (uint256 rewardsGoo, uint256 rewardsGobblers, uint256 rewardsFee)
    {
        // unchecked: safe because we're using the exact same math as in `IGobblers(_gobblers).gooBalance(address(this))`.
        unchecked {
            // adversaries can compound us by triggering `updateUserGooBalance(gooStew)`, for example, in ArtGobblers._transferFrom
            // however, as g(t) is auto-compounding it doesn't change the final value computed here in `gooBalance()`
            // exception: someone adds goo or gobblers. goo cannot be added as `addGoo` always adds to `msg.sender`
            // gobblers can be added increasing our emissionMultiple. we would gain more goo than expected but
            // compute distribution on our snapshot, therefore no loss property is correct. excess would go to gobblers

            // newTotalGoo = g(t, M, GOO) = t^2 / 4 * M + t * sqrt(M * GOO) + GOO
            // where M = sumMultiples, GOO = lastTotalGoo
            uint256 newTotalGoo = _gobblers.gooBalance(address(this));

            uint256 timeElapsedWad = uint256(toDaysWadUnsafe(block.timestamp - lastUpdate));
            // uint256 recomputedNewTotalGoo = LibGOO.computeGOOBalance(
            //     _sumMultiples,
            //     lastTotalGoo,
            //     timeElapsedWad
            // );

            // timeSqrtMGOO = t * sqrt(M*GOO)
            uint256 timeSqrtMGOO =
                newTotalGoo - lastTotalGoo - ((sumMultiples * timeElapsedWad.mulWadDown(timeElapsedWad)) >> 2);
            // rewardsGoo = t * sqrt(M*GOO) / 2
            rewardsGoo = timeSqrtMGOO / 2;
            // rewardsGobblers = t^2 * M + t * sqrt(M*GOO) / 2 = g(t, M, GOO) - GOO - rewardsGoo
            rewardsGobblers = newTotalGoo - lastTotalGoo - rewardsGoo;

            rewardsFee = (rewardsGoo * feePercentage) / type(uint32).max;
            rewardsGoo -= rewardsFee;
        }
    }

    /// anyone can update anyone
    function updateUser(address user) external updateInflation {
        _updateUser(user);
    }

    function _updateUser(address user) internal {
        // accrue user's gobbler inflation: (diff of inflation / totalMultiple) * stakingMultiple
        // these tokens have already been minted in `_updateInflation`.
        uint224 currentGlobalIndex = _gobblerSharesPerMultipleIndex;
        uint224 lastUserIndex = gobblerDeposits[user].lastIndex;
        // early exit if already updated
        if (currentGlobalIndex == lastUserIndex) return;

        uint256 userSumMultiples = gobblerDeposits[user].sumMultiples;
        uint256 shares = _computeUnmintedShares(currentGlobalIndex, lastUserIndex, userSumMultiples);
        gobblerDeposits[user].lastIndex = currentGlobalIndex;
        if (shares > 0) {
            _delayMint(user, shares);
        }
    }

    function _computeUnmintedShares(uint224 currentGlobalIndex, uint224 lastUserIndex, uint256 userSumMultiples)
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
        // short-circuit as most ibGoo holders didn't deposit a gobbler and are therefore not delay-minted any additional shares
        if (userSumMultiples == 0) {
            return _balanceOf[account];
        }

        (bool requiresUpdate,,, uint224 newGobblerSharesPerMultipleIndex,,,,,) = _calculateUpdate();

        if (!requiresUpdate) {
            newGobblerSharesPerMultipleIndex = _gobblerSharesPerMultipleIndex;
        }

        return _balanceOf[account]
            + _computeUnmintedShares(newGobblerSharesPerMultipleIndex, gobblerDeposits[account].lastIndex, userSumMultiples);
    }

    function _beforeTokenTransfer(address from, address, /* to */ uint256 /* amount */ ) internal virtual override {
        // as `balanceOf` reflects an optimistic balance, we need to update `from` here s.t. users can transfer entire balance.
        // `to` does not need to be updated because correctness of user's inflation update logic is based only on gobbler emissionMultiple, not on balance
        // we can also skip updating shares balance if `from` does not have any deposited gobblers. not updating `gobblerDeposits[from].lastIndex` in this case is okay because it is always updated before any gobblers are deposited. i.e., it is always updated before changing `sumMultiples`. `updateInflation` must only be called when user's `sumMultiples` changes
        if (gobblerDeposits[from].sumMultiples > 0) {
            _updateInflation();
            _updateUser(from);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSITS & REDEEMS
    //////////////////////////////////////////////////////////////*/
    function depositGobblers(uint256[] calldata gobblerIds)
        external
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
                uint256 gobblerMultiple = _gobblers.getGobblerEmissionMultiple(gobblerIds[i]);
                // revealing a gobbler changes its emissionMultiple but we don't update the user's sumMultiples on reveal.
                // disallow unrevealed gobbler deposits
                if (gobblerMultiple == 0) revert UnrevealedGobblerDeposit(gobblerIds[i]);
                // no overflow as uint32 is the same type ArtGobblers uses
                sumMultiples += uint32(gobblerMultiple);
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

    function depositGoo(uint256 amount) external updateInflation returns (uint256 shares) {
        _updateUser(msg.sender);

        // FullMath not required, max goo amount after 20 years is ~2e30
        shares = (amount * 1e18) / _sharesPrice();
        if (_totalSupply == 0) {
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
    function redeemGobblers(uint256[] calldata removalIndexesDescending, uint256[] calldata expectedGobblerIds)
        external
        updateInflation
    {
        _updateUser(msg.sender);

        uint32 sumMultiples = 0;
        unchecked {
            for (uint256 i = 0; i < expectedGobblerIds.length; ++i) {
                // no overflow as uint32 is the same type ArtGobblers uses
                sumMultiples += uint32(_gobblers.getGobblerEmissionMultiple(expectedGobblerIds[i]));
            }
        }

        // expectedGobblerIds does not contain duplicates as `_pushGobblers` would fail. remove is safe
        // remove fails if an id is not in packedIds
        gobblerDeposits[msg.sender].packedIds.remove(removalIndexesDescending, expectedGobblerIds);
        gobblerDeposits[msg.sender].sumMultiples -= sumMultiples;
        _sumMultiples -= sumMultiples;

        _pushGobblers(msg.sender, expectedGobblerIds);
    }

    function redeemGooShares(uint256 shares) external updateInflation returns (uint256 gooAmount) {
        _updateUser(msg.sender);
        // can directly read from _balanceOf instead of balanceOf() as it has been accrued in `_updateUser`
        if (shares == type(uint256).max) shares = _balanceOf[msg.sender];
        gooAmount = (shares * _sharesPrice()) / 1e18; // rounding down is correct

        _burn(msg.sender, shares);
        _totalGoo -= gooAmount;

        _pushGoo(msg.sender, gooAmount);
    }

    /// @dev goo shares price denominated in goo: totalGoo * 1e18 / totalShares
    function _sharesPrice() internal view returns (uint256) {
        return _sharesPrice({totalShares: _totalSupply, totalGoo: _totalGoo});
    }

    function _sharesPrice(uint256 totalShares, uint256 totalGoo) internal pure returns (uint256) {
        // when every goo share is redeemed this would reset and might cause issues for gobbler staking which also uses the goo price
        // but not all shares can ever be withdrawn because we minted MIN_GOO_SHARES_INITIAL_MINT to a dead address
        if (totalShares == 0) return 1e18;
        return (totalGoo * 1e18) / totalShares;
    }

    /// @dev also adds `amount` to our virtual goo balance in ArtGobblers
    function _pullGoo(uint256 amount) internal {
        _goo.transferFrom(msg.sender, address(this), amount);
        // always store all received goo in ArtGobblers as a virtual balance. this contract never holds any goo except by users doing direct transfers
        _gobblers.addGoo(amount);
    }

    function _pushGoo(address to, uint256 amount) internal {
        // defensive programming, should never happen that we miscalculated. but in unforseen issues, we don't want to revert and just withdraw what we can
        uint256 gooBalance = IGobblers(_gobblers).gooBalance(address(this));
        uint256 toTransfer = gooBalance < amount ? gooBalance : amount;
        _gobblers.removeGoo(toTransfer);
        _goo.transfer(to, toTransfer);
    }

    /// @dev reverts on duplicates in `gobblerIds` or if gobbler cannot be transferred from msg.sender
    function _pullGobblers(uint256[] memory gobblerIds) internal {
        unchecked {
            for (uint256 i = 0; i < gobblerIds.length; ++i) {
                // also "stakes" these gobblers to ArtGobblers, we gain their emissionMultiples
                _gobblers.transferFrom(msg.sender, address(this), gobblerIds[i]);
            }
        }
    }

    function _pushGobblers(address to, uint256[] memory gobblerIds) internal {
        unchecked {
            for (uint256 i = 0; i < gobblerIds.length; ++i) {
                // this also accrues inflation for us and
                // "unstakes" them from ArtGobblers, we lose the emissionMultiples
                // no `safeTransferFrom` because if you call this function we expect you can handle receiving the NFT (to == msg.sender)
                _gobblers.transferFrom(address(this), to, gobblerIds[i]);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FEE LOGIC
    //////////////////////////////////////////////////////////////*/
    function setFeeRecipient(address recipient)
        external
        updateInflation // update first s.t. fees until now are given to old recipient
    {
        if (msg.sender != feeRecipient) revert Unauthorized();
        feeRecipient = recipient;
    }

    function setFeeRate(uint32 rate)
        external
        updateInflation // update first s.t. old fees are applied on rewards up until now
    {
        if (msg.sender != feeRecipient) revert Unauthorized();
        if (rate > type(uint32).max / 10) revert InvalidArguments(); // max fee is 10%
        feeRate = rate;
    }

    /*//////////////////////////////////////////////////////////////
                        UTILITY VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getUserInfo(address user)
        external
        view
        returns (uint256[] memory gobblerIds, uint256 shares, uint32 sumMultiples, uint256 lastIndex)
    {
        shares = balanceOf(user);
        gobblerIds = gobblerDeposits[user].packedIds.getValues();
        sumMultiples = gobblerDeposits[user].sumMultiples;
        lastIndex = gobblerDeposits[user].lastIndex;
    }

    function getGlobalInfo()
        external
        view
        returns (uint256 sharesTotalSupply, uint32 sumMultiples, uint64 lastUpdate, uint256 lastIndex, uint256 price)
    {
        sharesTotalSupply = _totalSupply;
        sumMultiples = _sumMultiples;
        lastUpdate = _lastUpdate;
        lastIndex = _gobblerSharesPerMultipleIndex;
        price = _sharesPrice();
    }

    /// @notice returns the ibGOO price (denominated in goo)
    /// @return price Goo per ibGoo computed as totalGooAmount * 1e18 / totalSupply
    function sharesPrice() external view returns (uint256 price) {
        price = _sharesPrice();
    }
}
