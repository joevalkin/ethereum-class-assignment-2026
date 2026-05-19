// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";

// Local minimal interface for the PositionManager.
// The full IPositionManager inherits IPermit2Forwarder, which imports from the
// "permit2" npm package — a transitive dep that isn't installed in this workspace.
// We only need four functions, so we declare them directly to avoid that import chain.
interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    // permit2() is a public immutable on Permit2Forwarder (PositionManager's base).
    function permit2() external view returns (address);
}

// RewardTokensManager creates a Uniswap v4 liquidity pool for PNPT/FNBT and lets
// anyone mint a concentrated liquidity position inside it.
contract RewardTokensManager is Ownable {
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------
    // Constants — pool parameters required by the assignment
    // -------------------------------------------------------------------------

    // 0.3% swap fee. LPs earn this on every swap that passes through their range.
    uint24 public constant FEE_TIER = 3000;

    // Tick spacing controls granularity of price ranges. 60 pairs with the 0.3% fee tier.
    // Tick spacing affects how concentrated liquidity can be.
    // Smaller spacing gives LPs more control over narrow price ranges,
    // while larger spacing results in broader liquidity ranges.
    int24 public constant TICK_SPACING = 60;

    // No hooks — pool runs vanilla AMM logic with no custom lifecycle callbacks.
    // We use no hooks for this assignment, so the pool behaves like a standard AMM without custom logic before or after swaps/liquidity changes.
    // Hooks are an advanced v4 feature that let you run custom code at key points in the swap and liquidity change process.
    address public constant HOOKS = address(0);

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------


    
    // PoolManager is the main Uniswap v4 contract that stores pool state and handles things like pool creation, swaps and liquidity updates.
    // In v4 the pool itself is not a separate contract like older AMMs.
    // PoolManager is the singleton that stores and updates the state for many pools.
    IPoolManager public poolManager;
    // PositionManager handles minting and tracking liquidity positions (NFTs) for LPs who add liquidity to the pool.
    // A v4 pool is identified by more than just the two tokens.
    // The fee, tick spacing and hooks (not used here) are also part of the pool identity.
    IPositionManager public positionManager;

    // Permit2 address read from the PositionManager at construction time.
    // PositionManager calls permit2.transferFrom when settling token deltas.
    address private permit2Addr;

    // Raw addresses stored so we can sort them without extra unwrap calls.
    address public pnpToken;
    address public fnbToken;

    // The canonical pool key is built once in createPool and reused everywhere.
    PoolKey private poolKey;

    // Tracks which pools this contract has initialised so callers can verify.
    mapping(bytes32 => bool) public createdPools;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // Emitted when the PNPT/FNBT pool is initialised in the PoolManager.
    event PoolCreated(
        bytes32 poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    // Emitted after a liquidity position is successfully minted via PositionManager.
    event LiquidityMinted(
        bytes32 poolId,
        uint256 positionId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    // The assignment requires liquidity to cover the 1 FNBT = 10 PNPT implied price.
    // If the chosen range sits entirely above or below that tick, reject it.
    error TickRangeDoesNotCoverAssignmentPrice();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);

        // Read Permit2 from the PositionManager so we can approve it later.
        // Avoids needing a fifth constructor arg while keeping the address correct.
        permit2Addr = IPositionManager(_positionManager).permit2();

        pnpToken = _pnpToken;
        fnbToken = _fnbToken;
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    // Returns the keccak256 pool identifier derived from the stored pool key.
    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(poolKey.toId());
    }

    // Returns the two token addresses in canonical (sorted) order.
    function getCanonicalCurrencies() public view returns (address, address) {
        return (Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
    }
    // Converts the assignment price assumption (1 FNBT = 10 PNPT) into the target tick the pool should trade around in Uniswap. This is the mathematics below:
    // Returns the tick that represents 1 FNBT = 10 PNPT in ZAR notional terms.
    // price = 1.0001^tick where price = token1/token0 in pool terms.
    // If PNPT is currency0 and FNBT is currency1:
    //   price = FNBT per PNPT = 0.10/0.01 = 0.1 => tick = ln(0.1)/ln(1.0001) ≈ -23027
    // If FNBT is currency0 and PNPT is currency1:
    //   price = PNPT per FNBT = 0.01/0.10 = 10 => tick = ln(10)/ln(1.0001) ≈ 23027
    function getTargetTick() public view returns (int24) {
        if (Currency.unwrap(poolKey.currency0) == pnpToken) {
            return -23027;
        } else {
            return 23027;
        }
    }

    // -------------------------------------------------------------------------
    // Pool creation
    // -------------------------------------------------------------------------

    // onlyOwner prevents anyone from reinitialising the pool at a different price and invalidating existing positions. One pool, one owner, one starting price which is kind of like a built in security layer.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        // Uniswap v4 requires currency0 < currency1 by raw address value.
        // Sort at creation time so every subsequent call uses the canonical order.
        (Currency cur0, Currency cur1) = pnpToken < fnbToken
            ? (Currency.wrap(pnpToken), Currency.wrap(fnbToken))
            : (Currency.wrap(fnbToken), Currency.wrap(pnpToken));
// PoolKey uniquely identifies a Uniswap pool.
// The token pair, fee tier, tick spacing and hooks must all match to interact with the same pool.
        poolKey = PoolKey({
            currency0: cur0,
            currency1: cur1,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOKS)
        });

        poolId = PoolId.unwrap(poolKey.toId());

        // Initialize registers the pool inside the singleton PoolManager and sets the starting sqrtPrice so swaps immediately know the exchange rate.
        poolManager.initialize(poolKey, sqrtPriceX96);

        createdPools[poolId] = true;
// Emit the pool details so it is easy to verify the correct pool was created.
        emit PoolCreated(
            poolId,
            Currency.unwrap(cur0),
            Currency.unwrap(cur1),
            FEE_TIER,
            TICK_SPACING,
            HOOKS,
            sqrtPriceX96
        );
    }

    // -------------------------------------------------------------------------
    // Liquidity minting
    // -------------------------------------------------------------------------

    // Mints a concentrated liquidity NFT position in the PNPT/FNBT pool.
    // The position is owned by msg.sender, not this contract.
    // Any tokens not consumed by the mint are refunded.
    // Steps follow the assignment comment markers 1) – 9).
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId_) {
        // 1) Validate inputs
        require(amount0Desired > 0 || amount1Desired > 0, "Amounts cannot both be zero");
        require(tickLower < tickUpper, "tickLower must be less than tickUpper");
        // Ticks must land on the tick-spacing grid; misaligned ticks are rejected by the pool.
        require(tickLower % TICK_SPACING == 0 && tickUpper % TICK_SPACING == 0, "Ticks not aligned to spacing");

        // 2) Ensure the range covers the assignment-implied price.
        // LPs only earn fees while the price trades inside their range, so the range
        // must include the economically meaningful tick or the position is incoherent.
        int24 targetTick = getTargetTick();
        if (tickLower > targetTick || tickUpper <= targetTick) {
            revert TickRangeDoesNotCoverAssignmentPrice();
        }

        // 3) Resolve the pool id
        poolId_ = PoolId.unwrap(poolKey.toId());

        // 4) Compute liquidity from desired amounts at the current pool price.
        // getLiquidityForAmounts handles all cases: price below range (only token1 needed),
        // price above range (only token0 needed), or price inside range (both needed).
        (uint160 sqrtPriceX96Current,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96Current,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        // 5) Pull the desired amounts from the caller into this contract.
        // The caller must approve this contract on both tokens before calling.
        if (amount0Desired > 0) {
            IERC20(Currency.unwrap(poolKey.currency0)).transferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(Currency.unwrap(poolKey.currency1)).transferFrom(msg.sender, address(this), amount1Desired);
        }

        // 6) Approve Permit2 so PositionManager can settle token deltas from this contract.
        // When modifyLiquidities runs, PositionManager calls permit2.transferFrom(address(this), poolManager, amount, token).
        // Permit2 checks IERC20.allowance(address(this), permit2), so we approve here.
        IERC20(Currency.unwrap(poolKey.currency0)).approve(permit2Addr, type(uint256).max);
        IERC20(Currency.unwrap(poolKey.currency1)).approve(permit2Addr, type(uint256).max);

        // 7) Prepare and execute the PositionManager mint.
        // Read nextTokenId before the call — that is the id the new position will receive.
        positionId = positionManager.nextTokenId();

        // Actions are packed as single bytes; each byte maps to an Actions constant.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION: creates the NFT position on the pool in the given tick range.
        // msg.sender is passed as the literal owner so the NFT goes to the caller, not this contract.
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired),  // amount0Max — slippage upper bound
            uint128(amount1Desired),  // amount1Max — slippage upper bound
            msg.sender,               // NFT recipient
            bytes("")                 // no hook data
        );

        // SETTLE_PAIR: tells PositionManager to pay the token deltas owed to the pool
        // by pulling from this contract via Permit2.
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        // unlockData = abi.encode(actions, params) — the format BaseActionsRouter expects.
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);

        // 8) Verify mint succeeded.
        // getPositionLiquidity confirms the PositionManager recorded liquidity for this id.
        uint128 actualLiquidity = positionManager.getPositionLiquidity(positionId);
        require(actualLiquidity > 0, "Mint produced zero liquidity");

        // 9) Return any unspent token dust and emit the assignment event.
        // When the pool price is outside the tick range only one token is consumed;
        // the other sits unused in this contract and must be returned to the caller.
        uint256 dust0 = IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this));
        uint256 dust1 = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this));
        if (dust0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).transfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).transfer(msg.sender, dust1);

        emit LiquidityMinted(poolId_, positionId, msg.sender, tickLower, tickUpper, actualLiquidity);
    }
}
