// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ISonaxFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface ISonaxPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface ISonaxRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @notice Receiver for the quote tokens from a backflow swap.
/// PancakeSwap rejects a swap `to` that is a token in the pair (INVALID_TO),
/// so quote tokens land here first and the token contract pulls them back.
/// Only the token contract can operate this receiver.
contract SonaxQuoteReceiver {
    using SafeERC20 for IERC20;

    address public immutable token;

    constructor() {
        token = msg.sender;
    }

    function sweep(IERC20 quote) external returns (uint256 amount) {
        require(msg.sender == token, "only token");
        amount = quote.balanceOf(address(this));
        if (amount > 0) quote.safeTransfer(token, amount);
    }
}

/// @title SonaxToken
/// @notice Sonax token: 10 billion total supply, minted once at construction, no further minting.
///
/// Allocation: 95% mining pool, 3% LP liquidity build, 1% marketing, 1% market-cap management.
///
/// Fees (rates are constants and cannot be changed):
/// - Buy (transfer out of a pair): 0%
/// - Sell (transfer into a pair): 10% = 3% burn + 5% marketing (sent to marketing wallet) + 2% backflow to the pool
/// - Wallet-to-wallet transfers: 0%, unrestricted before and after trading opens
///
/// Unified dead address: burned SONAX and LP from backflow both go to the same `DEAD` (`0x…dEaD`).
/// Do not use `address(0)`, so there is a single sink instead of separate "zero-address burn" vs "dead address" stories.
///
/// The quote token (e.g. Alpha X) may be set in the constructor, or passed as `address(0)` and set later once
/// by the owner via `setQuoteToken(factory, quote)`, which also creates the main pair.
/// Until set, trading cannot open and backflow cannot run.
///
/// "Pair" means: the main pair (registered by `setQuoteToken` / constructor), plus any other pool the owner
/// registers by hand. There is NO automatic detection: a pool that is not registered is an ordinary address
/// (no pre-open restriction, no sell tax), so the owner must register every extra pool that gets liquidity.
/// - `setAmmPair(pool, true)`: V2-style pool. A sell is a transfer into it; the pool receives 90%.
/// Uniswap V3 / PancakeSwap V3 style pools are NOT supported: their swap callback demands the exact amount owed and
/// a fee-on-transfer token cannot satisfy it (the same is true for every taxed token). Do not register them.
/// Vault-style pools (Balancer, Pancake Infinity, Uniswap V4 PoolManager, etc.) can be registered with
/// `setAmmPair` too; the vault itself is then treated as the pair.
///
/// Backflow: the 2% sell tax accumulates in this contract. Once the threshold is met, backflow sells half for
/// quote, adds both sides as liquidity, LP to `DEAD`. Two ways to run it:
/// - inline auto-backflow on ordinary transfers (the normal path): once backflow is due, a non-pair ordinary
///   transfer runs it and needs ~600k gas available. If it does not have that, the transfer REVERTS
///   (`InsufficientGasForBackflow`) so that wallets' `eth_estimateGas` sees the cost and sends enough gas. The
///   first sender after it becomes due pays ~250k extra gas. Owner can remove this behaviour with
///   `setAutoBackflow(false)`;
/// - `processBackflow(minOut)`: owner only, no threshold/cap, process everything (catch-up, or slippage-protected).
/// Inline auto-backflow: a non-pair ordinary transfer triggers it.
/// Buy, sell, add-liquidity, and remove-liquidity transfers never run backflow, so it cannot interrupt a user's
/// add-liquidity and change pool reserves mid-flight. Auto-backflow guards:
/// 1) When due and the remaining gas is insufficient, the transfer reverts `InsufficientGasForBackflow` (see
///    above); when gas is enough, internal failures are swallowed by try/catch and only counted/emitted
///    (`autoBackflowFailures`, monitoring only);
/// 2) Auto-backflow never turns itself off. It keeps retrying on every eligible transfer; if the pool or quote
///    token is persistently broken, the owner can pause it with `setAutoBackflow(false)` and resume later;
/// 3) Per-run amount ≤ 0.1% of this token held in the pool;
/// 4) Skip when the pair has pending quote deposits (another contract mid add-liquidity with quote transferred first).
/// Only the owner may call `processBackflow(minOut)` manually; it works even while auto-backflow is paused.
/// Whitelist cannot trigger manual backflow. There is no rescue function:
/// stray tokens are added to the pool during backflow.
///
/// Before trading opens: transfers involving a pair require whitelist. `openTrading` is one-shot.
/// Whitelist: may touch the pool before open and is exempt from sell tax; dapp adapters should be whitelisted
/// (needs audit). Pairs must not be whitelisted.
///
/// Owner: openTrading, setQuoteToken, setWhitelist, setAmmPair, setMarketingWallet, setAutoBackflow,
/// processBackflow, transferOwnership / renounceOwnership. No mint, blacklist, or fee changes.
contract SonaxToken is ERC20, Ownable, ReentrancyGuard {
    string private constant _NAME = "Sonax";
    string private constant _SYMBOL = "SONAX";
    using SafeERC20 for IERC20;

    /// @notice 10 billion tokens, 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 ether;

    uint256 public constant BPS = 10_000;
    /// @notice Sell-tax split in basis points: 3% burn, 2% backflow, 5% marketing (10% total).
    uint256 public constant SELL_BURN_BPS = 300;
    uint256 public constant SELL_BACKFLOW_BPS = 200;
    uint256 public constant SELL_MARKETING_BPS = 500;
    /// @notice Buy fee is 0.
    uint256 public constant BUY_FEE_BPS = 0;

    /// @notice Auto-backflow trigger: contract balance ≥ pool balance of this token / 2000.
    uint256 public constant AUTO_BACKFLOW_THRESHOLD_DIV = 2000;
    /// @notice Auto-backflow per-run cap: pool balance of this token / 1000.
    uint256 public constant AUTO_BACKFLOW_CAP_DIV = 1000;
    /// @notice Gas budget for the auto-backflow subcall (~270k observed for one backflow on real Pancake/Uniswap V2).
    uint256 public constant AUTO_BACKFLOW_GAS = 450_000;
    /// @notice Gas reserved for the rest of this transfer. Skip backflow if gasleft < AUTO_BACKFLOW_GAS + this,
    /// so even if backflow burns its entire gas budget, the remaining transfer steps still succeed.
    uint256 public constant AUTO_BACKFLOW_RESERVE_GAS = 150_000;

    /// @notice Unified dead address: sell-tax burned SONAX and backflow LP both go here.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ISonaxRouter public immutable router;
    /// @notice Quote token of the main pair (e.g. Alpha X); may be 0 until owner `setQuoteToken`.
    address public quoteToken;
    /// @notice Main pair; 0 until quote token is set.
    address public pair;
    SonaxQuoteReceiver public immutable quoteReceiver;

    address public marketingWallet;
    bool public tradingOpen;

    mapping(address => bool) private _whitelist;

    /// @notice Addresses treated as AMM pairs. Transfers to/from them are whitelist-gated before open,
    /// and transfers in take sell tax. The main pair is registered at construction / `setQuoteToken`;
    /// every other pool must be registered by the owner (no auto-detection, see contract header).
    mapping(address => bool) public isAmmPair;
    /// True while auto-backflow is running, so transfers inside backflow do not re-enter it.
    bool private _inBackflow;
    /// @notice Owner switch for auto-backflow (default on). Manual `processBackflow` is unaffected.
    bool public autoBackflowEnabled = true;
    /// @notice Auto-backflow failures since the last success (auto or manual). Monitoring only; it never
    /// disables auto-backflow.
    uint256 public autoBackflowFailures;

    // Cumulative stats, monotonic, for frontend display.
    /// @notice SONAX burned via sell tax (cumulative).
    uint256 public totalBurned;
    /// @notice SONAX added to the pool via backflow (swap half + liquidity half, cumulative).
    uint256 public totalBackflowToken;
    /// @notice Quote token added to the pool via backflow (cumulative).
    uint256 public totalBackflowQuote;
    /// @notice LP locked to the dead address via backflow (cumulative).
    uint256 public totalLpLocked;

    event TradingOpened();
    event QuoteTokenSet(address indexed quoteToken, address indexed pair);
    event WhitelistUpdated(address indexed account, bool allowed);
    event MarketingWalletUpdated(address indexed wallet);
    event AmmPairUpdated(address indexed ammPair, bool enabled);
    event AutoBackflowToggled(bool enabled);
    /// @notice Auto-backflow failed (swallowed; the ordinary transfer that triggered it still succeeds).
    /// `consecutiveFailures` counts failures since the last success; it is informational and never stops retries.
    event AutoBackflowFailed(uint256 consecutiveFailures);
    /// @notice Backflow completed. tokenUsed includes the swap half plus the amount actually added as liquidity.
    event BackflowProcessed(uint256 tokenUsed, uint256 quoteAdded, uint256 liquidity);

    error ZeroAddress();
    error InvalidAccount();
    error OnlySelf();
    error TradingNotOpen();
    error AlreadyOpen();
    error NoLiquidity();
    error NothingToProcess();
    /// @notice A plain transfer arrived while backflow is due but the gas left cannot cover it. Resend with more gas
    /// (wallets pick it up automatically via eth_estimateGas). If a fixed-gas integration is blocked, the owner can
    /// clear the due amount with `processBackflow` or pause the revert with `setAutoBackflow(false)`.
    error InsufficientGasForBackflow();
    error QuoteNotSet();
    error QuoteAlreadySet();

    /// @param initialOwner Admin; also whitelisted.
    /// @param factory PancakeSwap V2 Factory; required when `quoteToken_` is non-zero, to create the main pair.
    /// @param router_ PancakeSwap V2 Router (used for backflow).
    /// @param quoteToken_ Other side of the main pair (e.g. Alpha X). Pass `address(0)` to set later via `setQuoteToken`.
    /// @param miningPool Mining pool; receives 95%.
    /// @param lpWallet LP wallet; receives 3%; whitelisted.
    /// @param marketing Marketing wallet; receives 1%; also receives the marketing portion of sell tax.
    /// @param marketCap Market-cap management wallet; receives 1%; whitelisted.
    constructor(
        address initialOwner,
        address factory,
        address router_,
        address quoteToken_,
        address miningPool,
        address lpWallet,
        address marketing,
        address marketCap
    ) ERC20(_NAME, _SYMBOL) Ownable(initialOwner) {
        if (
            router_ == address(0) || miningPool == address(0) || lpWallet == address(0) || marketing == address(0)
                || marketCap == address(0)
        ) revert ZeroAddress();
        if (quoteToken_ == address(this) || marketing == DEAD || miningPool == DEAD || lpWallet == DEAD || marketCap == DEAD)
        {
            revert InvalidAccount();
        }

        router = ISonaxRouter(router_);
        quoteReceiver = new SonaxQuoteReceiver();
        marketingWallet = marketing;

        if (quoteToken_ != address(0)) {
            _setQuoteToken(factory, quoteToken_);
        }

        _whitelist[initialOwner] = true;
        _whitelist[lpWallet] = true;
        _whitelist[marketCap] = true;

        // 95% / 3% / 1% / 1%
        _mint(miningPool, (TOTAL_SUPPLY * 95) / 100);
        _mint(lpWallet, (TOTAL_SUPPLY * 3) / 100);
        _mint(marketing, (TOTAL_SUPPLY * 1) / 100);
        _mint(marketCap, (TOTAL_SUPPLY * 1) / 100);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Whitelist check (includes this contract).
    function isWhitelisted(address account) public view returns (bool) {
        return _whitelist[account] || account == address(this);
    }

    /// @notice One-shot read of frontend display stats.
    /// @return burned Cumulative burn amount
    /// @return pendingBackflow SONAX pending backflow in this contract (sell-tax accrual plus direct transfers in)
    /// @return backflowToken Cumulative SONAX added to the pool via backflow
    /// @return backflowQuote Cumulative quote token added to the pool via backflow
    /// @return lpLocked Cumulative locked LP
    /// @return lpLockedOnPair Pair LP currently held by the dead address (on-chain balance)
    function getStats()
        external
        view
        returns (
            uint256 burned,
            uint256 pendingBackflow,
            uint256 backflowToken,
            uint256 backflowQuote,
            uint256 lpLocked,
            uint256 lpLockedOnPair
        )
    {
        burned = totalBurned;
        pendingBackflow = balanceOf(address(this));
        backflowToken = totalBackflowToken;
        backflowQuote = totalBackflowQuote;
        lpLocked = totalLpLocked;
        lpLockedOnPair = pair == address(0) ? 0 : IERC20(pair).balanceOf(DEAD);
    }

    // ---------------------------------------------------------------------
    // Admin (owner only)
    // ---------------------------------------------------------------------

    /// @notice Set the main-pair quote token and create/register the pair. Succeeds once only.
    /// Until set, `openTrading` / backflow are unavailable.
    function setQuoteToken(address factory_, address quoteToken_) external onlyOwner {
        _setQuoteToken(factory_, quoteToken_);
    }

    function _setQuoteToken(address factory_, address quoteToken_) private {
        if (quoteToken != address(0)) revert QuoteAlreadySet();
        if (factory_ == address(0) || quoteToken_ == address(0)) revert ZeroAddress();
        if (quoteToken_ == address(this) || quoteToken_ == DEAD) revert InvalidAccount();

        // Resolve and validate the pair BEFORE persisting anything, so a bad factory cannot leave
        // `quoteToken` set with `pair` unset (which would brick setQuoteToken / openTrading forever).
        address p = ISonaxFactory(factory_).getPair(address(this), quoteToken_);
        if (p == address(0)) {
            p = ISonaxFactory(factory_).createPair(address(this), quoteToken_);
        }
        if (p == address(0)) revert ZeroAddress();
        if (marketingWallet == p) revert InvalidAccount();

        quoteToken = quoteToken_;
        pair = p;
        isAmmPair[p] = true;
        emit QuoteTokenSet(quoteToken_, p);
        emit AmmPairUpdated(p, true);
    }

    /// @notice Open trading. One-shot; main pair must be set and already have liquidity.
    function openTrading() external onlyOwner {
        if (tradingOpen) revert AlreadyOpen();
        if (pair == address(0)) revert QuoteNotSet();
        (uint112 r0, uint112 r1,) = ISonaxPair(pair).getReserves();
        if (r0 == 0 || r1 == 0) revert NoLiquidity();
        tradingOpen = true;
        emit TradingOpened();
    }

    /// @notice Batch-set whitelist. Whitelisted addresses may trade with pairs before open and pay no sell tax.
    /// Known or registered pairs cannot be whitelisted, or anyone could buy from the pool before open.
    /// If a contract to whitelist was registered as a pair by mistake, clear it first with setAmmPair(addr, false).
    function setWhitelist(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            if (a == address(0)) revert ZeroAddress();
            if (isAmmPair[a]) revert InvalidAccount();
            _whitelist[a] = allowed;
            emit WhitelistUpdated(a, allowed);
        }
    }

    /// @notice Register or clear a V2-style pool (any pool that can take a 90% transfer, incl. vault-style
    /// contracts). The only way to add pools besides the main pair; there is no auto-detection.
    /// Once registered, treated like the main pair: whitelist-only before open; transfers in take sell tax
    /// (deducted from the amount, pool receives 90%). V3 / callback-style pools must not be registered.
    /// The main pair cannot be cleared; whitelist addresses, the marketing wallet, and this contract cannot be
    /// registered.
    function setAmmPair(address ammPair, bool enabled) external onlyOwner {
        if (ammPair == address(0)) revert ZeroAddress();
        if (ammPair == pair && !enabled) revert InvalidAccount();
        if (enabled && (ammPair == address(this) || isWhitelisted(ammPair) || ammPair == marketingWallet)) {
            revert InvalidAccount();
        }
        isAmmPair[ammPair] = enabled;
        emit AmmPairUpdated(ammPair, enabled);
    }

    /// @notice Pause / resume auto-backflow (e.g. while the pool or quote token is broken). Manual
    /// `processBackflow` is unaffected. Auto-backflow never pauses itself.
    function setAutoBackflow(bool enabled) external onlyOwner {
        autoBackflowEnabled = enabled;
        emit AutoBackflowToggled(enabled);
    }

    /// @notice Update the marketing wallet. Cannot be zero, dead, a known/registered pair, or this contract.
    function setMarketingWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        if (isAmmPair[wallet] || wallet == address(this) || wallet == DEAD) revert InvalidAccount();
        marketingWallet = wallet;
        emit MarketingWalletUpdated(wallet);
    }

    // ---------------------------------------------------------------------
    // Backflow / add liquidity
    // ---------------------------------------------------------------------

    /// @notice Owner manual backflow (day-to-day relies on auto). Swaps half of this contract's SONAX for quote,
    /// adds liquidity, LP → `DEAD`. Owner only; `minQuoteOut` is caller-computed anti-sandwich slippage.
    /// Reverts if quote is unset or trading is not open.
    function processBackflow(uint256 minQuoteOut) external onlyOwner nonReentrant {
        if (quoteToken == address(0) || pair == address(0)) revert QuoteNotSet();
        if (!tradingOpen) revert TradingNotOpen();

        uint256 amount = balanceOf(address(this));
        if (amount < 2) revert NothingToProcess();
        _backflow(amount, minQuoteOut);
        autoBackflowFailures = 0;
    }

    /// @notice Auto-backflow entry. Only callable by this contract, and only via try/catch on ordinary transfers;
    /// failure must not revert the transfer. No min-out: the contract cannot sandwich-protect from current reserves,
    /// so the per-run cap and sell tax make sandwiching unprofitable.
    function autoBackflow(uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _backflow(amount, 0);
    }

    function _backflow(uint256 amount, uint256 minQuoteOut) private {
        uint256 half = amount / 2;
        uint256 rest = amount - half;

        _approve(address(this), address(router), amount);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = quoteToken;

        router.swapExactTokensForTokens(half, minQuoteOut, path, address(quoteReceiver), block.timestamp);
        quoteReceiver.sweep(IERC20(quoteToken));
        uint256 quoteAll = IERC20(quoteToken).balanceOf(address(this));

        IERC20(quoteToken).forceApprove(address(router), quoteAll);
        (uint256 usedToken, uint256 usedQuote, uint256 liquidity) =
            router.addLiquidity(address(this), quoteToken, rest, quoteAll, 0, 0, DEAD, block.timestamp);

        // Clear leftover allowances; unused tokens stay for the next run.
        _approve(address(this), address(router), 0);
        IERC20(quoteToken).forceApprove(address(router), 0);

        totalBackflowToken += half + usedToken;
        totalBackflowQuote += usedQuote;
        totalLpLocked += liquidity;

        emit BackflowProcessed(half + usedToken, usedQuote, liquidity);
    }

    // ---------------------------------------------------------------------
    // Transfer logic
    // ---------------------------------------------------------------------

    /// @dev Attempt auto-backflow on a non-pair ordinary transfer.
    /// Skip when paused by the owner, the trigger is unmet, or the pair has pending quote deposits.
    /// When backflow is due but the remaining gas cannot cover it, REVERT (`InsufficientGasForBackflow`) instead of
    /// skipping silently: a wallet's `eth_estimateGas` binary-searches the smallest gas that succeeds, so a silent
    /// skip makes the estimate (~64k) miss the backflow cost and auto-backflow never runs; a revert forces the
    /// estimate (and therefore the sent gas limit) up to cover it. Whoever sends the first plain transfer after
    /// backflow becomes due pays for it (~250k extra gas). Emergency valves (owner): `setAutoBackflow(false)` removes
    /// this revert entirely; `processBackflow` clears the due amount so later transfers stay cheap.
    /// Internal backflow failures are swallowed so the transfer still succeeds. A failure never stops later
    /// attempts: the next eligible transfer simply tries again.
    function _tryAutoBackflow() private {
        if (!autoBackflowEnabled) return;

        uint256 amount = _dueBackflowAmount();
        if (amount == 0) return;

        // Another contract may be mid add-liquidity (quote transferred in, not yet minted). A backflow swap
        // would pull that quote into reserves and make the subsequent mint share 0 / fail. Skip if pending.
        if (_pendingQuoteDeposit()) return;

        if (gasleft() < AUTO_BACKFLOW_GAS + AUTO_BACKFLOW_RESERVE_GAS) revert InsufficientGasForBackflow();

        _inBackflow = true;
        try this.autoBackflow{gas: AUTO_BACKFLOW_GAS}(amount) {
            autoBackflowFailures = 0;
        } catch {
            autoBackflowFailures += 1;
            emit AutoBackflowFailed(autoBackflowFailures);
        }
        _inBackflow = false;
    }

    /// @dev Amount an auto backflow may process right now; 0 when not due.
    /// Due = quote set and this contract holds at least pool balance / THRESHOLD_DIV; capped at pool balance / CAP_DIV.
    function _dueBackflowAmount() private view returns (uint256) {
        if (pair == address(0) || quoteToken == address(0)) return 0;
        uint256 bal = balanceOf(address(this));
        uint256 poolBal = balanceOf(pair);
        uint256 threshold = poolBal / AUTO_BACKFLOW_THRESHOLD_DIV;
        if (threshold < 2 || bal < threshold) return 0;
        uint256 cap = poolBal / AUTO_BACKFLOW_CAP_DIV;
        return bal < cap ? bal : cap;
    }

    /// @dev Whether the pair's quote balance exceeds reserves — i.e. someone just deposited, not yet minted/swapped.
    /// On V2, token0 is the lower address, so no external token0() call is needed.
    function _pendingQuoteDeposit() private view returns (bool) {
        (uint112 r0, uint112 r1,) = ISonaxPair(pair).getReserves();
        uint256 quoteReserve = quoteToken < address(this) ? r0 : r1;
        return IERC20(quoteToken).balanceOf(pair) > quoteReserve;
    }

    function _update(address from, address to, uint256 value) internal override {
        // Mints and burns skip restrictions. (Sell-tax burns call the parent directly and never reach here.)
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        bool toPair = isAmmPair[to];
        bool touchesPair = toPair || isAmmPair[from];

        if (touchesPair && !tradingOpen) {
            if (!(isWhitelisted(from) || isWhitelisted(to))) revert TradingNotOpen();
        }

        // Auto-backflow only on ordinary transfers that do not touch any pair — never on buy/sell/add/remove
        // liquidity — so backflow cannot interrupt a user's add-liquidity or trade and alter reserves mid-flight.
        // Tokens leaving this contract inside backflow (from == this) do not re-trigger it.
        if (!touchesPair && from != address(this) && tradingOpen && !_inBackflow) {
            _tryAutoBackflow();
        }

        // Sell tax only: transfer into a pair, and sender not whitelisted. Buys, removes, and wallet transfers are free.
        // Burns go to unified DEAD (same sink as backflow LP); totalSupply is not reduced.
        if (toPair && !isWhitelisted(from) && value > 0) {
            // 10% is deducted from `value`; the pool receives 90%.
            uint256 burnAmount = (value * SELL_BURN_BPS) / BPS;
            uint256 backflowAmount = (value * SELL_BACKFLOW_BPS) / BPS;
            uint256 marketingAmount = (value * SELL_MARKETING_BPS) / BPS;
            uint256 toPool = value - burnAmount - backflowAmount - marketingAmount;

            totalBurned += burnAmount;
            super._update(from, DEAD, burnAmount);
            super._update(from, address(this), backflowAmount);
            super._update(from, marketingWallet, marketingAmount);
            super._update(from, to, toPool);
            return;
        }

        super._update(from, to, value);
    }
}
