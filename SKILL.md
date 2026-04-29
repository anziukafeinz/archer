---
name: crypto-futures-trading
description: |
  Crypto perpetual & quarterly futures trading skill for AI agents. Use this
  skill when the user mentions: long, short, leverage, futures, perpetual,
  perp, contract, margin, isolated, cross, hedge mode, funding rate, mark
  price, liquidation, open interest, basis, position, take-profit, stop-loss,
  bracket order, reduce-only, close position, set leverage, change margin
  type, USDS-M, COIN-M, or any derivatives trading operation on Binance,
  Bybit, OKX, or compatible venues. Supports testnet and mainnet. Defaults to
  testnet unless explicitly overridden. Requires API key + secret.
metadata:
  version: 0.1.0
  author: <your-org>
  openclaw:
    requires:
      bins:
        - curl
        - openssl
        - date
        - jq
    homepage: https://github.com/<your-org>/<your-repo>/tree/main/skills/crypto-futures-trading
license: MIT
---

# Crypto Futures Trading Skill

Authenticated perpetual & quarterly futures trading for AI agents. Wraps the
Binance USDS-M Futures API (`/fapi/*`) by default, with adapter shims for
Bybit and OKX. All commands return **JSON** so the agent can parse reliably.

> **Default: Demo Mode (testnet).** Mainnet trading requires `--mainnet` flag
> AND a non-empty `FUTURES_CONFIRM=yes` env var on every destructive call.
>
> Generate a Demo Mode API key at
> <https://demo.binance.com/en/my/settings/api-management>. The CLI uses
> `https://demo-fapi.binance.com` as the base URL for demo, and
> `https://fapi.binance.com` for mainnet.

---

## Quick Reference

### Market Data (no auth)

| Command | Description | Required | Optional |
|---|---|---|---|
| `futures-cli market exchange-info` | Symbols, filters (tickSize, stepSize, minNotional), contract type | none | `symbol` |
| `futures-cli market ticker` | 24h ticker | none | `symbol` |
| `futures-cli market depth` | Order book | `symbol` | `limit` (5/10/20/50/100/500/1000) |
| `futures-cli market klines` | Candlesticks | `symbol`, `interval` | `startTime`, `endTime`, `limit` |
| `futures-cli market mark-price` | Mark price + funding rate (current) | none | `symbol` |
| `futures-cli market funding-history` | Historical funding rates | none | `symbol`, `startTime`, `endTime`, `limit` |
| `futures-cli market open-interest` | Open interest snapshot | `symbol` | — |
| `futures-cli market open-interest-hist` | Open interest history | `symbol`, `period` | `limit`, `startTime`, `endTime` |
| `futures-cli market top-long-short-ratio` | Top trader long/short ratio | `symbol`, `period` | `limit` |
| `futures-cli market liquidations` | Recent forced liquidations | none | `symbol`, `limit` |

### Account & Position (auth required)

| Command | Endpoint | Description |
|---|---|---|
| `futures-cli account info` | `GET /fapi/v3/account` | Wallet balance, unrealized PnL, positions |
| `futures-cli account balance` | `GET /fapi/v3/balance` | Per-asset futures balance |
| `futures-cli account config` | `GET /fapi/v1/accountConfig` | Margin & position mode |
| `futures-cli account commission` | `GET /fapi/v1/commissionRate` | Maker/taker fee for symbol |
| `futures-cli account income` | `GET /fapi/v1/income` | Realized PnL, funding fees, commissions |
| `futures-cli position list` | `GET /fapi/v3/positionRisk` | Open positions w/ liq price & ADL quantile |
| `futures-cli position set-leverage` | `POST /fapi/v1/leverage` | Set leverage for symbol |
| `futures-cli position set-margin-type` | `POST /fapi/v1/marginType` | ISOLATED / CROSSED |
| `futures-cli position set-position-mode` | `POST /fapi/v1/positionSide/dual` | One-way / Hedge |
| `futures-cli position adjust-margin` | `POST /fapi/v1/positionMargin` | Add/remove isolated margin |

### Order Management (auth required, **destructive**)

