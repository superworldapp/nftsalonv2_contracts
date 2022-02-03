// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
//import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/Ownable.sol";
//import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
//import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./library/CompactArray.sol";

contract PlaceOfferERC721 is Ownable, ReentrancyGuard {
    using CompactArray for uint[];

    struct Offer {
        uint price;
        address maker;
    }

    uint public percentageCut;
    uint public contractBalance;
    uint public offerCounter = 1;
    mapping(address => mapping(uint => mapping(address => uint))) public offerIds; //contractAddr -> (tokenId -> (offerMaker -> offerIds))
    mapping(address => mapping(uint => uint[])) public tokenOfferIds; //contractAddr -> (tokenId -> [offerIds])
    mapping(uint => Offer) public offers; //offerId => Offer details

    event OfferAdded(
        uint indexed tokenId,
        address indexed contractAddr,
        uint offerId,
        address offerMaker,
        uint offerPrice
    );
    event OfferUpdated(
        uint indexed tokenId,
        address indexed contractAddr,
        uint offerId,
        address offerMaker,
        uint offerPrice
    );
    event OfferAccepted(
        uint indexed tokenId,
        address indexed contractAddr,
        uint offerId,
        address offerMaker,
        address offerAcceptor,
        uint offerPrice
    );

    constructor(uint percent) {
        percentageCut = percent;
    }

    modifier isTokenOwner(uint tokenId, address contractAddr) {
        require(IERC721(contractAddr).ownerOf(tokenId) == msg.sender, "Only token owner allowed");
        _;
    }

    function setPercentageCut(uint percent) public onlyOwner {
        percentageCut = percent;
    }

    function addOffer(uint tokenId, address contractAddr) public payable nonReentrant {
        require(offerIds[contractAddr][tokenId][msg.sender] == 0, "An offer is already made by the given address");
        offerIds[contractAddr][tokenId][msg.sender] = offerCounter;
        (tokenOfferIds[contractAddr][tokenId]).push(offerCounter);
        offers[offerCounter] = Offer(msg.value, msg.sender);
        emit OfferAdded(tokenId, contractAddr, offerCounter, msg.sender, msg.value);
        offerCounter++;
    }

    function changeOffer(
        uint tokenId,
        address contractAddr,
        uint newPrice
    ) public payable nonReentrant {
        uint offerId = offerIds[contractAddr][tokenId][msg.sender];
        require(offerId > 0, "No offerId found");
        Offer storage offer = offers[offerId];
        require(offer.price != newPrice && newPrice > 0, "No change in offer");

        uint priceDiff;
        if (offer.price > newPrice) {
            //offer price reduced
            priceDiff = offer.price - newPrice;
            offer.price = newPrice;
            (bool sent, ) = msg.sender.call{value: priceDiff}("");
            emit OfferUpdated(tokenId, contractAddr, offerId, msg.sender, newPrice);
        } else {
            //offer price is increased
            priceDiff = newPrice - offer.price;
            require(msg.value >= priceDiff, "Incorrect amount specified");
            offer.price = newPrice;
            emit OfferUpdated(tokenId, contractAddr, offerId, msg.sender, newPrice);
        }
    }

    function withdrawOffer(uint tokenId, address contractAddr) public nonReentrant {
        uint offerId = offerIds[contractAddr][tokenId][msg.sender];
        require(offerId > 0, "No offerId found");
        Offer storage offer = offers[offerId];

        require(offer.price > 0, "No offer");
        uint withdrawAmount = offer.price;
        offer.maker = address(0);
        offer.price = 0;
        tokenOfferIds[contractAddr][tokenId].removeByValue(offerId);
        offerIds[contractAddr][tokenId][msg.sender] = 0;
        (bool sent, ) = msg.sender.call{value: withdrawAmount}("");
        emit OfferUpdated(tokenId, contractAddr, offerId, msg.sender, 0);
    }

    function acceptOffer(
        uint tokenId,
        address contractAddr,
        address offerMaker
    ) public nonReentrant isTokenOwner(tokenId, contractAddr) {
        uint offerId = offerIds[contractAddr][tokenId][offerMaker];
        require(offerId > 0, "No offerId found");

        Offer storage offer = offers[offerId];
        IERC721(contractAddr).safeTransferFrom(msg.sender, offer.maker, tokenId);
        uint fee = (offer.price * percentageCut) / 100;
        uint offerAfterCut = offer.price - fee;
        contractBalance += fee;
        (bool sent, ) = (msg.sender).call{value: offerAfterCut}("");
        uint[] storage ids = tokenOfferIds[contractAddr][tokenId];
        uint tokenOfferId;
        for (uint i = 0; i < ids.length; i++) {
            tokenOfferId = ids[i];
            Offer storage currentOffer = offers[tokenOfferId];
            if (tokenOfferId != offerId && currentOffer.maker != address(0) && currentOffer.price != 0) {
                (sent, ) = (currentOffer.maker).call{value: currentOffer.price}("");
                currentOffer.maker = address(0);
                currentOffer.price = 0;
            }
        }
        tokenOfferIds[contractAddr][tokenId] = new uint[](0);
        offerIds[contractAddr][tokenId][offerMaker] = 0;

        emit OfferAccepted(tokenId, contractAddr, offerId, offer.maker, msg.sender, offer.price);

        offer.maker = address(0);
        offer.price = 0;
    }

    function getOfferIDsForToken(uint tokenId, address contractAddr) public view returns (uint[] memory) {
        return tokenOfferIds[contractAddr][tokenId];
    }

    function withdrawOwner(uint fundAmount) public onlyOwner nonReentrant {
        require(fundAmount <= contractBalance, "Incorrect amount is specified");
        contractBalance -= fundAmount;
        (bool sent, ) = (msg.sender).call{value: fundAmount}("");
        if (!sent) {
            contractBalance += fundAmount;
        }
    }
}
