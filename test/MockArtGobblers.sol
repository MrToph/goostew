// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Goo} from "art-gobblers.git/Goo.sol";
import {ArtGobblers} from "art-gobblers.git/ArtGobblers.sol";
import {Pages} from "art-gobblers.git/Pages.sol";
import {RandProvider} from "art-gobblers.git/utils/rand/RandProvider.sol";

contract MockArtGobblers is ArtGobblers {
    constructor(
        // Mint config:
        bytes32 _merkleRoot,
        uint256 _mintStart,
        // Addresses:
        Goo _goo,
        Pages _pages,
        address _team,
        address _community,
        RandProvider _randProvider,
        // URIs:
        string memory _baseUri,
        string memory _unrevealedUri
    )
        ArtGobblers(_merkleRoot, _mintStart, _goo, _pages, _team, _community, _randProvider, _baseUri, _unrevealedUri)
    {}

    /// acts like calling `claimGobbler` + `revealGobblers(1)` + sets custom emission multiple
    function mintGobblerExposed(uint32 emissionMultiple) external returns (uint256 gobblerId) {
        gobblerId = ++currentNonLegendaryId;
        _mint(msg.sender, gobblerId);
        gobblerRevealsData.waitingForSeed = false;
        gobblerRevealsData.toBeRevealed = uint56(1);
        gobblerRevealsData.lastRevealedId = uint56(gobblerId - 1);
        this.revealGobblers(1);

        getUserData[msg.sender].emissionMultiple -= uint32(getGobblerData[gobblerId].emissionMultiple);
        getGobblerData[gobblerId].emissionMultiple = emissionMultiple;
        getUserData[msg.sender].emissionMultiple += uint32(getGobblerData[gobblerId].emissionMultiple);
    }
}
