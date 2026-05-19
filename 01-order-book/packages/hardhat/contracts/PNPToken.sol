// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// Inheriting ERC20 gives standard token functions like transfer,
// approve and transferFrom without building them from scratch.
// PNPToken represents Pick n Pay loyalty points (PNPT).
// It is the base token in the order book ie. the asset being bought and sold.
contract PNPToken is ERC20 {
    // The constructor runs once at deployment.
    // initialSupply is passed in by the deployer (the test uses 1,000,000 * 10^18).
    // ERC20("PNP Token", "PNPT") sets the human-readable name and ticker symbol.
    // These exact strings are what the Part 1 tests assert against.
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        // Assign the entire supply to the deployer so they can distribute tokens as needed.
        _mint(msg.sender, initialSupply);
    }
}