| Command | Endpoint | Notes |
|---|---|---|
| `futures-cli order place` | `POST /fapi/v1/order` | Single order, see flags below |
| `futures-cli order place-batch` | `POST /fapi/v1/batchOrders` | Up to 5 orders atomically |
| `futures-cli order bracket` | composite | Entry + SL + TP as one logical group |
| `futures-cli order cancel` | `DELETE /fapi/v1/order` | By `orderId` or `origClientOrderId` |
| `futures-cli order cancel-all` | `DELETE /fapi/v1/allOpenOrders` | Per symbol |
| `futures-cli order cancel-batch` | `DELETE /fapi/v1/batchOrders` | Multiple by id |
| `futures-cli order query` | `GET /fapi/v1/order` | Single order status |
| `futures-cli order open` | `GET /fapi/v1/openOrders` | All open orders |
| `futures-cli order history` | `GET /fapi/v1/allOrders` | Full history |
| `futures-cli order trades` | `GET /fapi/v1/userTrades` | Fills |

### Strategy Helpers (offline, no API call)

| Command | Description |
|---|---|
| `futures-cli calc size` | Risk-based position sizing (`equity × risk% / (entry − stop)`) |
| `futures-cli calc liq` | Estimate liquidation price for hypothetical position |
| `futures-cli calc pnl` | What-if PnL given entry/exit/qty/leverage |
| `futures-cli calc basis` | Spot vs futures basis & implied APR |
| `futures-cli scan funding` | Rank symbols by current funding rate |
| `futures-cli ta` | SMA / EMA / RSI / ATR / Bollinger from klines |

---

## `order place` — the most important command

```
futures-cli order place \
  --symbol BTCUSDT \
  --side BUY|SELL \
  --type LIMIT|MARKET|STOP|STOP_MARKET|TAKE_PROFIT|TAKE_PROFIT_MARKET|TRAILING_STOP_MARKET \
  --quantity 0.01 \
  [--price 60000]              # required for LIMIT / STOP / TAKE_PROFIT
  [--time-in-force GTC]         # used for any price-bearing type; default GTC
  [--stop-price <p>]            # required for STOP* / TAKE_PROFIT*
  [--callback-rate <pct>]       # required for TRAILING_STOP_MARKET (0.1..5.0)
  [--activation-price <p>]      # optional for TRAILING_STOP_MARKET
  [--reduce-only]               # mutually exclusive with --close-position
  [--close-position]            # only valid on STOP_MARKET / TAKE_PROFIT_MARKET
  [--position-side LONG|SHORT|BOTH] \
  [--working-type MARK_PRICE|CONTRACT_PRICE] \
  [--price-protect] \
  [--client-order-id <idempotency-key>] \
  [--max-slippage 0.005]        # 0 disables; FUTURES_MAX_SLIPPAGE override
  [--dry-run]                   # default unless --confirm
  [--mainnet]                   # default testnet
```

### Per-type cheatsheet

| `--type`               | Required                                  | Sent to Binance                                     |
|------------------------|-------------------------------------------|------------------------------------------------------|
| `LIMIT`                | `--price`, `--quantity`                   | `price`, `timeInForce`, `quantity`                   |
| `MARKET`               | `--quantity`                              | `quantity` (no price / timeInForce)                  |
| `STOP`                 | `--price`, `--stop-price`, `--quantity`   | `price`, `stopPrice`, `timeInForce`, `quantity`      |
| `STOP_MARKET`          | `--stop-price` (qty OR `--close-position`)| `stopPrice` + (`quantity` or `closePosition=true`)   |
| `TAKE_PROFIT`          | `--price`, `--stop-price`, `--quantity`   | same shape as `STOP`                                 |
| `TAKE_PROFIT_MARKET`   | `--stop-price` (qty OR `--close-position`)| same shape as `STOP_MARKET`                          |
| `TRAILING_STOP_MARKET` | `--callback-rate` (0.1..5.0), `--quantity`| `callbackRate` + optional `activationPrice`          |

### Pre-trade validation (always runs, even in dry-run)
1. Symbol exists and is `TRADING` status.
2. Per-type required-arg check (table above) — wrong combos return `BAD_ARGS`.
3. `quantity` rounded down to `stepSize`; `price` and `stopPrice` rounded to `tickSize`.
4. `quantity × price ≥ minNotional` (skipped for `MARKET` / `*_MARKET` / `TRAILING_STOP_MARKET` — Binance enforces server-side).
5. **Slippage gate** (price-bearing types only): the explicit `--price` may not deviate
   from `markPrice` by more than `--max-slippage` (default `FUTURES_MAX_SLIPPAGE` /
   `0.005` = 0.5%). Set `--max-slippage 0` to disable. Failures return
   `SLIPPAGE_EXCEEDED`; this is intended to catch typos like a BUY LIMIT 1.5x mark.
