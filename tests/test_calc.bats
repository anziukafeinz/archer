#!/usr/bin/env bats
# M8 — pure-compute calc subcommands: size, liq, pnl, basis (no symbol).
# All tests are offline; basis with --symbol exercises the public_get path
# via the fixture mock.

load 'helpers.bash'

setup() { source_common_and_calc; }

# ---------------------------- calc size ----------------------------

@test "calc size: 1% risk on 1000 USDT, 1000 spread => 0.01" {
  run calc_dispatch size --equity 1000 --risk-pct 1 \
    --entry 60000 --stop 59000
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.ok')" = "true" ]
  [ "$(echo "$output" | jq -r '.data.suggested_quantity')" = "0.01" ]
  [ "$(echo "$output" | jq -r '.data.risk_usd')" = "10" ]
}

@test "calc size: missing args => BAD_ARGS" {
  run calc_dispatch size --equity 1000
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "calc size: equity <= 0 rejected" {
  run calc_dispatch size --equity 0 --risk-pct 1 --entry 100 --stop 99
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
  echo "$output" | jq -e '.error.message | test("equity")' >/dev/null
}

@test "calc size: risk-pct out of (0,100] rejected" {
  run calc_dispatch size --equity 1000 --risk-pct 101 --entry 100 --stop 99
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "calc size: entry == stop rejected" {
  run calc_dispatch size --equity 1000 --risk-pct 1 --entry 100 --stop 100
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.message | test("entry and stop")' >/dev/null
}

# ---------------------------- calc liq -----------------------------

@test "calc liq: LONG 5x, mmr=0.004, entry=60000 => 48240" {
  run calc_dispatch liq --entry 60000 --quantity 0.01 \
    --leverage 5 --side LONG
  [ "$status" -eq 0 ]
  # 60000 * (1 - 1/5 + 0.004) = 60000 * 0.804 = 48240
  [ "$(echo "$output" | jq -r '.data.estimated_liq_price')" = "48240.000" ]
  [ "$(echo "$output" | jq -r '.data.side')" = "LONG" ]
}

@test "calc liq: SHORT 5x, entry=60000 => 71760" {
  run calc_dispatch liq --entry 60000 --quantity 0.01 \
    --leverage 5 --side SHORT
  [ "$status" -eq 0 ]
  # 60000 * (1 + 1/5 - 0.004) = 60000 * 1.196 = 71760
  [ "$(echo "$output" | jq -r '.data.estimated_liq_price')" = "71760.000" ]
}

@test "calc liq: invalid --side rejected" {
  run calc_dispatch liq --entry 60000 --quantity 0.01 \
    --leverage 5 --side BOTH
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "calc liq: missing required args rejected" {
  run calc_dispatch liq --entry 60000
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

# ---------------------------- calc pnl -----------------------------

@test "calc pnl: LONG 60000->61000, qty 0.01 => +10" {
  run calc_dispatch pnl --side LONG --entry 60000 --exit 61000 \
    --quantity 0.01
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.data.pnl_quote')" = "10.00" ]
}

@test "calc pnl: SHORT 60000->59000 with 5x => roi=8.333%" {
  run calc_dispatch pnl --side SHORT --entry 60000 --exit 59000 \
    --quantity 0.01 --leverage 5
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.data.pnl_quote')" = "10.00" ]
  # margin = 60000*0.01/5 = 120; ROI = 10/120 = 8.333...%
  echo "$output" | jq -e '(.data.roi_on_margin | tonumber) > 8.3' >/dev/null
  echo "$output" | jq -e '(.data.roi_on_margin | tonumber) < 8.4' >/dev/null
}

@test "calc pnl: missing args rejected" {
  run calc_dispatch pnl --entry 100
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

# ---------------------------- calc basis ---------------------------

@test "calc basis: explicit prices => correct annualization" {
  # futures=60100, spot=60000, h=8 (Binance default). basis=0.16667%,
  # windows/yr = 24/8 * 365 = 1095. APR = 0.16667 * 1095 = 182.5%.
  run calc_dispatch basis --futures-price 60100 --spot-price 60000 --hours 8
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.data.basis_pct | tonumber) > 0.166' >/dev/null
  echo "$output" | jq -e '(.data.basis_pct | tonumber) < 0.167' >/dev/null
  echo "$output" | jq -e '(.data.basis_annualized_pct | tonumber) > 182' >/dev/null
  echo "$output" | jq -e '(.data.basis_annualized_pct | tonumber) < 183' >/dev/null
}

@test "calc basis: requires --symbol or both --futures-price and --spot-price" {
  run calc_dispatch basis --futures-price 60100
  [ "$status" -ne 0 ]
  [ "$(echo "$output" | jq -r '.error.code')" = "BAD_ARGS" ]
}

@test "calc basis: live mode via mocked public_get fixture" {
  cat >"$TMPDIR/premium-single.json" <<'JSON'
{"symbol":"BTCUSDT","markPrice":"60100.00","indexPrice":"60000.00","time":1}
JSON
  mock_public_get_fixture "$TMPDIR/premium-single.json"
  run calc_dispatch basis --symbol BTCUSDT --hours 8
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.data.symbol')" = "BTCUSDT" ]
  [ "$(echo "$output" | jq -r '.data.futures_price')" = "60100.00" ]
  [ "$(echo "$output" | jq -r '.data.spot_price')" = "60000.00" ]
}

# ---------------------------- output schema ------------------------

@test "calc size: standard ok_json envelope" {
  run calc_dispatch size --equity 1000 --risk-pct 1 \
    --entry 100 --stop 99
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok and .venue == "binance" and .network == "testnet"' >/dev/null
  echo "$output" | jq -e '.command == "calc size"' >/dev/null
  echo "$output" | jq -e 'has("data") and has("warnings") and has("error")' >/dev/null
}
