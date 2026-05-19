// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Inheriting ERC20 gives standard token functions like transfer,
// approve and transferFrom without building them from scratch.

// FNBToken represents FNB eBucks (FNBT).
// Used as one side of the PNPT/FNBT liquidity pool in this assignment.
contract FNBToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        // Mint the starting supply to the deployer for testing and trading.
        _mint(msg.sender, initialSupply);
    }
}
