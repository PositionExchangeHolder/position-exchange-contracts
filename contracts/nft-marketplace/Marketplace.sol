pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./library/Auction.sol";

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}

contract PosiNFTMarketplace is Initializable, ReentrancyGuardUpgradeable {
    using Auction for Auction.Data;
    using AuctionGetter for Auction.Data;
    using SafeMath for uint256;
    IERC20 public posi;
    uint256 public auctionIndex;
    uint256 public minDuration;
    IUniswapV2Router01 swapRouter;
    mapping(uint256 => Auction.Data) public auctions;
    uint256 public marketIndex;
    struct MarketData {
        IERC721 nft;
        uint256 tokenId;
        uint256 price;
        bool isSold;
        address purchaser;
        address seller;
    }
    mapping(uint256 => MarketData) public markets;

    event AuctionListed(
        uint256 indexed id,
        address seller,
        address nft,
        uint256 tokenId,
        uint256 duration,
        uint256 startingPrice
    );
    event Bid(
        uint256 indexed id,
        address bidder,
        address previousBidder,
        uint256 price,
        uint256 profit,
        uint256 newDuration
    );
    event NFTReceived(
        address operator,
        address from,
        uint256 tokenId,
        bytes data
    );
    event Collected(uint256 indexed id);
    event CollectedBackNFT(uint256 indexed id);
    event MarketListed(
        uint256 indexed id,
        address seller,
        address nft,
        uint256 tokenId,
        uint256 price
    );
    event MarketPurchased(uint256 indexed id, address purchaser);
    event MarketCancelled(uint256 indexed id);
    event AuctionCancelled(uint256 indexed id);

    function initialize() public initializer {
        __ReentrancyGuard_init();
        swapRouter = IUniswapV2Router01(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        posi = IERC20(0x5CA42204cDaa70d5c773946e69dE942b85CA6706);
        minDuration = 12 hours;
    }

    fallback() external {
        revert();
    }

    function getAuctionData(uint256 _id)
        public
        view
        returns (
            address seller,
            address lastBidder,
            address nft,
            uint256 tokenId,
            uint256 lastPrice,
            uint256 raisedAmount,
            uint256 startedAt,
            uint256 endingAt,
            uint256 status
        )
    {
        Auction.Data storage auctionData = auctions[_id];
        seller = auctionData.seller;
        lastBidder = auctionData.lastBidder;
        nft = address(auctionData.nft);
        tokenId = auctionData.tokenId;
        lastPrice = auctionData.lastPrice;
        raisedAmount = auctionData.raisedAmount;
        startedAt = auctionData.startedAt;
        endingAt = auctionData.getEndingAt();
        status = auctionData.getStatus();
    }

    // list on direct purchasing market
    function listMarket(
        address _nft,
        uint256 _tokenId,
        uint256 _price
    ) external {
        require(_tokenId != 0, "invalid token");
        IERC721(_nft).safeTransferFrom(msg.sender, address(this), _tokenId);
        marketIndex++;
        markets[marketIndex] = MarketData({
            nft: IERC721(_nft),
            tokenId: _tokenId,
            price: _price,
            isSold: false,
            purchaser: address(0),
            seller: msg.sender
        });
        emit MarketListed(marketIndex, msg.sender, _nft, _tokenId, _price);
    }

    function purchaseByBNB(uint256 _id) external payable nonReentrant {
        MarketData storage marketData = markets[_id];
        require(!marketData.isSold, "Purchased");
        address[] memory paths = new address[](2);
        paths[0] = swapRouter.WETH();
        paths[1] = address(posi);
        swapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: msg.value
        }(
            marketData.price.mul(1011).div(1000),
            paths,
            address(this),
            block.timestamp + 15 minutes
        );
        _completePurchase(_id);
    }

    function purchase(uint256 _id) external {
        MarketData storage marketData = markets[_id];
        require(!marketData.isSold, "Purchased");
        // cover RFI fees
        posi.transferFrom(
            msg.sender,
            address(this),
            marketData.price.mul(1011).div(1000)
        );
        _completePurchase(_id);
    }

    function cancelMarket(uint256 _id) external {
        MarketData storage marketData = markets[_id];
        require(marketData.seller == msg.sender, "only seller");
        require(!marketData.isSold, "already sold");
        marketData.nft.transferFrom(
            address(this),
            marketData.seller,
            marketData.tokenId
        );
        marketData.isSold = true;
        emit MarketCancelled(_id);
    }

    // auction listing
    function list(
        address _nft,
        uint256 _tokenId,
        uint256 _startingPrice,
        uint256 _duration
    ) external {
        require(_tokenId != 0, "invalid token");
        require(_duration >= minDuration, "invalid duration");

        IERC721(_nft).safeTransferFrom(msg.sender, address(this), _tokenId);
        auctionIndex++;
        auctions[auctionIndex] = Auction.Data({
            seller: msg.sender,
            lastBidder: address(0),
            lastPrice: _startingPrice,
            nft: IERC721(_nft),
            tokenId: _tokenId,
            duration: _duration,
            startedAt: block.timestamp,
            isTaken: false,
            raisedAmount: 0
        });
        emit AuctionListed(
            auctionIndex,
            msg.sender,
            _nft,
            _tokenId,
            _duration,
            _startingPrice
        );
    }

    function cancelAuction(uint256 _id) external {
        Auction.Data storage auction = auctions[_id];
        require(auction.lastBidder == address(0), "already bade");
        require(auction.getStatus() == 1, "invalid status");
        require(auction.seller == msg.sender, "Only seller");
        auction.nft.safeTransferFrom(
            address(this),
            auction.seller,
            auction.tokenId
        );
        auction.isTaken = true;
        emit AuctionCancelled(_id);
    }

    function bidBNB(uint256 _id) external payable nonReentrant {
        Auction.Data storage auction = auctions[_id];
        require(auction.getStatus() == 1, "invalid status");
        (
            uint256 newAmount,
            uint256 increaseAmount,
            uint256 previousBidderReward,
            uint256 sellerAmount
        ) = auction.getBidAmount();
        address[] memory paths = new address[](2);
        paths[0] = swapRouter.WETH();
        paths[1] = address(posi);
        swapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: msg.value
        }(
            newAmount.mul(1011).div(1000),
            paths,
            address(this),
            block.timestamp + 15 minutes
        );

        if (previousBidderReward > 0) {
            posi.transfer(
                auction.lastBidder,
                auction.lastPrice.add(previousBidderReward)
            );
        }
        (uint256 newDuration, address lastBidder) = auction.updateState(
            msg.sender,
            newAmount,
            sellerAmount
        );
        emit Bid(
            _id,
            msg.sender,
            lastBidder,
            newAmount,
            previousBidderReward,
            newDuration
        );
    }

    function bid(uint256 _id) external {
        Auction.Data storage auction = auctions[_id];
        require(auction.getStatus() == 1, "invalid status");
        (
            uint256 newAmount,
            uint256 increaseAmount,
            uint256 previousBidderReward,
            uint256 sellerAmount
        ) = auction.getBidAmount();
        // plus RFI fee
        posi.transferFrom(
            msg.sender,
            address(this),
            newAmount.mul(1011).div(1000)
        );
        if (previousBidderReward > 0) {
            posi.transfer(
                auction.lastBidder,
                auction.lastPrice.add(previousBidderReward)
            );
        }
        (uint256 newDuration, address lastBidder) = auction.updateState(
            msg.sender,
            newAmount,
            sellerAmount
        );
        emit Bid(
            _id,
            msg.sender,
            lastBidder,
            newAmount,
            previousBidderReward,
            newDuration
        );
    }

    function collect(uint256 _id) external {
        Auction.Data storage auction = auctions[_id];
        require(auction.getStatus() == 2, "invalid status");
        require(
            auction.lastBidder == msg.sender || auction.seller == msg.sender,
            "not authorized"
        );
        require(!auction.isTaken, "alrady collected");
        // transfer NFT to lastBidder
        auction.nft.safeTransferFrom(
            address(this),
            auction.lastBidder,
            auction.tokenId
        );

        //send sold amount to seller
        posi.transfer(auction.seller, auction.raisedAmount);
        auction.isTaken = true;
        emit Collected(_id);
    }

    function getBackNFT(uint256 _id) external {
        Auction.Data storage auction = auctions[_id];
        require(auction.seller == msg.sender, "only seller");
        require(auction.getStatus() == 3, "invalid status");
        require(!auction.isTaken, "already taken");
        auction.nft.safeTransferFrom(
            address(this),
            auction.seller,
            auction.tokenId
        );
        auction.isTaken = true;
        emit CollectedBackNFT(_id);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes memory data
    ) public returns (bytes4) {
        //only receive the _nft staff
        if (address(this) != operator) {
            //invalid from nft
            return 0;
        }
        //success
        emit NFTReceived(operator, from, tokenId, data);
        return
            bytes4(
                keccak256("onERC721Received(address,address,uint256,bytes)")
            );
    }

    function _completePurchase(uint256 _id) private {
        MarketData storage marketData = markets[_id];
        marketData.nft.safeTransferFrom(
            address(this),
            msg.sender,
            marketData.tokenId
        );
        posi.transfer(marketData.seller, marketData.price);
        marketData.isSold = true;
        marketData.purchaser = msg.sender;
        emit MarketPurchased(_id, msg.sender);
    }
}
