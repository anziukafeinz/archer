#!/usr/bin/env bats
# Unit tests for `order place` covering all M5 order types and the slippage
# gate. Network is mocked so these run offline.

load helpers.bash

setup() {
  source_common_and_order
  mock_signed_req
  CMD="order test"
}

# Helper: extract a single key=value from the would_send querystring.
# $1 = output JSON, $2 = key. Echoes the value, or empty if absent.
_q() {
  local out="$1" key="$2"
  echo "$out" | jq -r '.data.would_send' \
    | tr '&' '\n' \
    | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

# -------------------------------------------------------------- LIMIT ---------

@test "LIMIT dry-run: builds price + timeInForce + GTC default" {
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --price 60000 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'                       >/dev/null
  echo "$output" | jq -e '.network == "testnet"'             >/dev/null
  echo "$output" | jq -e '.data.type == "LIMIT"'             >/dev/null
  echo "$output" | jq -e '.data.dry_run == true'             >/dev/null
  echo "$output" | jq -e '.data.estimated_notional | tonumber == 120' >/dev/null
  [ "$(_q "$output" type)"        = "LIMIT" ]
  [ "$(_q "$output" quantity)"    = "0.002" ]
  [ "$(_q "$output" price)"       = "60000.00" ]
  [ "$(_q "$output" timeInForce)" = "GTC" ]
}

@test "LIMIT without --price fails BAD_ARGS" {
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.ok == false'                                >/dev/null
  echo "$output" | jq -e '.error.code == "BAD_ARGS"'                   >/dev/null
  echo "$output" | jq -e '.error.message | contains("LIMIT requires --price")' >/dev/null
}

# -------------------------------------------------------------- MARKET --------

@test "MARKET dry-run: no price / timeInForce in querystring" {
  run _order_place --symbol BTCUSDT --side SELL --type MARKET \
    --quantity 0.002 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.type == "MARKET"' >/dev/null
  [ "$(_q "$output" type)"     = "MARKET" ]
  [ "$(_q "$output" quantity)" = "0.002" ]
  [ -z "$(_q "$output" price)"       ]
  [ -z "$(_q "$output" timeInForce)" ]
  # Notional is computed from mark price (mock returns 60000).
  echo "$output" | jq -e '.data.estimated_notional | tonumber == 120' >/dev/null
}

@test "MARKET ignores --price (set to 0 internally; no minNotional gate)" {
  # Tiny qty that would fail minNotional@price=1, but MARKET skips that gate.
  run _order_place --symbol BTCUSDT --side BUY --type MARKET \
    --quantity 0.001 --price 1 --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(_q "$output" price)" ]
}

# -------------------------------------------------------------- STOP / TP -----

@test "STOP_MARKET dry-run: needs --stop-price; emits stopPrice rounded to tick" {
  # BTCUSDT tickSize=0.10 → 59999.55 rounds DOWN to 59999.50.
  run _order_place --symbol BTCUSDT --side SELL --type STOP_MARKET \
    --quantity 0.002 --stop-price 59999.55 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.type == "STOP_MARKET"' >/dev/null
  [ "$(_q "$output" stopPrice)" = "59999.50" ]
  [ -z "$(_q "$output" price)" ]
  [ -z "$(_q "$output" timeInForce)" ]
}

@test "STOP_MARKET without --stop-price fails BAD_ARGS" {
  run _order_place --symbol BTCUSDT --side SELL --type STOP_MARKET \
    --quantity 0.002 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("STOP_MARKET requires --stop-price")' >/dev/null
}

@test "STOP (stop-limit) dry-run: includes BOTH price AND stopPrice + timeInForce" {
  run _order_place --symbol BTCUSDT --side BUY --type STOP \
    --quantity 0.002 --price 60100 --stop-price 60050 \
    --time-in-force GTC --dry-run
  [ "$status" -eq 0 ]
  [ "$(_q "$output" type)"        = "STOP" ]
  [ "$(_q "$output" price)"       = "60100.00" ]
  [ "$(_q "$output" stopPrice)"   = "60050.00" ]
  [ "$(_q "$output" timeInForce)" = "GTC" ]
}

@test "STOP without --price fails BAD_ARGS" {
  run _order_place --symbol BTCUSDT --side BUY --type STOP \
    --quantity 0.002 --stop-price 60050 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("STOP requires --price")' >/dev/null
}

@test "TAKE_PROFIT_MARKET dry-run: stopPrice required; price omitted" {
  run _order_place --symbol BTCUSDT --side SELL --type TAKE_PROFIT_MARKET \
    --quantity 0.002 --stop-price 65000 --dry-run
  [ "$status" -eq 0 ]
  [ "$(_q "$output" type)"      = "TAKE_PROFIT_MARKET" ]
  [ "$(_q "$output" stopPrice)" = "65000.00" ]
  [ -z "$(_q "$output" price)" ]
}

@test "TAKE_PROFIT (limit variant) dry-run: includes price + stopPrice" {
  # mock mark = 60000. Use prices ~mark and raise --max-slippage so the
  # slippage gate doesn't fire on the 60100 entry.
  run _order_place --symbol BTCUSDT --side SELL --type TAKE_PROFIT \
    --quantity 0.002 --price 60100 --stop-price 60050 \
    --max-slippage 0.10 --dry-run
  [ "$status" -eq 0 ]
  [ "$(_q "$output" type)"      = "TAKE_PROFIT" ]
  [ "$(_q "$output" price)"     = "60100.00" ]
  [ "$(_q "$output" stopPrice)" = "60050.00" ]
}

# -------------------------------------------------------- TRAILING_STOP_MARKET

@test "TRAILING_STOP_MARKET dry-run: emits callbackRate + activationPrice" {
  run _order_place --symbol BTCUSDT --side SELL --type TRAILING_STOP_MARKET \
    --quantity 0.002 --callback-rate 1.5 --activation-price 65000 --dry-run
  [ "$status" -eq 0 ]
  [ "$(_q "$output" type)"             = "TRAILING_STOP_MARKET" ]
  [ "$(_q "$output" callbackRate)"     = "1.5" ]
  [ "$(_q "$output" activationPrice)"  = "65000.00" ]
  [ -z "$(_q "$output" price)" ]
  [ -z "$(_q "$output" timeInForce)" ]
}

@test "TRAILING_STOP_MARKET without --callback-rate fails BAD_ARGS" {
  run _order_place --symbol BTCUSDT --side SELL --type TRAILING_STOP_MARKET \
    --quantity 0.002 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("requires --callback-rate")' >/dev/null
}

@test "TRAILING_STOP_MARKET callback-rate too low (0.05) fails BAD_ARGS" {
  run _order_place --symbol BTCUSDT --side SELL --type TRAILING_STOP_MARKET \
    --quantity 0.002 --callback-rate 0.05 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("callbackRate")' >/dev/null
}

@test "TRAILING_STOP_MARKET callback-rate too high (10) fails BAD_ARGS" {
  run _order_place --symbol BTCUSDT --side SELL --type TRAILING_STOP_MARKET \
    --quantity 0.002 --callback-rate 10 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

# -------------------------------------------------------- closePosition rules

@test "closePosition on STOP_MARKET: omits quantity, includes closePosition=true" {
  run _order_place --symbol BTCUSDT --side SELL --type STOP_MARKET \
    --quantity 0.001 --stop-price 50000 --close-position --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(_q "$output" quantity)" ]
  [ "$(_q "$output" closePosition)" = "true" ]
  # Notional is forced to 0 so it never trips FUTURES_MAX_NOTIONAL.
  echo "$output" | jq -e '.data.estimated_notional == "0"' >/dev/null
}

@test "closePosition on LIMIT fails BAD_ARGS (only valid on *_MARKET stops)" {
  run _order_place --symbol BTCUSDT --side SELL --type LIMIT \
    --quantity 0.002 --price 60000 --close-position --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("--close-position only valid")' >/dev/null
}

@test "closePosition + reduceOnly are mutually exclusive" {
  run _order_place --symbol BTCUSDT --side SELL --type STOP_MARKET \
    --quantity 0.001 --stop-price 50000 --close-position --reduce-only --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("mutually exclusive")' >/dev/null
}

@test "reduceOnly on plain LIMIT: emitted as reduceOnly=true" {
  run _order_place --symbol BTCUSDT --side SELL --type LIMIT \
    --quantity 0.002 --price 60000 --reduce-only --dry-run
  [ "$status" -eq 0 ]
  [ "$(_q "$output" reduceOnly)" = "true" ]
  [ -z "$(_q "$output" closePosition)" ]
}

# -------------------------------------------------------- slippage gate ------

@test "slippage gate: LIMIT 0.83% off mark fails at default 0.5%" {
  # mock mark = 60000. 60500 is +0.833%, default --max-slippage 0.005.
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --price 60500 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "SLIPPAGE_EXCEEDED"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("60500")' >/dev/null
  echo "$output" | jq -e '.error.message | contains("60000")' >/dev/null
}

@test "slippage gate: same price with --max-slippage 0.02 (2%) passes" {
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --price 60500 --max-slippage 0.02 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.max_slippage == "0.02"' >/dev/null
}

@test "slippage gate: --max-slippage 0 disables the check entirely" {
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --price 99999 --max-slippage 0 --dry-run
  [ "$status" -eq 0 ]
}

@test "slippage gate: MARKET (no explicit price) bypasses gate" {
  # MARKET forces price=0; gate is only run for price-bearing types.
  run _order_place --symbol BTCUSDT --side BUY --type MARKET \
    --quantity 0.002 --dry-run
  [ "$status" -eq 0 ]
}

@test "slippage gate: STOP_MARKET (no limit price) bypasses gate" {
  run _order_place --symbol BTCUSDT --side SELL --type STOP_MARKET \
    --quantity 0.002 --stop-price 50000 --dry-run
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------- type rejection -----

@test "unsupported --type fails BAD_ARGS with help hint" {
  run _order_place --symbol BTCUSDT --side BUY --type FOO_BAR \
    --quantity 0.002 --price 60000 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("unsupported --type FOO_BAR")' >/dev/null
  echo "$output" | jq -e '.error.hint | contains("LIMIT")' >/dev/null
}

@test "missing --symbol fails BAD_ARGS" {
  run _order_place --side BUY --type LIMIT --quantity 0.002 --price 60000 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("--symbol --side --type --quantity required")' >/dev/null
}

# -------------------------------------------------------- positionSide / hedge

@test "positionSide=LONG: included as positionSide=LONG when not BOTH" {
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --price 60000 --position-side LONG --dry-run
  [ "$status" -eq 0 ]
  [ "$(_q "$output" positionSide)" = "LONG" ]
}

@test "positionSide=BOTH: omitted from query (one-way mode default)" {
  run _order_place --symbol BTCUSDT --side BUY --type LIMIT \
    --quantity 0.002 --price 60000 --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(_q "$output" positionSide)" ]
}