6. `clientOrderId` auto-generated as `ai-${epoch}-${rand}` if not provided (idempotency).
7. `--close-position` is rejected on anything other than `STOP_MARKET` /
   `TAKE_PROFIT_MARKET`, and is mutually exclusive with `--reduce-only`.
   For `closePosition=true`, `quantity` is ignored by Binance and stripped from
   the request; the confirmation gate uses notional `0`.

### Confirmation gate (mainnet only)
Destructive mainnet calls require **all** of:
- `--confirm` flag
- `FUTURES_CONFIRM=yes` env var
- Notional ≤ `FUTURES_MAX_NOTIONAL` (default $1000)
- Leverage ≤ `FUTURES_MAX_LEVERAGE` (default 5)
- Symbol in `FUTURES_ALLOWED_SYMBOLS` if set

If any check fails the CLI returns:
```json
{ "ok": false, "error": "CONFIRMATION_REQUIRED", "missing": ["--confirm"], "would_send": { ... } }
```

---

## `order place-batch` — up to 5 orders in one signed call

```
futures-cli order place-batch \
  --orders-file path/to/orders.json \
  [--orders '<inline JSON array>'] \
  [--dry-run] \
  [--mainnet] \
  [--confirm]
```

The JSON payload is an array (1..5 elements) of order objects following
Binance's `POST /fapi/v1/batchOrders` schema:

```json
[
  {"symbol":"BTCUSDT","side":"BUY", "type":"LIMIT","quantity":"0.002","price":"60000","timeInForce":"GTC"},
  {"symbol":"ETHUSDT","side":"SELL","type":"STOP_MARKET","quantity":"0.10","stopPrice":"3500","reduceOnly":"true"}
]
```

Each order is run through the same Layer-2 validations as `order place`
(stepSize / tickSize rounding, minQty, minNotional). Per-order
`newClientOrderId` is auto-generated when omitted (see Idempotency above).
The aggregate `qty × price` across the batch is fed into the mainnet
confirmation gate (`FUTURES_MAX_NOTIONAL`).

`--dry-run` returns the normalized batch and the estimated total notional
without contacting the venue:

```json
{
  "ok": true, "venue": "binance", "network": "testnet",
  "command": "order place-batch",
  "data": {
    "would_send": [ { "symbol": "BTCUSDT", "...": "..." } ],
    "count": 1,
    "estimated_notional": "120.000",
    "dry_run": true
  },
  "warnings": [], "error": null
}
```

A live response wraps the venue array (one element per order; each is
either a fill response or a per-order error) in the same `data` field
described under "Output schema".

---

## `order cancel-batch` — cancel up to 10 orders by id

```
futures-cli order cancel-batch \
  --symbol BTCUSDT \
  [--order-ids "12345,67890"] \
  [--client-order-ids "ai-1,ai-2"] \
  [--mainnet] [--confirm]
```

Exactly one of `--order-ids` (numeric) or `--client-order-ids` (strings)
must be provided. The CLI builds Binance's `orderIdList` /
`origClientOrderIdList` JSON arrays, URL-encodes them, and signs the
request. Cancels are non-destructive in the risk model so they pass the
mainnet gate with zero notional, but `--confirm` + `FUTURES_CONFIRM=yes`
are still required on mainnet.

---

## `order bracket` — atomic entry + SL + TP

```
futures-cli order bracket \
  --symbol ETHUSDT --side BUY --quantity 0.1 \
  --entry-type LIMIT --entry-price 3000 \
  --stop-loss 2900 \
  --take-profit 3200 \
  [--reduce-only-exits]  # default true
```

Implementation: places entry as `LIMIT`, then on fill (or immediately if
already filled) places `STOP_MARKET` (SL) and `TAKE_PROFIT_MARKET` (TP) both
with `closePosition=true` and `workingType=MARK_PRICE`. Returns all three
order IDs grouped by a synthetic `bracketId`.

