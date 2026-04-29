# Changelog

## [0.2.0] - unreleased

### Added — Milestone 7: batch order management
- `futures-cli order place-batch` — atomic submission of 1..5 orders via
  Binance `POST /fapi/v1/batchOrders`. Accepts `--orders-file` (path to
  JSON array) or `--orders` (inline JSON). Each order is run through the
  Layer-2 risk validator (stepSize / tickSize rounding, minQty,
  minNotional), `newClientOrderId` is auto-generated when omitted, and
  the aggregate notional is fed into the mainnet confirmation gate. New
  error codes: `BATCH_SIZE`, `INVALID_ORDER`.
- `futures-cli order cancel-batch` — bulk cancel via
  `DELETE /fapi/v1/batchOrders`, supporting either `--order-ids` (numeric
  list) or `--client-order-ids` (string list). Builds Binance's
  `orderIdList` / `origClientOrderIdList` JSON parameters and respects
  the mainnet confirmation gate (zero-notional pass-through).
- `_batch_normalize_one` helper: shared per-order validate + normalize
  step that surfaces a single-line error JSON with the failing index
  (e.g. `order[1] notional 0.001 < 5`) instead of double-emitting.

### Added — Milestone 4: risk-layer unit tests
- `tests/` directory with `bats-core` test framework. Two test files
  (39 cases total, all green offline):
  - `tests/test_common.bats` — `_common.sh` validation: `round_down`
    edge cases, `validate_order` rounding + minQty / minNotional /
    INVALID_SYMBOL paths, `gen_client_order_id` shape & uniqueness,
    `require_confirmation` testnet/mainnet matrix, HMAC `sign` known
    vector.
  - `tests/test_order_batch.bats` — covers the M7 batch logic end to
    end with a mocked `signed_req` / `public_get` (no network), asserts
    the URL-encoded payload Binance receives, and exercises every
    error path (`BAD_ARGS`, `BATCH_SIZE`, per-order validation).
- `tests/fixtures/exchangeInfo.json` — minimal BTCUSDT / ETHUSDT /
  DOGEUSDT entries so `symbol_filters` and `validate_order` run hermetic.
- `tests/helpers.bash` — sets up an isolated `TMPDIR` and exchangeInfo
  cache per test, plus a `mock_signed_req` stub.

### Documentation
- SKILL.md: added detailed `order place-batch` and `order cancel-batch`
  usage sections. Output schema (`{ok, venue, network, command, data,
  warnings, error}`) is unchanged — both batch subcommands return data
  via the same envelope. Added `MIN_NOTIONAL`, `BATCH_SIZE`, and
  `INVALID_ORDER` to the normalized error-code list.

### Added — small enabler
- `FUTURES_BASE_URL` env override in `_common.sh`. When set, replaces the
  network-derived `BASE_URL` so the CLI can reach the legacy
  `https://testnet.binancefuture.com` host from runners where the new
  Demo Mode endpoint is geo-blocked. Default behaviour is unchanged.

### Notes
- Default network remains `testnet`; mainnet still requires `--confirm`
  + `FUTURES_CONFIRM=yes` + per-call notional/leverage gates.
- No `withdraw` / `transfer` endpoints introduced (per security checklist).

## [0.1.0] - unreleased
- Initial draft skeleton
- SKILL.md with Quick Reference for market / account / order / calc commands
- Risk safety layer design (limits.json, circuit breaker, confirmation gate)
- Bash starter scripts for Binance USDS-M (testnet default)
- References for signing and endpoint mapping
