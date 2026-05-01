# Changelog

## [0.4.0] - unreleased

### Added — Milestone 6: position setters (leverage / margin type / mode)
- `futures-cli position set-leverage` is now a first-class subcommand
  with strict pre-flight validation: `--leverage` must be an integer in
  `1..125` (Binance's hard cap). The mainnet confirmation gate is
  enforced (`--confirm` + `FUTURES_CONFIRM=yes`), and the requested
  leverage value is fed into `FUTURES_MAX_LEVERAGE` so a strategy
  hard-cap of `5x` will block a `set-leverage 10` even with
  `--confirm`. Supports `--dry-run`.
- `futures-cli position set-margin-type` — accepts `ISOLATED` or
  `CROSSED` (case-insensitive; normalised to upper-case before
  signing). Wrong values fail with `BAD_ARGS` and a clear hint listing
  the two accepted values.
- `futures-cli position set-position-mode` — friendly
  `--mode hedge|one-way` flag (mapped to Binance's
  `dualSidePosition true|false`). The legacy `--dual true|false`
  remains accepted for backward-compatibility with the v0.1.0 draft.
- `futures-cli position get-position-mode` — read-only sibling that
  returns `{mode, dualSidePosition}` so callers can verify the
  current mode after a setter, or before issuing hedge-mode-only
  parameters like `positionSide=LONG`.
- `futures-cli position adjust-margin` was upgraded with proper
  validation (`--type` ∈ `{1,2}`, `--amount > 0`) and now passes
  `--amount` as the notional upper bound to the confirmation gate so
  `FUTURES_MAX_NOTIONAL` can prevent accidentally pumping six figures
  of collateral into a stuck position.
- All five setters now accept `--dry-run` and emit the standard
  `ok_json` envelope (`{ok, venue, network, command, data, warnings,
  error}`), with subcommand-specific keys inside `data` (e.g.
  `{symbol, leverage, dry_run:true, would_send}`).

### Tests
- `tests/test_position_setters.bats` — 26 hermetic unit tests
  covering: every setter's happy path, every per-setter rejection
  path (missing args, out-of-range leverage, bad enum, bad mode,
  zero amount, etc.), the mainnet gate matrix (testnet bypass /
  no `--confirm` / over `FUTURES_MAX_LEVERAGE` / over
  `FUTURES_MAX_NOTIONAL` / within all limits), and `get-position-mode`
  success + venue-error normalisation paths.
- `tests/helpers.bash` gains a `source_common_and_account` helper that
  pairs `_common.sh` with `account.sh` (the file that hosts both the
  `account` and `position` dispatchers).

### Documentation
- `SKILL.md` — new "`position` setters" section with full usage,
  validation rules, mainnet-gate behaviour, and notes on Binance's
  server-side rejections (`-4046` / `-4059`). Quick-reference table
  updated with the new `get-position-mode` entry and gate annotations.
- `scripts/futures-cli` — top-level help text updated to list
  `get-position-mode` and re-flow the `position` row.

## [0.3.0] - unreleased

### Added — Milestone 5: full order-type matrix + slippage gate
- `futures-cli order place` now supports the full Binance USDS-M futures
  order type set: `LIMIT`, `MARKET`, `STOP`, `STOP_MARKET`, `TAKE_PROFIT`,
  `TAKE_PROFIT_MARKET`, `TRAILING_STOP_MARKET`. Per-type required-arg
  validation runs before any signed call (e.g. `STOP` requires both
  `--price` and `--stop-price`; `TRAILING_STOP_MARKET` requires
  `--callback-rate` in `0.1..5.0`).
- New `--activation-price` flag for `TRAILING_STOP_MARKET`.
- `--max-slippage` (env: `FUTURES_MAX_SLIPPAGE`, default `0.005` = 0.5%)
  is now enforced for any price-bearing type (`LIMIT` / `STOP` /
  `TAKE_PROFIT`). The CLI fetches `markPrice` and rejects orders whose
  explicit price deviates by more than the threshold with a new
  `SLIPPAGE_EXCEEDED` error. Set `--max-slippage 0` to disable. The
  flag was previously parsed but unused.
- `--close-position` is now constrained to `STOP_MARKET` /
  `TAKE_PROFIT_MARKET` and is mutually exclusive with `--reduce-only`.
  When used, `quantity` is omitted from the request and the
  confirmation gate uses notional `0` (Binance ignores qty server-side).
- `stopPrice` and `activationPrice` are rounded to `tickSize` before
  the request is built, matching how `price` and `quantity` are handled.
- `order place --dry-run` output now uses the standard `ok_json`
  envelope (`{ok, venue, network, command, data, warnings, error}`) and
  includes `type`, `max_slippage`, and `dry_run:true` inside `data`.
  Previously the dry-run path emitted a hand-rolled object without
  `venue` / `network` and with `dry_run` at the wrong nesting level.

### Tests
- `tests/test_order_types.bats` — 27 hermetic unit tests covering every
  type's happy path, every per-type rejection path, the slippage-gate
  matrix (default reject / `--max-slippage` raised / disabled / bypassed
  for non-price-bearing types), `closePosition` rules,
  `reduceOnly`/`closePosition` mutual exclusion, and `positionSide`
  emission.
- `tests/helpers.bash` already provided `mock_signed_req` and
  `public_get` mocks, so all 27 cases run offline against the
  `exchangeInfo.json` fixture.

### Documentation
- `SKILL.md` — `order place` section rewritten with a per-type
  cheatsheet table; pre-trade validation list updated to mention the
  slippage gate, the per-type required-arg check, and `closePosition`
  semantics. Output schema unchanged.
- `SKILL.md` — added `SLIPPAGE_EXCEEDED` to the normalised error-code list.

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
