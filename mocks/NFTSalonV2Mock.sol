// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";

import "../library/SignatureValidator.sol";
import "../library/TokenType.sol";
import "../interfaces/ISuperAssetV2.sol";
import "../interfaces/IMultiRoyalty.sol";

contract NFTSalonV2Mock is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using TokenType for address;

    struct Auction {
        uint bidPrice;
        uint bidEnd;
        bool isBidding;
        bool isCountdown;
        address payable bidder;
        address seller;
        string metadata;
        string secretUrl;
    }

    address private _signer;
    uint private _systemTotalBalance;
    uint public systemRoyaltyPercentage;

    mapping(address => mapping(uint => Auction)) private _auctions;
    mapping(address => mapping(uint => string)) private _locations;
    mapping(address => uint) private _userBalances;

    // Upgraded fields
    string private _upgradedField;

    event BidStarted(
        uint indexed tokenId,
        address indexed seller,
        bool isBidding,
        uint bidPrice,
        uint endTime,
        bool isClosedBySuperWorld,
        uint timestamp,
        string location
    );
    event TokenBidded(uint indexed tokenId, address indexed bidder, uint bidPrice, uint timestamp);
    event TransferFailed(address indexed receiver, uint amount);

    function initialize(uint percent, address signer) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        systemRoyaltyPercentage = percent;
        _signer = signer;
    }

    function setSignerAddress(address signer) public onlyOwner {
        _signer = signer;
    }

    function setSystemRoyaltyPercentage(uint percentage) public onlyOwner {
        systemRoyaltyPercentage = percentage;
    }

    function buyToken(
        uint _tokenId,
        uint _batchId,
        uint _price,
        address _tokenAddress,
        address payable _seller,
        string memory _metadata,
        string memory _secretUrl,
        string memory _location,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature
    ) public payable {
        require(msg.value >= _price, "NFTSalonV2: Incorrect amount specified");

        _mintOrBuyToken(
            _tokenId,
            _batchId,
            _price,
            _tokenAddress,
            _seller,
            payable(_msgSender()),
            _metadata,
            _secretUrl,
            _royaltyAddresses,
            _royaltyPercentages,
            _signature,
            false
        );

        if (_tokenAddress.isSuperAssetV2()) {
            ISuperAssetV2(_tokenAddress).setTokenLocation(_tokenId, _location);
        }
        _locations[_tokenAddress][_tokenId] = _location;
    }

    function _buyToken(
        uint _tokenId,
        uint _amount,
        address _tokenAddress,
        address payable _seller,
        address payable _buyer,
        string memory _location,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bool _isAuction
    ) private nonReentrant {
        if (!_checkSellerValidity(_tokenId, _tokenAddress, _seller, _isAuction)) {
            return;
        }

        if (_tokenAddress.isERC721()) {
            IERC721(_tokenAddress).safeTransferFrom(_seller, _buyer, _tokenId);
        } else if (_tokenAddress.isERC1155()) {
            IERC1155(_tokenAddress).safeTransferFrom(_seller, _buyer, _tokenId, 1, "");
        }

        {
            uint totalAmount = _amount;
            uint systemFee = (_amount * systemRoyaltyPercentage) / 100;

            totalAmount -= systemFee;
            _systemTotalBalance += systemFee;

            totalAmount = _payRoyaltyMembers(
                totalAmount,
                _tokenId,
                _tokenAddress,
                _royaltyAddresses,
                _royaltyPercentages
            );

            require(totalAmount >= 0, "NFTSalonV2: Remained amount should not be negative");

            (bool success, ) = _seller.call{value: totalAmount}("");
            if (success == false) {
                emit TransferFailed(_seller, totalAmount);
            }
        }

        if (_tokenAddress.isSuperAssetV2()) {
            ISuperAssetV2(_tokenAddress).setTokenLocation(_tokenId, _location);
        }
        _locations[_tokenAddress][_tokenId] = _location;
    }

    function addBid(
        uint _tokenId,
        uint _price,
        uint _endTimestamp,
        bool _isCountdown,
        address _tokenAddress,
        address payable _seller,
        string memory _metadata,
        string memory _secretUrl,
        string memory _location,
        bytes memory _signature
    ) public payable nonReentrant {
        require(msg.value >= _price, "NFTSalonV2: Incorrect amount specified");

        SignatureValidator.verifySignature(
            _signer,
            keccak256(abi.encodePacked(_tokenId, _tokenAddress, _price, _seller, _metadata, _secretUrl)),
            _signature
        );

        Auction storage tokenAuctionData = _auctions[_tokenAddress][_tokenId];
        if (tokenAuctionData.bidder == payable(address(0x0))) {
            require(tokenAuctionData.isBidding == false, "NFTSalonV2: Token is already on auction");

            if (_isCountdown == false) {
                require(_endTimestamp > block.timestamp, "NFTSalonV2: Incorrect auction end timestamp specified");
                tokenAuctionData.bidEnd = _endTimestamp;
            } else {
                tokenAuctionData.bidEnd = _endTimestamp + block.timestamp;
            }
            tokenAuctionData.isCountdown = _isCountdown;
            tokenAuctionData.isBidding = true;
            tokenAuctionData.bidPrice = _price;
            tokenAuctionData.seller = _seller;
            tokenAuctionData.bidder = payable(_msgSender());
            tokenAuctionData.metadata = _metadata;
            tokenAuctionData.secretUrl = _secretUrl;

            emit BidStarted(_tokenId, _seller, true, _price, _endTimestamp, false, block.timestamp, _location);
        } else {
            require(_price > tokenAuctionData.bidPrice, "NFTSalonV2: Incorrect bid price is specified");
            require(tokenAuctionData.isBidding, "NFTSalonV2: Auction ended");
            require(tokenAuctionData.bidEnd > block.timestamp, "NFTSalonV2: Auction ended");

            uint oldBidAmount = tokenAuctionData.bidPrice;
            address oldBidder = tokenAuctionData.bidder;

            tokenAuctionData.bidder = payable(_msgSender());
            tokenAuctionData.bidPrice = _price;

            (bool success, ) = oldBidder.call{value: oldBidAmount}("");
            if (success == false) {
                _userBalances[oldBidder] += oldBidAmount;
            }
            emit TokenBidded(_tokenId, _msgSender(), _price, block.timestamp);
        }

        if (_tokenAddress.isSuperAssetV2() && ISuperAssetV2(_tokenAddress).exists(_tokenId)) {
            ISuperAssetV2(_tokenAddress).setTokenLocation(_tokenId, _location);
        }
        _locations[_tokenAddress][_tokenId] = _location;
    }

    function closeBid(
        uint _tokenId,
        uint _batchId,
        address _tokenAddress,
        address payable _seller,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature
    ) public onlyOwner nonReentrant {
        Auction storage tokenAuctionData = _auctions[_tokenAddress][_tokenId];

        require(tokenAuctionData.isBidding, "NFTSalonV2: Token is not bidding");
        require(tokenAuctionData.bidEnd < block.timestamp, "NFTSalonV2: The Auction is not ended");

        _mintOrBuyToken(
            _tokenId,
            _batchId,
            tokenAuctionData.bidPrice,
            _tokenAddress,
            _seller,
            tokenAuctionData.bidder,
            tokenAuctionData.metadata,
            tokenAuctionData.secretUrl,
            _royaltyAddresses,
            _royaltyPercentages,
            _signature,
            true
        );

        tokenAuctionData.bidder = payable(address(0x0));
        tokenAuctionData.bidEnd = 0;
        tokenAuctionData.isBidding = false;
        tokenAuctionData.bidPrice = 0;
        tokenAuctionData.seller = address(0x0);
        tokenAuctionData.isCountdown = false;
        tokenAuctionData.metadata = "";
        tokenAuctionData.secretUrl = "";

        emit BidStarted(_tokenId, _msgSender(), false, 0, 0, true, block.timestamp, "");
    }

    function closeBidByOwner(
        uint _tokenId,
        uint _batchId,
        address _tokenAddress,
        address payable _seller,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature
    ) public {
        Auction storage tokenAuctionData = _auctions[_tokenAddress][_tokenId];

        require(tokenAuctionData.isBidding, "NFTSalonV2: Token is not bidding");
        require(tokenAuctionData.seller == _msgSender(), "NFTSalonV2: Seller is not the owner");
        require(tokenAuctionData.seller == _seller, "NFTSalonV2: Incorrect seller is specified");
        require(tokenAuctionData.bidEnd < block.timestamp, "NFTSalonV2: Auction is still active");

        _mintOrBuyToken(
            _tokenId,
            _batchId,
            tokenAuctionData.bidPrice,
            _tokenAddress,
            _seller,
            tokenAuctionData.bidder,
            tokenAuctionData.metadata,
            tokenAuctionData.secretUrl,
            _royaltyAddresses,
            _royaltyPercentages,
            _signature,
            true
        );

        tokenAuctionData.bidder = payable(address(0x0));
        tokenAuctionData.bidEnd = 0;
        tokenAuctionData.isBidding = false;
        tokenAuctionData.bidPrice = 0;
        tokenAuctionData.seller = address(0x0);
        tokenAuctionData.isCountdown = false;
        tokenAuctionData.metadata = "";
        tokenAuctionData.secretUrl = "";

        emit BidStarted(_tokenId, _msgSender(), false, 0, 0, false, block.timestamp, "");
    }

    function closeBidByBuyer(
        uint _tokenId,
        uint _batchId,
        address _tokenAddress,
        address payable _seller,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature
    ) public {
        Auction storage tokenAuctionData = _auctions[_tokenAddress][_tokenId];

        require(tokenAuctionData.isBidding, "NFTSalonV2: Token is not bidding");
        require(tokenAuctionData.bidder == _msgSender(), "NFTSalonV2: Not Bidder");
        require(tokenAuctionData.bidEnd < block.timestamp, "NFTSalonV2: Auction is still active");

        _mintOrBuyToken(
            _tokenId,
            _batchId,
            tokenAuctionData.bidPrice,
            _tokenAddress,
            _seller,
            tokenAuctionData.bidder,
            tokenAuctionData.metadata,
            tokenAuctionData.secretUrl,
            _royaltyAddresses,
            _royaltyPercentages,
            _signature,
            true
        );

        tokenAuctionData.bidder = payable(address(0x0));
        tokenAuctionData.bidEnd = 0;
        tokenAuctionData.isBidding = false;
        tokenAuctionData.bidPrice = 0;
        tokenAuctionData.seller = address(0x0);
        tokenAuctionData.isCountdown = false;
        tokenAuctionData.metadata = "";
        tokenAuctionData.secretUrl = "";

        emit BidStarted(_tokenId, _seller, false, 0, 0, false, block.timestamp, "");
    }

    function giftToken(
        uint _tokenId,
        address _tokenAddress,
        address _receiver
    ) public {
        require(_auctions[_tokenAddress][_tokenId].isBidding == false, "NFTSalonV2: Token is bidded");

        if (_tokenAddress.isERC721()) {
            require(IERC721(_tokenAddress).ownerOf(_tokenId) == _msgSender(), "NFTSalonV2: Only token owner allowed");
            IERC721(_tokenAddress).safeTransferFrom(_msgSender(), _receiver, _tokenId);
        } else if (_tokenAddress.isERC1155()) {
            require(
                IERC1155(_tokenAddress).balanceOf(_msgSender(), _tokenId) != 0,
                "NFTSalonV2: Only token owner allowed"
            );
            IERC1155(_tokenAddress).safeTransferFrom(_msgSender(), _receiver, _tokenId, 1, "");
        }
    }

    function withdrawSystemBalance() public payable onlyOwner nonReentrant returns (bool) {
        require(_systemTotalBalance > 0, "NFTSalonV2: System balance should be positive");

        (bool success, ) = _msgSender().call{value: _systemTotalBalance}("");
        if (success) {
            _systemTotalBalance = 0;
        } else {
            emit TransferFailed(_msgSender(), _systemTotalBalance);
        }
        return success;
    }

    function withdrawUserBalance() public payable nonReentrant returns (bool) {
        require(_userBalances[_msgSender()] > 0, "NFTSalonV2: System balance should be positive");

        (bool success, ) = _msgSender().call{value: _userBalances[_msgSender()]}("");
        if (success) {
            _userBalances[_msgSender()] = 0;
        } else {
            emit TransferFailed(_msgSender(), _userBalances[_msgSender()]);
        }
        return success;
    }

    function getTokenLocation(uint _tokenId, address _tokenAddress) public view returns (string memory) {
        return _locations[_tokenAddress][_tokenId];
    }

    function getSystemTotalBalance() public view returns (uint) {
        return _systemTotalBalance;
    }

    function getTokenAuctionDetails(uint _tokenId, address _tokenAddress)
        external
        view
        returns (
            uint _bidPrice,
            uint _bidEnd,
            bool _isBidding,
            bool _isCountdown,
            address _bidder,
            address _seller,
            string memory _metadata
        )
    {
        Auction storage tokenAuctionData = _auctions[_tokenAddress][_tokenId];
        _bidPrice = tokenAuctionData.bidPrice;
        _bidEnd = tokenAuctionData.bidEnd;
        _isBidding = tokenAuctionData.isBidding;
        _isCountdown = tokenAuctionData.isCountdown;
        _bidder = tokenAuctionData.bidder;
        _seller = tokenAuctionData.seller;
        _metadata = tokenAuctionData.metadata;
    }

    function _mintOrBuyToken(
        uint _tokenId,
        uint _batchId,
        uint _price,
        address _tokenAddress,
        address payable _seller,
        address payable _buyer,
        string memory _metadata,
        string memory _secretUrl,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages,
        bytes memory _signature,
        bool _isAuction
    ) private {
        if (_tokenAddress.isSuperAssetV2() && !ISuperAssetV2(_tokenAddress).exists(_tokenId)) {
            uint systemFee = (_price * systemRoyaltyPercentage) / 100;
            _price -= systemFee;
            _systemTotalBalance += systemFee;

            TokenMintData memory tokenData = TokenMintData(
                _tokenId,
                _batchId,
                _price,
                _seller,
                _buyer,
                _metadata,
                _secretUrl
            );

            ISuperAssetV2(_tokenAddress).mintToken{value: _price}(
                tokenData,
                _royaltyAddresses,
                _royaltyPercentages,
                _signature
            );
        } else {
            bytes32 messageHash = keccak256(
                abi.encodePacked(
                    _tokenId,
                    _price,
                    _batchId,
                    _seller,
                    _buyer,
                    _metadata,
                    _secretUrl,
                    _royaltyAddresses,
                    _royaltyPercentages
                )
            );
            SignatureValidator.verifySignature(_signer, messageHash, _signature);

            string memory location = _locations[_tokenAddress][_tokenId];
            _buyToken(
                _tokenId,
                _price,
                _tokenAddress,
                _seller,
                _buyer,
                location,
                _royaltyAddresses,
                _royaltyPercentages,
                _isAuction
            );
        }
    }

    function _checkSellerValidity(
        uint _tokenId,
        address _tokenAddress,
        address payable _seller,
        bool _isAuction
    ) private returns (bool) {
        bool isSellerValid = true;
        if (_tokenAddress.isERC721()) {
            isSellerValid = (_seller == payable(IERC721(_tokenAddress).ownerOf(_tokenId)));
        } else if (_tokenAddress.isERC1155()) {
            isSellerValid = (IERC1155(_tokenAddress).balanceOf(_seller, _tokenId) > 0);
        }
        if (_isAuction) {
            if (!isSellerValid) {
                address payable bidder = _auctions[_tokenAddress][_tokenId].bidder;
                uint bidPrice = _auctions[_tokenAddress][_tokenId].bidPrice;
                if (bidder != payable(address(0x0)) && bidPrice != 0) {
                    (bool status, ) = (bidder).call{value: bidPrice}("");
                    if (status == false) {
                        _userBalances[bidder] += bidPrice;
                        emit TransferFailed(bidder, bidPrice);
                    }
                }
                return false;
            }
        } else {
            require(isSellerValid, "NFTSalonV2: Wrong seller address");
        }

        return isSellerValid;
    }

    function _payRoyaltyMembers(
        uint _totalAmount,
        uint _tokenId,
        address _tokenAddress,
        address payable[] memory _royaltyAddresses,
        uint[] memory _royaltyPercentages
    ) private returns (uint) {
        if (_tokenAddress.supportsMultiRoyalty()) {
            address[] memory receivers;
            uint256[] memory royaltyAmounts;

            (receivers, royaltyAmounts) = IMultiRoyalty(_tokenAddress).royaltiesInfo(_tokenId, _totalAmount);
            if (receivers.length == 0 || royaltyAmounts.length == 0) {
                if (_royaltyAddresses.length > 0 && _royaltyPercentages.length > 0) {
                    ISuperAssetV2(_tokenAddress).setTokenRoyalties(_tokenId, _royaltyAddresses, _royaltyPercentages);
                    (receivers, royaltyAmounts) = IMultiRoyalty(_tokenAddress).royaltiesInfo(_tokenId, _totalAmount);
                }
            }

            for (uint i = 0; i < receivers.length; ++i) {
                address receiver = receivers[i];
                uint royaltyAmount = royaltyAmounts[i];
                _totalAmount -= royaltyAmount;

                (bool sent, ) = receiver.call{value: royaltyAmount}("");
                if (sent == false) {
                    emit TransferFailed(receiver, royaltyAmount);
                }
            }
        } else if (_tokenAddress.supportsSingleRoyalty()) {
            (address receiver, uint256 royaltyAmount) = IERC2981(_tokenAddress).royaltyInfo(_tokenId, _totalAmount);
            _totalAmount -= royaltyAmount;

            (bool sent, ) = receiver.call{value: royaltyAmount}("");
            if (sent == false) {
                emit TransferFailed(receiver, royaltyAmount);
            }
        }

        return _totalAmount;
    }

    // New functions after an upgrade
    function setUpgradedField(string memory newValue) external onlyOwner {
        _upgradedField = newValue;
    }

    function getUpgradedField() external view returns (string memory) {
        return _upgradedField;
    }
}
