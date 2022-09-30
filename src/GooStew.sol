// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// import "forge-std/console2.sol";
import {ERC1155, ERC1155TokenReceiver} from "solmate/tokens/ERC1155.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {LibString} from "solmate/utils/LibString.sol";
import {toDaysWadUnsafe} from "solmate/utils/SignedWadMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Constants} from "./Constants.sol";
import {LibGOO} from "./LibGOO.sol";
import {IGobblers} from "./IGobblers.sol";

contract GooStew is ERC1155, ERC1155TokenReceiver, Constants {
    using LibString for uint256;
    using FixedPointMathLib for uint256;

    // accounting related
    string internal constant BASE_URI = "https://nft.goostew.com/";
    address internal immutable _gobblers;
    address internal immutable _goo;
    uint256 internal _ENTERED = 1;
    uint256 internal _lastUpdate; // last time _updateInflation (deposit/redeem) was called

    // Goo related
    uint256 internal _totalSharesGoo;
    uint256 internal _totalGoo; // includes deposited + earned inflation (for both gobblers and goo stakers)

    // Gobbler related
    struct GobblerStaking {
        uint256 lastIndex;
    }

    mapping(uint256 => GobblerStaking) public gobblerStakingMap;
    uint256 internal _gobblerSharesPerMultipleIndex = 0;
    uint32 internal _sumMultiples; // sum of emissionMultiples of all deposited gobblers

    constructor(address gobblers, address goo) {
        _gobblers = gobblers;
        _goo = goo;
        IERC20(goo).approve(gobblers, type(uint256).max);
        // ArtGobblers always has approval to take gobblers, no need to set
    }

    modifier updateInflation() {
        _updateInflation();

        // goo is "staked" in _pullGoo, gobblers are "staked" in _pullGobblers
        _;
    }

    modifier noReenter() {
        if (_ENTERED != 1) revert Reentered();
        _ENTERED = 2;
        _;
        _ENTERED = 1;
    }

    function _updateInflation() internal {
        // if we updated this block, there won't be any new rewards. can exit early
        if (_lastUpdate == block.timestamp) return;

        (, uint256 rewardsGoo, uint256 rewardsGobblers) = _calculateUpdate();

        // 1. update goo rewards: this updates _gooSharesPrice
        _totalGoo += rewardsGoo;

        // 2. update gobbler rewards
        // if there were no deposited gobblers, rewards should be zero anyway, can skip
        if (_sumMultiples > 0) {
            // act as if we deposited rewardsGobblers for goo shares and distributed among current gobbler stakers
            // i.e., mint new goo shares with rewardsGobblers, keeping the _gooSharesPrice the same
            uint256 mintShares = (rewardsGobblers * 1e18) / _gooSharesPrice();
            _totalGoo += rewardsGobblers;
            // mintShares is rounded down, new shares price should never decrease because of a rounding error
            _totalSharesGoo += mintShares;
            _gobblerSharesPerMultipleIndex += (mintShares * 1e18) / _sumMultiples;
        }

        _lastUpdate = block.timestamp;
    }

    function deposit(uint256[] calldata gobblerIds, uint256 gooAmount)
        external
        noReenter
        updateInflation
        returns (
            uint256 gobblerStakingId,
            // acts as "gobblerShares", proportional to total _sumMultiples
            uint32 gobblerSumMultiples,
            uint256 gooShares
        )
    {
        if (gobblerIds.length > 0) {
            (gobblerStakingId, gobblerSumMultiples) = _depositGobblers(msg.sender, gobblerIds);
            // when pulling gobblers, the goo in tank stays at `from` and is not given to us
            // and our emissionMultiple is automatically updated, earning the new rate
            _pullGobblers(gobblerIds);
            emit DepositGobblers(msg.sender, gobblerStakingId, gobblerIds, gobblerSumMultiples);
        }

        if (gooAmount > 0) {
            gooShares = _depositGoo(msg.sender, gooAmount);
            // _pullGoo also adds the gooAmount to ArtGobblers to earn goo inflation
            _pullGoo(gooAmount);
            emit DepositGoo(msg.sender, gooAmount, gooShares);
        }
    }

    function _depositGoo(address to, uint256 amount) internal returns (uint256 shares) {
        // TODO: do we need FullMath everywhere because goo amount can easily be >= 1e59? ArtGobblers also does not use FullMath but do they * 1e18 anywhere?
        shares = (amount * 1e18) / _gooSharesPrice();
        if (_totalSharesGoo == 0) {
            // we send some tokens to the burn address to ensure gooSharePrice is never decreaasing (as it can't be reset by redeeming all shares)
            _mint(BURN_ADDRESS, GOO_SHARES_ID, MIN_GOO_SHARES_INITIAL_MINT, "");
            _totalSharesGoo += MIN_GOO_SHARES_INITIAL_MINT;
            shares -= MIN_GOO_SHARES_INITIAL_MINT;
        }
        _totalGoo += amount;
        _totalSharesGoo += shares;
        // note: gives control to `to`
        _mint(to, GOO_SHARES_ID, shares, "");
    }

    function _depositGobblers(address to, uint256[] calldata gobblerIds)
        internal
        returns (uint256 stakingId, uint32 sumMultiples)
    {
        unchecked {
            for (uint256 i = 0; i < gobblerIds.length; i++) {
                // no overflow as uint32 is the same type ArtGobblers uses
                sumMultiples += uint32(IGobblers(_gobblers).getGobblerEmissionMultiple(gobblerIds[i]));
            }
        }
        // this is a not yet seen staking id as it includes gobblerIds[0], which is ensured to be owned by msg.sender and not us
        stakingId = _encodeStakingId(keccak256(abi.encodePacked(gobblerIds)), sumMultiples);

        gobblerStakingMap[stakingId].lastIndex = _gobblerSharesPerMultipleIndex; // was updated before this call
        _sumMultiples += sumMultiples;

        // note: gives control to `to`
        _mint(to, stakingId, 1, "");
    }

    function redeemGooShares(uint256 shares) external noReenter updateInflation returns (uint256 gooAmount) {
        gooAmount = (shares * _gooSharesPrice()) / 1e18; // rounding down is correct

        _burn(msg.sender, GOO_SHARES_ID, shares);
        _totalSharesGoo -= shares;
        _totalGoo -= gooAmount;

        _pushGoo(msg.sender, gooAmount);
    }

    /// redeems all gobblers in the stakingId and redeems any accrued goo shares from the staking NFT
    function redeemGobblers(uint256 stakingId, uint256[] calldata gobblerIds)
        external
        noReenter
        updateInflation
        returns (uint256 gooAmount)
    {
        // make sure this is actually a stakingId and not the goo shares token
        if (stakingId < GOBBLER_STAKING_ID_START) revert InvalidStakingId();

        // the owner of the NFT can redeem its gobblers
        if (balanceOf[msg.sender][stakingId] != 1) revert Unauthorized();
        // check if the provided `gobblerIds` args are indeed the gobblers associated with the stakingId
        // the sumMultiples is also authentic as its directly part of the tokenId and the user owns this tokenId. (i.e., we issued it at some point, thus authentic)
        uint32 sumMultiples = _decodeStakingIdAndVerify(stakingId, keccak256(abi.encodePacked(gobblerIds)));

        // (diff of inflation / totalMultiple) * stakingMultiple
        // do an imaginary "lazy mint" to the user. these tokens have already been minted (totalSupply increased) in _updateInflation. no need to call _burn
        uint256 gooShares =
            ((_gobblerSharesPerMultipleIndex - gobblerStakingMap[stakingId].lastIndex) * sumMultiples) / 1e18;
        if (gooShares > 0) {
            gooAmount = (gooShares * _gooSharesPrice()) / 1e18;
            _totalGoo -= gooAmount;
            _totalSharesGoo -= gooShares;
        }

        // redeeming destroys the NFT
        _burn(msg.sender, stakingId, 1);
        delete gobblerStakingMap[stakingId];
        _sumMultiples -= sumMultiples;

        _pushGoo(msg.sender, gooAmount);
        _pushGobblers(msg.sender, gobblerIds);
    }

    /// @dev goo shares price denominated in goo: totalGoo * 1e18 / totalShares
    function _gooSharesPrice() internal view returns (uint256) {
        // when every goo share is redeemed this would reset and might cause issues for gobbler staking which also uses the goo price
        // but not all shares can ever be withdrawn because we minted MIN_GOO_SHARES_INITIAL_MINT to a dead address
        if (_totalSharesGoo == 0) return 1e18;
        return (_totalGoo * 1e18) / _totalSharesGoo;
    }

    /// @dev stakingId is unique as it contains gobblerIds[0] which can only be deposited once, redeeming destroys the stakingId
    function _encodeStakingId(bytes32 gobblerIdsHash, uint32 sumMultiples) internal pure returns (uint256 id) {
        // store part of the hash (224 bits) in the upper bits and sumMultiples in lower 32 bits
        // 224bits of the hash are enough to still be collision-resistant and enforce that gobblerIds match
        return (uint256(gobblerIdsHash) & ~uint256(type(uint32).max)) | sumMultiples;
    }

    function _decodeStakingIdAndVerify(uint256 stakingId, bytes32 expectedGobblerIdsHash)
        internal
        pure
        returns (uint32 sumMultiples)
    {
        // a == b iff a xor b == 0. we use this to check equality of the upper 224 bits (`gobblerIdsHash`).
        if ((stakingId ^ uint256(expectedGobblerIdsHash)) >> 32 != 0) {
            revert MismatchedGobblers();
        }
        // `sumMultiples` is in the lower 32 bits
        sumMultiples = uint32(stakingId);
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

    function uri(uint256 id) public view virtual override returns (string memory) {
        return string.concat(BASE_URI, uint256(id).toString());
    }
}
