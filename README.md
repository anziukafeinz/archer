# crypto-futures-trading — design & build guide

This is a **starter skeleton** for a Binance Skills Hub-style skill that lets
AI agents trade crypto perpetual & quarterly futures safely.

## Files in this draft

```
crypto-futures-trading/
├── SKILL.md              # Skill manifest (the only file the agent reads first)
├── README.md             # This file — architecture & build plan
├── CHANGELOG.md
├── LICENSE.md
├── references/
│   ├── binance-fapi-endpoints.md   # Curated list of /fapi/* endpoints to wrap
│   ├── binance-signing.md          # HMAC-SHA256 signing recipe
│   └── error-code-mapping.md       # Venue error → normalized error
└── scripts/
    ├── futures-cli                 # Bash entrypoint dispatcher
    ├── _common.sh                  # signing, request, validation helpers
    ├── market.sh                   # market data subcommands
    ├── account.sh                  # account & position subcommands
    ├── order.sh                    # order placement / cancel / query
    ├── calc.sh                     # offline calculators
    └── risk.sh                     # risk limits + circuit breaker state
```

## Architecture (3 layers)

```
┌─────────────────────────────────────────────────────────┐
│ Layer 3: Agent UX                                        │
│   SKILL.md trigger keywords, JSON output, few-shot       │
│   examples, --dry-run default, confirmation gate         │
├─────────────────────────────────────────────────────────┤
│ Layer 2: Risk & Safety                                   │
│   pre-trade validation, slippage guard, idempotency,     │
│   leverage/notional limits, circuit breaker, allow-list  │
├─────────────────────────────────────────────────────────┤
│ Layer 1: Venue Adapter                                   │
│   HTTP + HMAC signing, rate limit handling, response     │
│   normalization, testnet/mainnet routing                 │
└─────────────────────────────────────────────────────────┘
```

Keep Layer 1 thin (just translate to/from HTTP). Put **all** the
agent-specific intelligence in Layer 2 and 3 — that's the differentiator
versus a generic SDK.

## Why bash + curl + openssl + jq?

Binance Skills Hub uses exactly this stack (see
[derivatives-trading-usds-futures](https://github.com/binance/binance-skills-hub/tree/main/skills/binance/derivatives-trading-usds-futures)).
Reasons:
- Zero install footprint, works in any sandbox / OpenClaw runner
- Auditable: a security reviewer can read the whole thing in 30 minutes
- Deterministic JSON output via `jq`
- Composable: agent can pipe between commands

If you prefer TypeScript or Go, keep the **CLI surface and JSON schema
identical** so SKILL.md doesn't change.

## Build order (recommended)

| # | Milestone | Commands to ship | Test |
|---|-----------|------------------|------|
| 1 | Auth + market data | `market exchange-info`, `market ticker`, `market mark-price` | testnet, no key needed |
| 2 | Account read | `account info`, `account balance`, `position list` | testnet w/ key |
| 3 | Single order + cancel | `order place` (LIMIT only), `order cancel`, `order open` | testnet, dry-run + real |
| 4 | Risk layer | pre-trade validation, idempotency, limits.json | unit tests |
| 5 | More order types | MARKET, STOP, TP, TRAILING, reduceOnly, closePosition | testnet |
| 6 | Leverage & margin | `position set-leverage`, `set-margin-type`, `set-position-mode` | testnet |
| 7 | Bracket + batch | `order bracket`, `order place-batch`, `cancel-batch` | testnet |
| 8 | Strategy helpers | `calc size`, `calc liq`, `calc pnl`, `scan funding`, `ta` | offline unit tests |
| 9 | Streaming (optional) | WS `markPrice`, user data stream | manual |
| 10 | Multi-venue | Bybit + OKX adapters behind `FUTURES_VENUE` | parity tests |

## Critical correctness items (don't skip)

1. **Round to filters before submit.** Use `exchangeInfo` → `PRICE_FILTER.tickSize`,
   `LOT_SIZE.stepSize`, `MIN_NOTIONAL.notional`. Round price *down* for BUY
   limits and *up* for SELL limits to be conservative; round qty *down* always.
2. **Hedge mode position side.** If account is in hedge mode, every order
   needs `positionSide=LONG` or `SHORT`. In one-way mode it must be `BOTH`
   or omitted. Detect mode from `account config` and inject automatically.
3. **`reduceOnly` vs `closePosition`.**
   - `reduceOnly=true`: order can only reduce, not flip. Used on regular SL/TP.
   - `closePosition=true`: only valid on `STOP_MARKET` / `TAKE_PROFIT_MARKET`,
     ignores `quantity`, closes whole position. Used on bracket exits.
4. **Idempotency.** Always set `newClientOrderId`. Hash of
   `(symbol, side, type, qty, price, epoch_minute)` is a reasonable default
   if the agent doesn't provide one.
5. **Server time skew.** Sync once per process: `GET /fapi/v1/time`, store
   `serverTime - localTime` offset, apply to every signed request. Skew > 1s
   causes signature failures.
6. **Rate limits.** Track `X-MBX-USED-WEIGHT-1M` header; back off at 80%.
7. **Base URLs (Demo Mode replaces the old testnet.binancefuture.com).**
   - Demo REST: `https://demo-fapi.binance.com` (keys: <https://demo.binance.com/en/my/settings/api-management>)
   - Demo WS:   `wss://fstream.binancefuture.com`  (legacy host, still works for streams)
   - Mainnet:   `https://fapi.binance.com` / `wss://fstream.binance.com`

## Security review checklist (before listing)

- [ ] API key + secret never logged, never in error messages
- [ ] No `withdraw` / `transfer` endpoints wrapped (least privilege)
- [ ] Mainnet requires `--confirm` + env var (double-gate)
- [ ] Default network is testnet
- [ ] Risk limits enforced even when agent forgets `--dry-run`
- [ ] `clientOrderId` always set (no double-orders on retry)
- [ ] All shell variables quoted (no command injection from symbol/qty)
- [ ] `set -euo pipefail` in every script
- [ ] No `eval`, no `curl | bash`
- [ ] Dependencies pinned, minimal (`curl`, `openssl`, `jq`, `date`)

## Multi-venue notes

Binance USDS-M is the reference. To add a venue:
1. Implement `_common_<venue>.sh` with `sign_request`, `base_url`, `normalize_error`.
2. Map endpoints to the same CLI surface; if a feature is missing, return
   `{"ok": false, "error": {"code": "UNSUPPORTED_BY_VENUE"}}`.
3. Normalize responses to the schema in `SKILL.md` → "Output schema".

Bybit V5 (`/v5/order/create`) and OKX V5 (`/api/v5/trade/order`) both fit
this pattern.

## Open questions for v0.2+
- WebSocket user data stream → push order/position updates back to agent
- Position netting across venues (cross-exchange portfolio view)
- Funding-rate arb runner (cron skill)
- TWAP / VWAP execution algos (Binance has `algo/futures/newOrderTwap`)
- Copy-trading leaderboard integration
