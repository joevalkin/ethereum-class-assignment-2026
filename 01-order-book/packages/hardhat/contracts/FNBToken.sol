// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Inheriting ERC20 gives standard token functions like transfer,
// approve and transferFrom without building them from scratch.

// FNBToken represents FNB eBucks (FNBT).
// It is the quote token in the order book, meaning it is used to pay for PNP tokens.
contract FNBToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Mint the starting supply to the deployer for testing and trading.
        _mint(msg.sender, initialSupply);
    }
}