// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/utils/introspection/ERC165Storage.sol";
import "./interfaces/IMultiRoyalty.sol";

abstract contract PerTokenRoyalties is IMultiRoyalty, ERC165Storage {
    struct RoyaltyInfo {
        address receiver;
        uint8 percentage;
    }

    uint256 internal _maxRoyaltyPercentage;
    mapping(uint256 => RoyaltyInfo[]) internal _royalties;

    uint256 constant MAX_ROYALTY_PERCENTAGE = 50;

    constructor() {
        _maxRoyaltyPercentage = MAX_ROYALTY_PERCENTAGE;
    }

    function setMaxRoyaltyPercentage(uint256 percentage) public {
        _maxRoyaltyPercentage = percentage;
    }

    function _setTokenRoyalties(
        uint256 tokenId,
        address payable[] memory royaltyAddresses,
        uint256[] memory royaltyPercentages
    ) internal {
        require(
            royaltyAddresses.length == royaltyPercentages.length,
            "Royalty percentages and addresses count should be the same"
        );

        uint totalRoyaltyPercentage;
        for (uint256 i = 0; i < royaltyAddresses.length; i++) {
            _royalties[tokenId].push(RoyaltyInfo(royaltyAddresses[i], uint8(royaltyPercentages[i])));
            totalRoyaltyPercentage += royaltyPercentages[i];
        }

        require(totalRoyaltyPercentage <= MAX_ROYALTY_PERCENTAGE, "Maximum royalty percentage reached");
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = address(0);
        royaltyAmount = 0;
        RoyaltyInfo[] storage royalties = _royalties[tokenId];
        if (royalties.length > 0) {
            receiver = royalties[0].receiver;
            royaltyAmount = (salePrice * royalties[0].percentage) / 100;
        }
    }

    function royaltiesInfo(uint256 tokenId, uint256 salePrice)
        public
        view
        override
        returns (address[] memory receivers, uint256[] memory royaltyAmounts)
    {
        RoyaltyInfo[] storage royalties = _royalties[tokenId];
        receivers = new address[](royalties.length);
        royaltyAmounts = new uint256[](royalties.length);
        for (uint256 i = 0; i < royalties.length; ++i) {
            receivers[i] = royalties[i].receiver;
            royaltyAmounts[i] = (salePrice * royalties[i].percentage) / 100;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC165Storage) returns (bool) {
        return
            interfaceId == type(IERC2981).interfaceId ||
            interfaceId == type(IMultiRoyalty).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
