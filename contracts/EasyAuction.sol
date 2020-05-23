pragma solidity >=0.6.8;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./libraries/IterableOrderedOrderSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libraries/IdToAddressBiMap.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";


contract EasyAuction {
  using SafeMath for uint64;
  using SafeMath for uint96;
  using SafeMath for uint256;
  using SafeCast for uint256;
  using IterableOrderedOrderSet for IterableOrderedOrderSet.Data;
  using IterableOrderedOrderSet for bytes32;
  using IdToAddressBiMap for IdToAddressBiMap.Data;

  modifier atStageOrderplacement(uint256 auctionId) {
    require(
      block.timestamp < auctionData[auctionId].auctionEndDate,
      "Auction no longer in order placement phase"
    );
    _;
  }

  modifier atStageSolutionSubmission(uint256 auctionId) {
    require(
      block.timestamp > auctionData[auctionId].auctionEndDate &&
        auctionData[auctionId].clearingPriceOrder == bytes32(0),
      "Auction not in solution submission phase"
    );
    _;
  }

  modifier atStageFinished(uint256 auctionId) {
    require(
      auctionData[auctionId].clearingPriceOrder != bytes32(0),
      "Auction not yet finished"
    );
    _;
  }

  event NewBuyOrders(
    uint256 indexed auctionId,
    uint64 indexed userId,
    uint96[] sellAmountOfBuy,
    uint96[] buyAmountOfBuy
  );
  event NewAuction(
    uint256 auctionId,
    ERC20 indexed _sellToken,
    ERC20 indexed _buyToken
  );
  event UserRegistration(address user, uint64 userId);

  struct AuctionData {
    ERC20 sellToken;
    ERC20 buyToken;
    uint256 auctionEndDate;
    bytes32 sellOrder;
    bytes32 clearingPriceOrder;
    uint96 volumeClearingPriceOrder;
  }
  mapping(uint256 => IterableOrderedOrderSet.Data) public buyOrders;
  mapping(uint256 => AuctionData) public auctionData;
  IdToAddressBiMap.Data private registeredUsers;
  uint64 public numUsers;
  address public donationAccount;
  uint256 public auctionCounter;

  constructor() public {
    donationAccount = msg.sender;
  }

  function initiateAuction(
    ERC20 _sellToken,
    ERC20 _buyToken,
    uint256 duration,
    uint96 _sellAmount,
    uint96 _buyAmount
  ) public returns (uint256) {
    uint64 userId = getUserId(msg.sender);
    require(
      _sellToken.transferFrom(msg.sender, address(this), _sellAmount),
      "transfer was not successful"
    );
    auctionCounter++;
    auctionData[auctionCounter] = AuctionData(
      _sellToken,
      _buyToken,
      block.timestamp + duration,
      IterableOrderedOrderSet.encodeOrder(userId, _sellAmount, _buyAmount),
      bytes32(0),
      0
    );
    emit NewAuction(auctionCounter, _sellToken, _buyToken);
    return auctionCounter;
  }

  function placeBuyOrders(
    uint256 auctionId,
    uint96[] memory _buyAmount,
    uint96[] memory _sellAmount,
    bytes32[] memory _prevBuyOrders
  ) public atStageOrderplacement(auctionId) {
    (
      ,
      uint96 sellAmountOfSellOrder,
      uint96 buyAmountOfSellOrder
    ) = auctionData[auctionId].sellOrder.decodeOrder();
    uint256 sumOfBuyAmounts = 0;
    uint64 userId = getUserId(msg.sender);
    for (uint256 i = 0; i < _buyAmount.length; i++) {
      sumOfBuyAmounts = sumOfBuyAmounts.add(_buyAmount[i]);
      require(
        _buyAmount[i].mul(buyAmountOfSellOrder) <
          sellAmountOfSellOrder.mul(_sellAmount[i]),
        "limit price not better than mimimal offer"
      );
      buyOrders[auctionId].insert(
        IterableOrderedOrderSet.encodeOrder(
          userId,
          _sellAmount[i],
          _buyAmount[i]
        ),
        _prevBuyOrders[i]
      );
    }
    emit NewBuyOrders(auctionId, userId, _buyAmount, _sellAmount);
    require(
      auctionData[auctionId].buyToken.transferFrom(
        msg.sender,
        address(this),
        sumOfBuyAmounts
      ),
      "transfer was not successful"
    );
  }

  function calculatePrice(uint256 auctionId)
    public
    atStageSolutionSubmission(auctionId)
    returns (uint96 priceNumerator, uint96 priceDenominator)
  {
    (, uint96 sellAmount, ) = auctionData[auctionId].sellOrder.decodeOrder();

    // Search for single partically filled order or last fully filled order:
    uint96 sumBuyAmount = 0;
    bytes32 iterOrder = IterableOrderedOrderSet.QUEUE_START;
    bool buyAmountExceedsSellAmount = true;
    while (sumBuyAmount < sellAmount) {
      iterOrder = buyOrders[auctionId].next(iterOrder);
      if (iterOrder == IterableOrderedOrderSet.QUEUE_END) {
        buyAmountExceedsSellAmount = false;
        break;
      }
      (, , uint96 buyAmountOfIter) = iterOrder.decodeOrder();
      sumBuyAmount = uint96(sumBuyAmount.add(buyAmountOfIter)); // todo check correctness
    }

    // Store result:
    bytes32 clearingPriceOrder = iterOrder;
    if (!buyAmountExceedsSellAmount) {
      clearingPriceOrder = auctionData[auctionId].sellOrder;
      auctionData[auctionId].volumeClearingPriceOrder = uint96(sumBuyAmount);
    } else {
      auctionData[auctionId].volumeClearingPriceOrder = uint96(
        sumBuyAmount.sub(sellAmount)
      );
    }
    auctionData[auctionId].clearingPriceOrder = clearingPriceOrder;
    (, priceNumerator, priceDenominator) = clearingPriceOrder.decodeOrder();
  }

  function claimFromBuyOrder(uint256 auctionId, bytes32[] memory orders)
    public
    atStageFinished(auctionId)
    returns (uint256 sumSellToken, uint256 sumBuyToken)
  {
    AuctionData memory auction = auctionData[auctionId];
    (uint64 userId, uint96 priceDenominator, uint96 priceNumerator) = auction
      .clearingPriceOrder
      .decodeOrder();
    for (uint256 i = 0; i < orders.length; i++) {
      (, , uint96 buyAmount) = orders[i].decodeOrder();
      if (orders[i] == auction.clearingPriceOrder) {
        sumSellToken = sumSellToken.add(
          auction.volumeClearingPriceOrder.mul(priceNumerator).div(
            priceDenominator
          )
        );
        sumBuyToken = sumBuyToken.add(
          buyAmount.sub(auction.volumeClearingPriceOrder)
        );
      } else {
        if (orders[i].biggerThan(auction.clearingPriceOrder)) {
          sumSellToken = sumSellToken.add(
            buyAmount.mul(priceNumerator).div(priceDenominator)
          );
        } else {
          sumBuyToken = sumBuyToken.add(buyAmount);
        }
      }
    }
    sendOutTokens(auctionId, sumSellToken, sumBuyToken, userId);
  }

  function claimFromSellOrder(uint256 auctionId)
    public
    atStageFinished(auctionId)
    returns (uint256 sumSellToken, uint256 sumBuyToken)
  {
    (
      uint64 userId,
      uint96 sellAmount,
      uint96 buyAmount
    ) = auctionData[auctionId].sellOrder.decodeOrder();
    if (
      auctionData[auctionId].sellOrder ==
      auctionData[auctionId].clearingPriceOrder
    ) {
      sumSellToken = sellAmount.sub(
        auctionData[auctionId].volumeClearingPriceOrder
      );
      sumBuyToken = auctionData[auctionId]
        .volumeClearingPriceOrder
        .mul(buyAmount)
        .div(sellAmount);
    } else {
      (
        ,
        uint96 priceDenominator,
        uint96 priceNumerator
      ) = IterableOrderedOrderSet.decodeOrder(
        auctionData[auctionId].clearingPriceOrder
      );
      sumBuyToken = sellAmount.mul(priceNumerator).div(priceDenominator);
    }
    sendOutTokens(auctionId, sumSellToken, sumBuyToken, userId);
  }

  function sendOutTokens(
    uint256 auctionId,
    uint256 sellTokenAmount,
    uint256 buyTokenAmount,
    uint64 userId
  ) internal {
    address userAddress = registeredUsers.getAddressAt(userId);
    require(
      auctionData[auctionId].sellToken.transfer(userAddress, sellTokenAmount),
      "Claim transfer for sellToken failed"
    );
    require(
      auctionData[auctionId].buyToken.transfer(userAddress, buyTokenAmount),
      "Claim transfer for sellToken failed"
    );
  }

  function registerUser(address user) public returns (uint64 userId) {
    require(registeredUsers.insert(numUsers, user), "User already registered");
    userId = numUsers;
    numUsers = numUsers.add(1).toUint64();
    emit UserRegistration(user, userId);
  }

  function getUserId(address user) public returns (uint64 userId) {
    if (registeredUsers.hasAddress(user)) {
      return registeredUsers.getId(user);
    } else {
      return registerUser(user);
    }
  }

  function getSecondsRemainingInBatch(uint256 auctionId)
    public
    view
    returns (uint256)
  {
    if (auctionData[auctionId].auctionEndDate < block.timestamp) {
      return 0;
    }
    return auctionData[auctionId].auctionEndDate.sub(block.timestamp);
  }
}
