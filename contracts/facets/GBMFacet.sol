// SPDX-License-Identifier: UNLICENSED
// © Copyright 2021. Patent pending. All rights reserved. Perpetual Altruism Ltd.
pragma solidity ^0.8.0;

import "../interfaces/IGBM.sol";
import "../interfaces/IGBMInitiator.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC721.sol";
import "../interfaces/IERC721TokenReceiver.sol";
import "../interfaces/IERC1155.sol";
import "../interfaces/IERC1155TokenReceiver.sol";
import "../interfaces/Ownable.sol";
import "../libraries/AppStorage.sol";
import "../libraries/LibDiamond.sol";
import "../libraries/LibSignature.sol";

//import "hardhat/console.sol";

/// @title GBM auction contract
/// @dev See GBM.auction on how to use this contract
/// @author Guillaume Gonnaud
contract GBMFacet is IGBM, IERC1155TokenReceiver, IERC721TokenReceiver, Modifiers {
    error NoSecondaryMarket();

    error AuctionNotStarted();

    //
    error ContractEnabledAlready();
    error AuctionExists();
    error NotTokenOwner();
    error StartOrEndTimeTooLow();
    error InsufficientToken();
    error UnsupportedTokenType();
    error UndefinedPreset();
    error NoAuction();
    error NotAuctionOwner();
    error AuctionEnded();
    error AuctionClaimed();
    error ModifyAuctionError();
    error AuctionNotEnded(uint256 timeToEnd);
    error CancellationTimeExceeded();
    error BiddingNotAllowed();
    error NoZeroBidAmount();
    error UnmatchedHighestBid(uint256 currentHighestBid);
    error HigherBidAmount(uint256 currentHighestBid);
    error NotHighestBidder();
    error MinBidNotMet();
    //   error AlreadyDefinedPreset();
    event TokenIndex(uint256 index);

    /// @notice Place a GBM bid for a GBM auction
    /// @param _auctionID The auction you want to bid on
    /// @param _bidAmount The amount of the ERC20 token the bid is made of. They should be withdrawable by this contract.
    /// @param _highestBid The current higest bid. Throw if incorrect.
    /// @param _signature Signature
    function commitBid(
        uint256 _auctionID,
        uint256 _bidAmount,
        uint256 _highestBid,
        bytes memory _signature
    ) external {
        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, _auctionID, _bidAmount, _highestBid));
        require(LibSignature.isValid(messageHash, _signature, s.backendPubKey), "bid: Invalid signature");

        bid(_auctionID, _bidAmount, _highestBid);
    }

    /// @notice Place a GBM bid for a GBM auction
    /// @param _auctionID The auction you want to bid on
    /// @param _bidAmount The amount of the ERC20 token the bid is made of. They should be withdrawable by this contract.
    /// @param _highestBid The current higest bid. Throw if incorrect.
    function bid(
        uint256 _auctionID,
        uint256 _bidAmount,
        uint256 _highestBid
    ) internal {
        Auction storage a = s.auctions[_auctionID];
        //verify existence
        if (a.owner == address(0)) revert NoAuction();
        if (a.info.endTime < block.timestamp) revert AuctionEnded();
        if (a.claimed == true) revert AuctionClaimed();
        if (a.biddingAllowed == false) revert BiddingNotAllowed();

        if (_bidAmount < 1) revert NoZeroBidAmount();

        if (_highestBid != a.highestBid) revert UnmatchedHighestBid(a.highestBid);

        if (_bidAmount <= _highestBid) revert HigherBidAmount(_highestBid);

        if ((_highestBid * (getAuctionBidDecimals(_auctionID) + getAuctionStepMin(_auctionID))) >= (_bidAmount * getAuctionBidDecimals(_auctionID)))
            revert MinBidNotMet();

        //Transfer the money of the bidder to the GBM Diamond
        IERC20(s.GHST).transferFrom(msg.sender, address(this), _bidAmount);

        //Extend the duration time of the auction if we are close to the end
        if (getAuctionEndTime(_auctionID) < block.timestamp + getAuctionHammerTimeDuration(_auctionID)) {
            a.info.endTime = uint80(block.timestamp + getAuctionHammerTimeDuration(_auctionID));
            emit Auction_EndTimeUpdated(_auctionID, a.info.endTime);
        }

        // Saving incentives for later sending
        uint256 duePay = s.auctions[_auctionID].dueIncentives;
        address previousHighestBidder = s.auctions[_auctionID].highestBidder;
        uint256 previousHighestBid = s.auctions[_auctionID].highestBid;

        // Emitting the event sequence
        if (previousHighestBidder != address(0)) {
            emit Auction_BidRemoved(_auctionID, previousHighestBidder, previousHighestBid);
        }

        if (duePay != 0) {
            s.auctions[_auctionID].auctionDebt = uint88(a.auctionDebt + duePay);
            emit Auction_IncentivePaid(_auctionID, previousHighestBidder, duePay);
        }

        emit Auction_BidPlaced(_auctionID, msg.sender, _bidAmount);

        // Calculating incentives for the new bidder
        s.auctions[_auctionID].dueIncentives = uint88(calculateIncentives(_auctionID, _bidAmount));

        //Setting the new bid/bidder as the highest bid/bidder
        s.auctions[_auctionID].highestBidder = msg.sender;
        s.auctions[_auctionID].highestBid = uint96(_bidAmount);

        if ((previousHighestBid + duePay) != 0) {
            //Refunding the previous bid as well as sending the incentives
            //Added to prevent revert
            //No need if using transfer()
            //  IERC20(s.GHST).approve(address(this), (previousHighestBid + duePay));

            IERC20(s.GHST).transfer(previousHighestBidder, (previousHighestBid + duePay));
        }
    }

    function batchClaim(uint256[] memory _auctionIDs) external {
        for (uint256 index = 0; index < _auctionIDs.length; index++) {
            claim(_auctionIDs[index]);
        }
    }

    // function updatePlayerRewardsAddress(address _newAddress) external onlyOwner {
    //     s.playerRewards = _newAddress;
    // }

    /// @notice Attribute a token to the winner of the auction and distribute the proceeds to the owner of this contract.
    /// throw if bidding is disabled or if the auction is not finished.
    /// @param _auctionID The auctionId of the auction to complete
    function claim(uint256 _auctionID) public {
        Auction storage a = s.auctions[_auctionID];
        if (a.owner == address(0)) revert NoAuction();
        if (a.info.endTime + getAuctionHammerTimeDuration(_auctionID) > block.timestamp)
            revert AuctionNotEnded(a.info.endTime + getAuctionHammerTimeDuration(_auctionID));
        if (a.claimed == true) revert AuctionClaimed();
        //only owner should caim
        if (msg.sender != a.highestBidder) revert NotHighestBidder();
        address ca = s.secondaryMarketTokenContract[a.contractID];
        uint256 tid = a.info.tokenID;
        uint256 tam = a.info.tokenAmount;

        //Prevents re-entrancy
        a.claimed = true;

        //Todo: Add in the various Aavegotchi addresses
        uint256 _proceeds = a.highestBid - a.auctionDebt;

        //Added to prevent revert
        //IERC20(s.GHST).approve(address(this), _proceeds);

        //Transfer the proceeds to the various recipients
        //TODO: DEFINE FEE PERCENTAGES
        //5% to burn address
        /** 
        uint256 burnShare = (_proceeds * 5) / 100;

        //40% to Pixelcraft wallet
        uint256 companyShare = (_proceeds * 40) / 100;

        //40% to player rewards
        uint256 playerRewardsShare = (_proceeds * 2) / 5;

        //15% to DAO
        uint256 daoShare = (_proceeds - burnShare - companyShare - playerRewardsShare);

        IERC20(s.GHST).transfer(address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF), burnShare);
        IERC20(s.GHST).transfer(s.pixelcraft, companyShare);
        IERC20(s.GHST).transfer(s.playerRewards, playerRewardsShare);
        IERC20(s.GHST).transfer(s.daoTreasury, daoShare);
*/
        //todo: test
        //not feasible for secondary/user-created auctions
        // if (s.auctions[_auctionID].highestBid == 0) {
        //     s.auctions[_auctionID].highestBidder = LibDiamond.contractOwner();
        // }
        if (a.info.tokenKind == ERC721) {
            _sendTokens(ca, a.highestBidder, ERC721, tid, 1);
        }
        if (a.info.tokenKind == ERC1155) {
            _sendTokens(ca, a.highestBidder, ERC1155, tid, tam);
            //update storage
            s.erc1155AuctionIndexes[ca][tid][tam]--;
        }

        emit Auction_ItemClaimed(_auctionID);
    }

    /// @notice Allow/disallow bidding and claiming for a whole token contract address.
    /// @param _contract The token contract the auctionned token belong to
    /// @param _value True if bidding/claiming should be allowed.
    function setBiddingAllowed(address _contract, bool _value) external onlyOwner {
        s.biddingAllowed[_contract] = _value;
        emit Contract_BiddingAllowed(_contract, _value);
    }

    function enableContract(uint256 _contractID, address _tokenContract) external onlyOwner {
        if (s.secondaryMarketTokenContract[_contractID] != address(0)) revert ContractEnabledAlready();
        s.secondaryMarketTokenContract[_contractID] = _tokenContract;
    }

    function createAuction(
        InitiatorInfo calldata _info,
        bytes4 _tokenKind,
        uint160 _contractID,
        uint256 _auctionPresetID
    ) external {
        if (s.auctionPresets[_auctionPresetID].incMin < 1) revert UndefinedPreset();
        uint256 id = _info.tokenID;
        uint256 amount = _info.tokenAmount;
        address ca = s.secondaryMarketTokenContract[_contractID];
        uint256 _aid;
        if (ca == address(0)) revert NoSecondaryMarket();
        _validateInitialAuction(_info);
        if (_tokenKind == ERC721) {
            if (s.erc721AuctionExists[ca][id] != false) revert AuctionExists();
            if (msg.sender != Ownable(ca).owner()) revert NotTokenOwner();
            //transfer Token
            IERC721(ca).safeTransferFrom(msg.sender, address(this), id);
            //register onchain after successfull transfer
            _aid = uint256(keccak256(abi.encodePacked(ca, id, _tokenKind, block.number, amount)));
            amount = 1;
        }
        if (_tokenKind == ERC1155) {
            uint256 index = s.erc1155AuctionIndexes[ca][id][amount];
            if (IERC721(ca).balanceOf(msg.sender) < amount) revert InsufficientToken();
            //transfer Token
            IERC1155(ca).safeTransferFrom(msg.sender, address(this), id, amount, "");
            index++;
            _aid = uint256(keccak256(abi.encodePacked(ca, id, _tokenKind, block.number, index)));
        } else {
            revert UnsupportedTokenType();
        }

        //set initiator info and set bidding allowed
        Auction storage a = s.auctions[_aid];
        a.owner = msg.sender;
        a.contractID = _contractID;
        a.info = _info;
        a.biddingAllowed = true;
        emit Auction_Initialized(_aid, id, amount, ca, _tokenKind);
        emit Auction_StartTimeUpdated(_aid, getAuctionStartTime(_aid));
    }

    function modifyAuction(
        uint256 _auctionID,
        uint80 _newEndTime,
        uint64 _newTokenAmount,
        bytes4 _tokenKind
    ) external {
        Auction storage a = s.auctions[_auctionID];
        //verify existence
        if (a.owner == address(0)) revert NoAuction();
        //verify ownership
        if (a.owner != msg.sender) revert NotAuctionOwner();
        if (a.info.endTime < block.timestamp) revert AuctionEnded();
        if (a.claimed == true) revert AuctionClaimed();

        uint256 tid = a.info.tokenID;
        address ca = s.secondaryMarketTokenContract[a.contractID];
        //verify that no bids have been entered yet
        if (a.highestBid > 0) revert ModifyAuctionError();

        if (_tokenKind == ERC721) {
            a.info.endTime = _newEndTime;
            emit Auction_Initialized(_auctionID, tid, 1, ca, _tokenKind);
        }

        if (_tokenKind == ERC1155) {
            uint256 diff = 0;
            a.info.endTime = _newEndTime;
            uint256 currentAmount = a.info.tokenAmount;

            if (currentAmount < _newTokenAmount) {
                diff = _newTokenAmount - currentAmount;
                //retrieve Token
                IERC1155(ca).safeTransferFrom(msg.sender, address(this), a.info.tokenID, diff, "");
                // update storage
                a.info.tokenAmount = _newTokenAmount;
            }
            if (currentAmount > _newTokenAmount) {
                diff = currentAmount - _newTokenAmount;
                //refund tokens
                _sendTokens(ca, msg.sender, _tokenKind, tid, diff);
                //update storage
                a.info.tokenAmount = _newTokenAmount;
                s.erc1155AuctionIndexes[ca][tid][currentAmount]--;
                s.erc1155AuctionIndexes[ca][tid][_newTokenAmount]++;
            }
            emit Auction_Initialized(_auctionID, tid, _newTokenAmount, ca, _tokenKind);
        }
    }

    function _validateInitialAuction(InitiatorInfo memory _info) internal {
        //TODO: Add a minimum time for auction lifetime
        //TODO: Add extra checks for incMin and incMax(min and max values)
        if (_info.startTime <= block.timestamp || _info.startTime <= _info.endTime) revert StartOrEndTimeTooLow();
    }

    function _sendTokens(
        address _contract,
        address _recipient,
        bytes4 _tokenKind,
        uint256 _tokenID,
        uint256 _amount
    ) internal {
        if (_tokenKind == ERC721) {
            IERC721(_contract).safeTransferFrom(address(this), _recipient, _tokenID, "");
        }
        if (_tokenKind == ERC1155) {
            IERC1155(_contract).safeTransferFrom(address(this), _recipient, _tokenID, _amount, "");
        }
    }

    /// @notice Seller can cancel an auction during the grace period
    /// Throw if the token owner is not the caller of the function
    /// @param _auctionID The auctionId of the auction to cancel
    function cancelAuction(uint256 _auctionID) public {
        Auction storage a = s.auctions[_auctionID];
        //verify existence
        if (a.owner == address(0)) revert NoAuction();
        //verify ownership
        if (a.owner != msg.sender) revert NotAuctionOwner();
        if (a.info.endTime > block.timestamp) revert AuctionNotEnded(getAuctionEndTime(_auctionID));
        //check if not claimed
        if (a.claimed == true) revert AuctionClaimed();

        address ca = s.secondaryMarketTokenContract[a.contractID];
        uint256 tid = a.info.tokenID;
        uint256 tam = a.info.tokenAmount;
        if (getAuctionEndTime(_auctionID) + getAuctionHammerTimeDuration(_auctionID) < block.timestamp) revert CancellationTimeExceeded();
        a.claimed = true;
        //TODO:compare cases where no bids have been made
        uint256 _proceeds = a.highestBid - a.auctionDebt;

        //Send the debt + his due incentives from the seller to the highest bidder
        IERC20(s.GHST).transferFrom(a.owner, a.highestBidder, a.dueIncentives + a.auctionDebt);

        //INSERT ANY EXTRA FEE HERE

        //Refund it's bid minus debt to the highest bidder
        IERC20(s.GHST).transferFrom(address(this), a.highestBidder, _proceeds);

        // Transfer the token to the owner/canceller
        if (a.info.tokenKind == ERC721) {
            _sendTokens(ca, a.owner, ERC721, tid, 1);
        }
        if (a.info.tokenKind == ERC1155) {
            _sendTokens(ca, a.owner, ERC1155, tid, tam);
            //update storage
            s.erc1155AuctionIndexes[ca][tid][tam]--;
        }

        emit AuctionCancelled(_auctionID, tid);
    }

    /// @notice Register parameters of auction to be used as presets
    /// Throw if the token owner is not the GBM smart contract
    function setAuctionPresets(uint256 _auctionPresetID, Preset calldata _preset) external onlyOwner {
        s.auctionPresets[_auctionPresetID] = _preset;
    }

    function getAuctionPresets(uint256 _auctionPresetID) public view returns (Preset memory presets_) {
        presets_ = s.auctionPresets[_auctionPresetID];
    }

    function getAuctionInfo(uint256 _auctionID) external view returns (Auction memory auctionInfo_) {
        auctionInfo_ = s.auctions[_auctionID];
    }

    function getAuctionHighestBidder(uint256 _auctionID) external view returns (address) {
        return s.auctions[_auctionID].highestBidder;
    }

    function getAuctionHighestBid(uint256 _auctionID) external view returns (uint256) {
        return s.auctions[_auctionID].highestBid;
    }

    function getAuctionDebt(uint256 _auctionID) external view returns (uint256) {
        return s.auctions[_auctionID].auctionDebt;
    }

    function getAuctionDueIncentives(uint256 _auctionID) external view returns (uint256) {
        return s.auctions[_auctionID].dueIncentives;
    }

    function getTokenKind(uint256 _auctionID) external view returns (bytes4) {
        return s.auctions[_auctionID].info.tokenKind;
    }

    function getTokenId(uint256 _auctionID) external view returns (uint256) {
        return s.auctions[_auctionID].info.tokenID;
    }

    function getContractAddress(uint256 _auctionID) external view returns (address) {
        return s.secondaryMarketTokenContract[s.auctions[_auctionID].contractID];
    }

    function getAuctionStartTime(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].info.startTime;
    }

    function getAuctionEndTime(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].info.endTime;
    }

    function getAuctionHammerTimeDuration(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].presets.hammerTimeDuration;
    }

    function getAuctionBidDecimals(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].presets.bidDecimals;
    }

    function getAuctionStepMin(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].presets.stepMin;
    }

    function getAuctionIncMin(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].presets.incMin;
    }

    function getAuctionIncMax(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].presets.incMax;
    }

    function getAuctionBidMultiplier(uint256 _auctionID) public view returns (uint256) {
        return s.auctions[_auctionID].presets.bidMultiplier;
    }

    function onERC721Received(
        address, /* _operator */
        address, /*  _from */
        uint256, /*  _tokenId */
        bytes calldata /* _data */
    ) external pure override returns (bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    function onERC1155Received(
        address, /* _operator */
        address, /* _from */
        uint256, /* _id */
        uint256, /* _value */
        bytes calldata /* _data */
    ) external pure override returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

    function onERC1155BatchReceived(
        address, /* _operator */
        address, /* _from */
        uint256[] calldata, /* _ids */
        uint256[] calldata, /* _values */
        bytes calldata /* _data */
    ) external pure override returns (bytes4) {
        return bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    }

    /// @notice Calculating and setting how much payout a bidder will receive if outbid
    /// @dev Only callable internally
    function calculateIncentives(uint256 _auctionID, uint256 _newBidValue) internal view returns (uint256) {
        uint256 bidDecimals = getAuctionBidDecimals(_auctionID);
        uint256 bidIncMax = getAuctionIncMax(_auctionID);

        //Init the baseline bid we need to perform against
        uint256 baseBid = (s.auctions[_auctionID].highestBid * (bidDecimals + getAuctionStepMin(_auctionID))) / bidDecimals;

        //If no bids are present, set a basebid value of 1 to prevent divide by 0 errors
        if (baseBid == 0) {
            baseBid = 1;
        }

        //Ratio of newBid compared to expected minBid
        uint256 decimaledRatio = ((bidDecimals * getAuctionBidMultiplier(_auctionID) * (_newBidValue - baseBid)) / baseBid) +
            getAuctionIncMin(_auctionID) *
            bidDecimals;

        if (decimaledRatio > (bidDecimals * bidIncMax)) {
            decimaledRatio = bidDecimals * bidIncMax;
        }

        return (_newBidValue * decimaledRatio) / (bidDecimals * bidDecimals);
    }
}
