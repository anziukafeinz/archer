#!/usr/bin/env bats
# Unit tests for scripts/_common.sh helpers (M4: risk-layer + filter rounding).

load helpers.bash

setup() {
  source_common
}

# ------------------------------------------------------------------- round_down

@test "round_down: 0.123456 by stepSize 0.001 -> 0.123" {
  run round_down 0.123456 0.001
  [ "$status" -eq 0 ]
  [ "$output" = "0.123" ]
}

@test "round_down: 60001.55 by tickSize 0.10 -> 60001.50" {
  run round_down 60001.55 0.10
  [ "$status" -eq 0 ]
  [ "$output" = "60001.50" ]
}

@test "round_down: exact multiple is unchanged" {
  run round_down 0.500 0.001
  [ "$status" -eq 0 ]
  [ "$output" = "0.500" ]
}

@test "round_down: integer step, fractional value floors" {
  run round_down 1234.9 1
  [ "$status" -eq 0 ]
  [ "$output" = "1234" ]
}

@test "round_down: very small step keeps full precision" {
  # DOGEUSDT-style price tickSize=0.00001
  run round_down 0.123456789 0.00001
  [ "$status" -eq 0 ]
  [ "$output" = "0.12345" ]
}

# ---------------------------------------------------------------- symbol_filters

@test "symbol_filters: BTCUSDT returns expected tickSize / stepSize / minNotional" {
  run symbol_filters BTCUSDT
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.tickSize == "0.10"'    >/dev/null
  echo "$output" | jq -e '.stepSize == "0.001"'   >/dev/null
  echo "$output" | jq -e '.minNotional == "5"'    >/dev/null
}

@test "symbol_filters: unknown symbol returns empty" {
  run symbol_filters DOESNOTEXISTUSDT
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------- validate_order

@test "validate_order: BTCUSDT 0.005 @ 60000.55 -> rounded to step/tick" {
  run validate_order BTCUSDT 0.005 60000.55
  [ "$status" -eq 0 ]
  # qty unchanged (already on stepSize); price rounded down to tick 0.10.
  # Decimal arithmetic preserves trailing zeros from the divisor's scale.
  [ "$output" = "0.005 60000.50" ]
}

@test "validate_order: qty 0.0059 rounds DOWN (never up) to 0.005 stepSize 0.001" {
  run validate_order BTCUSDT 0.0059 60000
  [ "$status" -eq 0 ]
  [ "$output" = "0.005 60000.00" ]
}

@test "validate_order: rejects qty below minQty as INVALID_QUANTITY" {
  # BTCUSDT minQty = 0.001, stepSize = 0.001. 0.0009 floors to 0.000.
  run validate_order BTCUSDT 0.0009 60000
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.ok == false'                    >/dev/null
  echo "$output" | jq -e '.error.code == "INVALID_QUANTITY"' >/dev/null
}

@test "validate_order: rejects when qty*price below minNotional" {
  # BTCUSDT minNotional = 5; 0.001 * 1000 = 1 < 5
  run validate_order BTCUSDT 0.001 1000
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "MIN_NOTIONAL"' >/dev/null
}

@test "validate_order: market order (price=0) skips minNotional check" {
  run validate_order BTCUSDT 0.001 0
  [ "$status" -eq 0 ]
  [ "$output" = "0.001 0" ]
}

@test "validate_order: unknown symbol -> INVALID_SYMBOL" {
  run validate_order NOPEUSDT 0.001 1000
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "INVALID_SYMBOL"' >/dev/null
}

@test "validate_order: DOGEUSDT integer stepSize floors fractional qty" {
  # stepSize=1, minQty=1, minNotional=5; 100 * 0.1 = 10 OK
  run validate_order DOGEUSDT 100.7 0.10000
  [ "$status" -eq 0 ]
  [ "$output" = "100 0.10000" ]
}

# -------------------------------------------------------------- idempotency

@test "gen_client_order_id: matches ai-<epoch_ms>-<rand> shape" {
  run gen_client_order_id
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^ai-[0-9]{13}-[0-9]+$ ]]
}

@test "gen_client_order_id: two calls produce different ids" {
  local a b
  a=$(gen_client_order_id)
  # tiny sleep so the epoch_ms component advances
  sleep 0.002
  b=$(gen_client_order_id)
  [ "$a" != "$b" ]
}

# ----------------------------------------------------------- confirmation gate

@test "require_confirmation: testnet always passes regardless of env" {
  # default FUTURES_NETWORK=testnet
  run require_confirmation 99999 100
  [ "$status" -eq 0 ]
}

@test "require_confirmation: mainnet without FUTURES_CONFIRM=yes -> CONFIRMATION_REQUIRED" {
  unset FUTURES_CONFIRM
  FUTURES_NETWORK=mainnet ARG_CONFIRM=1 run require_confirmation 100 1
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
}

@test "require_confirmation: mainnet without --confirm flag -> CONFIRMATION_REQUIRED" {
  FUTURES_NETWORK=mainnet FUTURES_CONFIRM=yes ARG_CONFIRM=0 \
    run require_confirmation 100 1
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
  echo "$output" | jq -re '.error.message' | grep -q -- '--confirm flag'
}

@test "require_confirmation: mainnet over FUTURES_MAX_NOTIONAL -> blocked" {
  FUTURES_NETWORK=mainnet FUTURES_CONFIRM=yes ARG_CONFIRM=1 \
  FUTURES_MAX_NOTIONAL=1000 \
    run require_confirmation 1000.01 1
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
}

@test "require_confirmation: mainnet over FUTURES_MAX_LEVERAGE -> blocked" {
  FUTURES_NETWORK=mainnet FUTURES_CONFIRM=yes ARG_CONFIRM=1 \
  FUTURES_MAX_LEVERAGE=5 \
    run require_confirmation 100 6
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
}

@test "require_confirmation: mainnet within all limits -> passes" {
  FUTURES_NETWORK=mainnet FUTURES_CONFIRM=yes ARG_CONFIRM=1 \
  FUTURES_MAX_NOTIONAL=1000 FUTURES_MAX_LEVERAGE=5 \
    run require_confirmation 500 3
  [ "$status" -eq 0 ]
}

# -------------------------------------------------------------------- signing

@test "sign: known HMAC-SHA256 vector matches openssl reference" {
  local key="abcdefghijklmnop"
  local msg="symbol=BTCUSDT&timestamp=1700000000000"
  local expected
  expected=$(printf '%s' "$msg" | openssl dgst -sha256 -hmac "$key" | awk '{print $NF}')
  FUTURES_API_SECRET="$key" run sign "$msg"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  # And it should be 64 hex chars.
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}