---

## Authentication

API key + secret are read from environment variables:

```
FUTURES_API_KEY        # required
FUTURES_API_SECRET     # required
FUTURES_VENUE          # binance|bybit|okx, default binance
FUTURES_NETWORK        # testnet|mainnet, default testnet
FUTURES_BASE_URL       # optional, overrides the resolved BASE_URL for every
                       # request (e.g. https://testnet.binancefuture.com when
                       # demo-fapi.binance.com is geo-blocked from your runner)
```

Signing follows Binance HMAC-SHA256 over the query string with `timestamp`
and optional `recvWindow`. See `references/binance-signing.md`.

> **Never** echo `FUTURES_API_SECRET` in logs or responses. The CLI redacts
> it automatically.

---

## Output schema

Every command returns:
```json
{
  "ok": true | false,
  "venue": "binance",
  "network": "testnet" | "mainnet",
  "command": "order place",
  "data": { /* venue response, normalized */ },
  "warnings": [ "..." ],
  "error": null | { "code": "...", "message": "...", "hint": "..." }
}
```

Common error codes (normalized across venues):
- `INSUFFICIENT_MARGIN`
- `INVALID_QUANTITY` (below stepSize / minNotional)
- `INVALID_PRICE` (off tickSize)
- `MIN_NOTIONAL` (qty × price below filter)
- `LEVERAGE_TOO_HIGH`
- `POSITION_SIDE_MISMATCH` (hedge mode misuse)
- `REDUCE_ONLY_REJECT`
- `CONFIRMATION_REQUIRED`
- `RATE_LIMIT` (with `retry_after_ms`)
- `CIRCUIT_BREAKER` (drawdown / daily-loss limit hit)
- `BATCH_SIZE` (`order place-batch` outside 1..5)
- `INVALID_ORDER` (per-order failure inside a batch; message includes index)
- `SLIPPAGE_EXCEEDED` (limit price too far from mark; raise `--max-slippage` or move price)

---

## Risk safety layer (built-in)

Configured via env or `~/.futures-cli/limits.json`:

```json
{
  "max_leverage": 5,
  "max_notional_usd": 1000,
  "max_daily_loss_usd": 200,
  "allowed_symbols": ["BTCUSDT", "ETHUSDT"],
  "circuit_breaker": {
    "drawdown_pct": 5,
    "window_minutes": 60,
    "action": "cancel_all_and_block"
  }
}
```

State (daily PnL, last-N trades) persists to `~/.futures-cli/state.db`
(SQLite). Reset with `futures-cli risk reset`.

---

## Few-shot examples for the agent

**User:** "Long 0.05 BTC at market with 3x leverage on testnet, stop loss 2% below"

```bash
futures-cli position set-leverage --symbol BTCUSDT --leverage 3
MARK=$(futures-cli market mark-price --symbol BTCUSDT | jq -r .data.markPrice)
SL=$(echo "$MARK * 0.98" | bc -l)
futures-cli order bracket \
  --symbol BTCUSDT --side BUY --quantity 0.05 \
  --entry-type MARKET \
  --stop-loss "$SL"
```

**User:** "Show me the top 5 perpetuals by funding rate right now"

```bash
futures-cli scan funding --top 5
```

**User:** "Close all my ETH positions"

```bash
futures-cli order cancel-all --symbol ETHUSDT
futures-cli position list --symbol ETHUSDT \
  | jq -r '.data[] | select(.positionAmt != "0") | .positionAmt' \
  | while read AMT; do
      SIDE=$([ "${AMT#-}" != "$AMT" ] && echo BUY || echo SELL)
      QTY=${AMT#-}
      futures-cli order place --symbol ETHUSDT --side "$SIDE" \
        --type MARKET --quantity "$QTY" --reduce-only --confirm
    done
```

---

## What this skill does NOT do
- Spot trading → use `binance/spot` skill
- On-chain / DEX perps (Hyperliquid, dYdX, GMX) → separate skill
- Options → use `binance/derivatives-trading-options`
- Withdrawals / transfers between wallets → out of scope (least-privilege)

---

## Implementation notes (for the builder)
See `README.md` for architecture, `references/` for upstream API docs, and
`scripts/futures-cli` for a working starter (Binance USDS-M, ~10 endpoints).
