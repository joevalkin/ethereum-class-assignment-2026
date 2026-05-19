// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Inheriting ERC20 gives standard token functions like transfer,
// approve and transferFrom without building them from scratch.

// PNPToken represents Pick n Pay loyalty points (PNPT).
// Used as one side of the PNPT/FNBT liquidity pool in this assignment.
contract PNPToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        // Assign the entire supply to the deployer so they can distribute tokens as needed.
        _mint(msg.sender, initialSupply);
    }
}
