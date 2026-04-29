# Binance USDS-M Futures — endpoint reference

Base URL:
- Mainnet: `https://fapi.binance.com`
- Demo Mode (new testnet, replaces `testnet.binancefuture.com`): `https://demo-fapi.binance.com`
  - Get keys at <https://demo.binance.com/en/my/settings/api-management>

Docs: https://developers.binance.com/docs/derivatives/usds-margined-futures

## Endpoints to wrap (MVP)

### Market (no auth, weight 1-40)
| Method | Path | Used by CLI |
|---|---|---|
| GET | `/fapi/v1/ping` | health |
| GET | `/fapi/v1/time` | time sync |
| GET | `/fapi/v1/exchangeInfo` | `market exchange-info` |
| GET | `/fapi/v1/depth` | `market depth` |
| GET | `/fapi/v1/trades` | (internal) |
| GET | `/fapi/v1/klines` | `market klines` |
| GET | `/fapi/v1/premiumIndex` | `market mark-price` |
| GET | `/fapi/v1/fundingRate` | `market funding-history` |
| GET | `/fapi/v1/ticker/24hr` | `market ticker` |
| GET | `/fapi/v1/openInterest` | `market open-interest` |
| GET | `/futures/data/openInterestHist` | `market open-interest-hist` |
| GET | `/futures/data/topLongShortPositionRatio` | `market top-long-short-ratio` |
| GET | `/fapi/v1/forceOrders` | `market liquidations` (auth) |

### Account & Position (auth, USER_DATA)
| Method | Path | Used by CLI |
|---|---|---|
| GET | `/fapi/v3/account` | `account info` |
| GET | `/fapi/v3/balance` | `account balance` |
| GET | `/fapi/v1/accountConfig` | `account config` |
| GET | `/fapi/v1/commissionRate` | `account commission` |
| GET | `/fapi/v1/income` | `account income` |
| GET | `/fapi/v3/positionRisk` | `position list` |
| POST | `/fapi/v1/leverage` | `position set-leverage` |
| POST | `/fapi/v1/marginType` | `position set-margin-type` |
| POST | `/fapi/v1/positionSide/dual` | `position set-position-mode` |
| POST | `/fapi/v1/positionMargin` | `position adjust-margin` |
| POST | `/fapi/v1/multiAssetsMargin` | (optional) |

### Trade (auth, TRADE)
| Method | Path | Used by CLI |
|---|---|---|
| POST | `/fapi/v1/order` | `order place` |
| POST | `/fapi/v1/batchOrders` | `order place-batch` |
| DELETE | `/fapi/v1/order` | `order cancel` |
| DELETE | `/fapi/v1/allOpenOrders` | `order cancel-all` |
| DELETE | `/fapi/v1/batchOrders` | `order cancel-batch` |
| GET | `/fapi/v1/order` | `order query` |
| GET | `/fapi/v1/openOrders` | `order open` |
| GET | `/fapi/v1/allOrders` | `order history` |
| GET | `/fapi/v1/userTrades` | `order trades` |
| POST | `/fapi/v1/countdownCancelAll` | (optional, dead-man switch) |

### Explicitly NOT wrapped (least-privilege)
- Withdraw, transfer, internal-transfer endpoints
- Sub-account management
- Anything under `/sapi/*` (spot/wallet)

## Param conventions
- `timestamp` (ms) and `signature` are auto-injected by `_common.sh`.
- `recvWindow` defaults to 5000ms.
- All numeric fields submitted as strings to avoid float rounding (e.g. `"0.01000000"`).
