# Error code normalization

The CLI returns errors in this shape regardless of venue:
```json
{ "ok": false, "error": { "code": "<NORMALIZED>", "message": "...", "hint": "...", "raw": { ... } } }
```

## Mapping

| Normalized | Binance | Bybit | OKX | Hint to surface to agent |
|---|---|---|---|---|
| `INSUFFICIENT_MARGIN` | -2019 | 110007, 30787 | 51008 | Reduce qty, lower leverage, or top up |
| `INVALID_QUANTITY` | -4003, -1013 | 10001 (qty) | 51000 | Round qty to `stepSize` ≥ `minQty` |
| `INVALID_PRICE` | -4014, -1013 | 10001 (price) | 51000 | Round price to `tickSize` |
| `MIN_NOTIONAL` | -4164 | 110094 | 51020 | Increase `qty × price` ≥ `minNotional` |
| `LEVERAGE_TOO_HIGH` | -4028 | 110026 | 51010 | Lower leverage, check tier ladder |
| `POSITION_SIDE_MISMATCH` | -4061 | 110017 | 51000 | Set `positionSide` (LONG/SHORT) in hedge mode |
| `REDUCE_ONLY_REJECT` | -2022 | 110017 | 51400 | Position smaller than reduce qty, or wrong side |
| `RATE_LIMIT` | -1003, -1015 | 10006 | 50011 | Back off; respect `Retry-After` |
| `IP_BANNED` | -1003 (banned) | 10010 | 50111 | Stop, change IP, contact support |
| `MAINTENANCE` | -1000 | 10016 | 50001 | Wait, retry later |
| `SIGNATURE` | -1022 | 10004 | 50113 | Check secret + querystring |
| `TIMESTAMP` | -1021 | 10002 | 50102 | Sync time |
| `UNKNOWN_ORDER` | -2013 | 110001 | 51400 | Order id wrong or already filled/cancelled |
| `CONFIRMATION_REQUIRED` | (CLI-internal) | — | — | Add `--confirm` + env var for mainnet |
| `CIRCUIT_BREAKER` | (CLI-internal) | — | — | Risk layer triggered, run `risk reset` |
| `UNSUPPORTED_BY_VENUE` | (CLI-internal) | — | — | Use a different venue or feature |
