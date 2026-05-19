// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OrderBook {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Data types
    // -------------------------------------------------------------------------

    // Represents a single buy or sell order with the relevant information related to the trade.
    struct Order {
        address trader;    // who placed the order — only they can cancel it
        uint8 orderType;   // 0 = buy (wants tokenA, pays tokenB), 1 = sell (offers tokenA, wants tokenB)
        uint256 amount;    // original quantity of tokenA in the order
        uint256 filled;    // tracks how much of the order has already gone through
        uint256 price;     // tokenB per tokenA (e.g. price=2 means 2 FNB per PNP)
        bool open;         // false once fully matched or cancelled
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    // tokenA is PNPToken — the base asset being bought and sold.
    IERC20 public tokenA;

    // tokenB is FNBToken — the quote currency used to price tokenA.
    IERC20 public tokenB;

    // All orders ever placed. The array index is the orderId.
    Order[] public orders;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error InvalidAmount();
    error InvalidPrice();
    error InvalidAddress();
    error PriceMismatch();
    error OrderTypeMismatch();
    error OrderNotOpen();
    error UnauthorizedCancellation();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // Emitted when a new buy or sell order is placed.
    // tokenIn  = the token the placer deposits into escrow.
    // tokenOut = the token the placer expects to receive when matched.
    event OrderPlaced(
        uint256 orderId,
        address trader,
        uint8 orderType,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 price
    );

    // Emitted when two orders are matched (fully or partially).
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId, uint256 matchedAmount);

    // Emitted when an open order is cancelled and the escrowed tokens are refunded.
    event OrderCanceled(uint256 orderId);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    // Set the token pair for this order book.
    // PNP is what users trade and FNB is what they pay with.
    constructor(address _tokenA, address _tokenB) {
        // Fail at deployment rather than failing silently on every later call.
        if (_tokenA == address(0) || _tokenB == address(0)) revert InvalidAddress();
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // -------------------------------------------------------------------------
    // Order placement
    // -------------------------------------------------------------------------

    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();
        // Funds are locked in the contract first so trades can happen without needing to trust the other side.
        // Pull amount * price of tokenB from the buyer into escrow.
        // This locks the full payment upfront so the buyer cannot spend it before matching.
        tokenB.safeTransferFrom(msg.sender, address(this), amount * price);

        orderId = orders.length;
        orders.push(Order({
            trader: msg.sender,
            orderType: 0,
            amount: amount,
            filled: 0,
            price: price,
            open: true
        }));

        // tokenIn = tokenB (what the buyer deposits), tokenOut = tokenA (what they receive).
        emit OrderPlaced(orderId, msg.sender, 0, address(tokenB), address(tokenA), amount, price);
    }

    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount == 0) revert InvalidAmount();
        if (price == 0) revert InvalidPrice();
        // Seller locks the tokens first so the trade can happen without needing to trust the other side.
        // Pull amount of tokenA from the seller into escrow.
        // The seller commits their tokens so they cannot be sold elsewhere before matching.
        tokenA.safeTransferFrom(msg.sender, address(this), amount);

        orderId = orders.length;
        orders.push(Order({
            trader: msg.sender,
            orderType: 1,
            amount: amount,
            filled: 0,
            price: price,
            open: true
        }));

        // tokenIn = tokenA (what the seller deposits), tokenOut = tokenB (what they receive).
        emit OrderPlaced(orderId, msg.sender, 1, address(tokenA), address(tokenB), amount, price);
    }

    // -------------------------------------------------------------------------
    // Order queries
    // -------------------------------------------------------------------------
    // Tracking amount still left in the order after previous matches.
    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].amount - orders[orderId].filled;
    }

    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].open;
    }

    // -------------------------------------------------------------------------
    // Order matching and cancellation
    // -------------------------------------------------------------------------

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        // Prevent matching against orders that are already fully filled or cancelled.
        if (!buyOrder.open || !sellOrder.open) revert OrderNotOpen();

        // Prevent accidentally passing IDs in the wrong order, which would corrupt escrow accounting.
        if (buyOrder.orderType != 0 || sellOrder.orderType != 1) revert OrderTypeMismatch();

        // No trade if buyer is offering less than what the seller wants.
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // The trade quantity is the smaller of what each side still needs filled. 
        // Example: buy 10, sell 4 = only 4 gets matched.
        uint256 buyRemaining = buyOrder.amount - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;
        uint256 matchedAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        buyOrder.filled += matchedAmount;
        sellOrder.filled += matchedAmount;

        // Close an order once it is fully filled.
        if (buyOrder.filled == buyOrder.amount) buyOrder.open = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.open = false;

        // Release escrowed tokenA to the buyer.
        tokenA.safeTransfer(buyOrder.trader, matchedAmount);

        // Release escrowed tokenB payment to the seller (quantity × price).
        tokenB.safeTransfer(sellOrder.trader, matchedAmount * sellOrder.price);

        emit OrderMatched(buyOrderId, sellOrderId, matchedAmount);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        if (msg.sender != order.trader) revert UnauthorizedCancellation();
        if (!order.open) revert OrderNotOpen();

        //  Refund whatever part of the order never got matched.
        uint256 refundAmount = order.amount - order.filled;
        order.open = false;

        if (order.orderType == 0) {
            // Buyer deposits FNBT first so the money is already there if a trade happens.
            tokenB.safeTransfer(order.trader, refundAmount * order.price);
        } else {
            //Seller locks tokens in the contract so they cannot promise tokens they do not have.
            tokenA.safeTransfer(order.trader, refundAmount);
        }

        emit OrderCanceled(orderId);
    }
}
