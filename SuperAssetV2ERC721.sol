// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./PerTokenRoyalties.sol";
import "./library/SignatureValidator.sol";
import "./structs/TokenMintData.sol";
import "./interfaces/ISuperAssetV2.sol";

contract SuperAssetV2ERC721 is ISuperAssetV2, PerTokenRoyalties, ERC721Enumerable, Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using Strings for uint256;

    struct TokenData {
        uint price;
        uint batchId;
        address payable creator;
        address payable buyer;
        // JSON metadata with userId, name, fileUrl, thumbnailUrl information
        string metadata;
        string secretUrl;
        string location;
    }

    address private _signer;
    address private _marketplaceAddress;
    string public metaUrl;

    mapping(uint => TokenData) private _tokenDetails;
    mapping(address => EnumerableSet.UintSet) private walletTokens;

    event TokenCreated(uint indexed tokenId, address indexed creator, uint indexed batchId, uint timestamp);
    event TokenBought(
        uint indexed tokenId,
        address indexed owner,
        address indexed seller,
        uint timestamp,
        string location
    );

    event TransferFailed(uint indexed tokenId, address indexed receiver, uint amount);

    constructor(
        string memory url,
        address signer,
        address marketplaceAddress
    ) PerTokenRoyalties() ERC721("SuperAsset", "SUPERASSET") {
        metaUrl = url;
        _signer = signer;
        _marketplaceAddress = marketplaceAddress;
    }

    //only the creator of token allowed
    modifier onlyTokenCreator(uint tokenId) {
        require(_tokenDetails[tokenId].creator == _msgSender(), "SuperAssetV2ERC721: Only token creator allowed");
        _;
    }

    //only the owner of token allowed
    modifier onlyTokenOwner(uint tokenId) {
        require(ownerOf(tokenId) == _msgSender(), "SuperAssetV2ERC721: Only token owner allowed");
        _;
    }

    modifier onlyTokenOwnerOrCreator(uint tokenId) {
        bool allowed = false;
        if (ownerOf(tokenId) == _msgSender() || _tokenDetails[tokenId].creator == _msgSender()) {
            allowed = true;
        }

        require(allowed == true, "SuperAssetV2ERC721: Not allowed");

        _;
    }

    function setMarketplaceAddress(address marketplaceAddress) external override onlyOwner {
        _marketplaceAddress = marketplaceAddress;
    }

    function setSignerAddress(address signerAddress) external override onlyOwner {
        _signer = signerAddress;
    }

    function setMetaUrl(string memory url) external override onlyOwner {
        metaUrl = url;
    }

    function tokenURI(uint tokenId) public view override returns (string memory) {
        return string(abi.encodePacked(metaUrl, tokenId.toString()));
    }

    function mintTokenBatch(
        uint _amountToMint,
        uint _price,
        uint _batchId,
        address payable _creator,
        address payable _buyer,
        string memory _metadata,
        string memory _secretUrl,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature
    ) public payable override {
        TokenMintData memory _tokenData = TokenMintData(0, _batchId, _price, _creator, _buyer, _metadata, _secretUrl);
        for (uint i = 0; i < _amountToMint; i++) {
            mintToken(_tokenData, _royaltyAddresses, _royaltyPercentages, _signature);
        }
    }

    function mintToken(
        TokenMintData memory _tokenData,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature
    ) public payable override returns (uint) {
        require(msg.value >= _tokenData.price, "SuperAssetV2ERC721: Incorrect amount specified");

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _tokenData.tokenId,
                _tokenData.price,
                _tokenData.batchId,
                _tokenData.creator,
                _tokenData.buyer,
                _tokenData.metadata,
                _tokenData.secretUrl,
                _royaltyAddresses,
                _royaltyPercentages
            )
        );
        SignatureValidator.verifySignature(_signer, messageHash, _signature);

        uint tokenId = _tokenData.tokenId;
        if (tokenId == 0) {
            tokenId = totalSupply() + 1;
        }
        require(!_exists(tokenId), "SuperAssetV2ERC721: Token exists with such ID");

        _setTokenRoyalties(tokenId, _royaltyAddresses, _royaltyPercentages);

        {
            address[] memory receivers;
            uint256[] memory royaltyAmounts;
            uint totalAmount = _tokenData.price;

            (receivers, royaltyAmounts) = royaltiesInfo(tokenId, msg.value);

            for (uint i = 0; i < receivers.length; ++i) {
                address receiver = receivers[i];
                uint royaltyAmount = royaltyAmounts[i];

                totalAmount -= royaltyAmount;

                (bool sent, ) = receiver.call{value: royaltyAmount}("");
                if (sent == false) {
                    emit TransferFailed(tokenId, receiver, royaltyAmount);
                }
            }
            require(totalAmount >= 0, "SuperAssetV2ERC721: Remained amount should not be negative");

            (bool success, ) = _tokenData.creator.call{value: totalAmount}("");
            if (success == false) {
                emit TransferFailed(tokenId, _tokenData.creator, totalAmount);
            }
        }

        _tokenDetails[tokenId] = TokenData({
            price: _tokenData.price,
            creator: _tokenData.creator,
            buyer: _tokenData.buyer,
            metadata: _tokenData.metadata,
            batchId: _tokenData.batchId,
            secretUrl: _tokenData.secretUrl,
            location: ""
        });

        _safeMint(_tokenData.buyer, tokenId);

        walletTokens[_tokenData.creator].add(tokenId);

        emit TokenCreated(tokenId, _tokenData.creator, _tokenData.batchId, block.timestamp);

        return tokenId;
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint _tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(_from, _to, _tokenId);

        if (_from != address(0x0)) {
            emit TokenBought(_tokenId, _from, _to, block.timestamp, _tokenDetails[_tokenId].location);
        }
        walletTokens[_from].remove(_tokenId);
        walletTokens[_to].add(_tokenId);
    }

    function getTokenData(uint tokenId)
        external
        view
        override
        returns (
            uint _batchId,
            uint _price,
            address _creator,
            address _buyer,
            string memory _metadata,
            string memory _location
        )
    {
        _batchId = _tokenDetails[tokenId].batchId;
        _price = _tokenDetails[tokenId].price;
        _creator = _tokenDetails[tokenId].creator;
        _buyer = _tokenDetails[tokenId].buyer;
        _metadata = _tokenDetails[tokenId].metadata;
        _location = _tokenDetails[tokenId].location;
    }

    function setTokenLocation(uint _tokenId, string memory _location) external override {
        require(_msgSender() == _marketplaceAddress, "SuperAssetV2ERC721: Caller is not the marketplace");
        _tokenDetails[_tokenId].location = _location;
    }

    function getTokenLocation(uint _tokenId) public view returns (string memory) {
        return _tokenDetails[_tokenId].location;
    }

    function setTokenRoyalties(
        uint256 _tokenId,
        address payable[] memory _royaltyAddresses,
        uint256[] memory _royaltyPercentages
    ) public override {
        require(_msgSender() == _marketplaceAddress, "SuperAssetV2ERC721: Caller is not the marketplace");
        _setTokenRoyalties(_tokenId, _royaltyAddresses, _royaltyPercentages);
    }

    function getOwnedNFTs(address owner) external view override returns (string memory) {
        uint tokenCount = EnumerableSet.length(walletTokens[owner]);
        string memory intString;

        for (uint i = 0; i < tokenCount; ++i) {
            if (i > 0) {
                intString = string(abi.encodePacked(intString, ",", (EnumerableSet.at(walletTokens[owner], i))));
            } else {
                intString = string(abi.encodePacked((EnumerableSet.at(walletTokens[owner], i))));
            }
        }
        return intString;
    }

    function exists(uint tokenId) public view override returns (bool) {
        return _exists(tokenId);
    }

    function burn(uint tokenId) public onlyTokenOwner(tokenId) {
        _burn(tokenId);
    }

    /// @inheritdoc	ERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(PerTokenRoyalties, IERC165, ERC721Enumerable)
        returns (bool)
    {
        return interfaceId == type(ISuperAssetV2).interfaceId || super.supportsInterface(interfaceId);
    }
}
