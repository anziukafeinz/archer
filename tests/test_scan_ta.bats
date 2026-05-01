#!/usr/bin/env bats
# M8 — `scan funding` + `ta` indicators. Uses fixtures to keep tests
# hermetic (no live klines or premiumIndex calls).

load 'helpers.bash'

setup() { source_common_and_calc; }

# ----------------------------- scan funding ------------------------

@test "scan funding: top 2 ranks by lastFundingRate (DOGE most-negative, SOL most-positive)" {
  mock_public_get_fixture premiumIndex.json
  run scan_dispatch funding --top 2
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.count == 5' >/dev/null
  echo "$output" | jq -e '.data.top_negative | length == 2' >/dev/null
  echo "$output" | jq -e '.data.top_positive | length == 2' >/dev/null
  [ "$(echo "$output" | jq -r '.data.top_negative[0].symbol')" = "DOGEUSDT" ]
  [ "$(echo "$output" | jq -r '.data.top_positive[0].symbol')" = "SOLUSDT" ]
}

@test "scan funding: default top=10 caps at total count when fewer symbols exist" {
  mock_public_get_fixture premiumIndex.json
  run scan_dispatch funding
  [ "$status" -eq 0 ]
  # Fixture has 5 entries; default --top 10 should clip to whatever is there.
  [ "$(echo "$output" | jq -r '.data.top_positive | length')" = "5" ]
}

@test "scan funding: --top 0 rejected" {
  run scan_dispatch funding --top 0
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "scan funding: --top non-integer rejected" {
  run scan_dispatch funding --top abc
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "scan funding: malformed response rejected with BAD_RESPONSE" {
  cat >"$TMPDIR/premium-bad.json" <<'JSON'
{"err":"not an array"}
JSON
  mock_public_get_fixture "$TMPDIR/premium-bad.json"
  run scan_dispatch funding --top 5
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_RESPONSE" ]
}

# ------------------------------- ta -------------------------------

@test "ta sma: monotonic closes 10..34, period 5 => SMA = 32" {
  mock_public_get_fixture klines_monotonic.json
  run ta_dispatch sma --symbol BTCUSDT --interval 1h --period 5
  [ "$status" -eq 0 ]
  # Compare numerically to be robust across jq versions: jq 1.6 prints 32.0
  # as "32" while jq 1.7+ prints it as "32.0".
  echo "$output" | jq -e '(.data.value | tonumber) == 32' >/dev/null
  [ "$(echo "$output" | jq -r '.data.indicator')" = "sma" ]
  echo "$output" | jq -e '(.data.candles | tonumber) == 25' >/dev/null
  echo "$output" | jq -e '(.data.last_close | tonumber) == 34' >/dev/null
}

@test "ta ema: monotonic +1 step closes => EMA(5) ~= 32" {
  mock_public_get_fixture klines_monotonic.json
  run ta_dispatch ema --symbol BTCUSDT --interval 1h --period 5
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.value | tonumber) > 31.99' >/dev/null
  echo "$output" | jq -e '(.data.value | tonumber) < 32.01' >/dev/null
}

@test "ta rsi: all-gains series => RSI = 100" {
  mock_public_get_fixture klines_monotonic.json
  run ta_dispatch rsi --symbol BTCUSDT --interval 1h --period 14
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.value | tonumber) == 100' >/dev/null
}

@test "ta atr: range 1, body 1, prev_close=close-1 => TR=1.5 => ATR=1.5" {
  mock_public_get_fixture klines_monotonic.json
  run ta_dispatch atr --symbol BTCUSDT --interval 1h --period 14
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.value | tonumber) == 1.5' >/dev/null
}

@test "ta bbands: monotonic closes period 5 => middle=32, stddev=sqrt(2)" {
  mock_public_get_fixture klines_monotonic.json
  run ta_dispatch bbands --symbol BTCUSDT --interval 1h --period 5
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.bbands.middle | tonumber) == 32' >/dev/null
  echo "$output" | jq -e '(.data.bbands.stddev | tonumber) > 1.414' >/dev/null
  echo "$output" | jq -e '(.data.bbands.stddev | tonumber) < 1.415' >/dev/null
  echo "$output" | jq -e '(.data.bbands.upper | tonumber) > 34.82' >/dev/null
  echo "$output" | jq -e '(.data.bbands.lower | tonumber) < 29.18' >/dev/null
}

@test "ta: missing --symbol rejected" {
  run ta_dispatch sma --interval 1h --period 5
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "ta: --period < 2 rejected" {
  run ta_dispatch sma --symbol BTCUSDT --period 1
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "ta: unknown indicator rejected with UNKNOWN_CMD" {
  run ta_dispatch macd --symbol BTCUSDT
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "UNKNOWN_CMD" ]
}

@test "ta: malformed klines rejected with BAD_RESPONSE" {
  cat >"$TMPDIR/klines-bad.json" <<'JSON'
{"code":-1121,"msg":"Invalid symbol."}
JSON
  mock_public_get_fixture "$TMPDIR/klines-bad.json"
  run ta_dispatch sma --symbol FAKEUSDT --period 5
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_RESPONSE" ]
}

@test "ta sma: standard ok_json envelope" {
  mock_public_get_fixture klines_monotonic.json
  run ta_dispatch sma --symbol BTCUSDT --period 5
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok and .venue == "binance" and .network == "testnet"' >/dev/null
  echo "$output" | jq -e '.command == "ta sma"' >/dev/null
  echo "$output" | jq -e 'has("data") and has("warnings") and has("error")' >/dev/null
}
