#!/usr/bin/env bats
# Unit tests for `position set-leverage / set-margin-type / set-position-mode`
# and friends (M6). Network is mocked so these run offline.

load helpers.bash

setup() {
  source_common_and_account
  mock_signed_req
  CMD="position test"
}

# Helper: extract a single key=value from the would_send querystring.
_q() {
  local out="$1" key="$2"
  echo "$out" | jq -r '.data.would_send' \
    | tr '&' '\n' \
    | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

# ---------------------------------------------------------------- set-leverage

@test "set-leverage dry-run: emits symbol+leverage in standard envelope" {
  run _position_set_leverage --symbol BTCUSDT --leverage 5 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'             >/dev/null
  echo "$output" | jq -e '.network == "testnet"'   >/dev/null
  echo "$output" | jq -e '.command == "position test"' >/dev/null
  echo "$output" | jq -e '.data.dry_run == true'   >/dev/null
  echo "$output" | jq -e '.data.symbol == "BTCUSDT"' >/dev/null
  echo "$output" | jq -e '.data.leverage == 5'     >/dev/null
  [ "$(_q "$output" symbol)"   = "BTCUSDT" ]
  [ "$(_q "$output" leverage)" = "5" ]
}

@test "set-leverage: missing --symbol -> BAD_ARGS" {
  run _position_set_leverage --leverage 5 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("--symbol and --leverage required")' >/dev/null
}

@test "set-leverage: leverage 0 -> BAD_ARGS (out of range)" {
  run _position_set_leverage --symbol BTCUSDT --leverage 0 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("out of range")' >/dev/null
}

@test "set-leverage: leverage 200 -> BAD_ARGS (above 125 hard cap)" {
  run _position_set_leverage --symbol BTCUSDT --leverage 200 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "set-leverage: non-integer (3.5) -> BAD_ARGS" {
  run _position_set_leverage --symbol BTCUSDT --leverage 3.5 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "set-leverage: testnet bypasses confirmation gate (no --confirm needed)" {
  # Default FUTURES_NETWORK=testnet from setup_futures_env; gate is a no-op.
  run _position_set_leverage --symbol BTCUSDT --leverage 10 --dry-run
  [ "$status" -eq 0 ]
}

@test "set-leverage: mainnet without --confirm -> CONFIRMATION_REQUIRED" {
  export FUTURES_NETWORK="mainnet"
  export FUTURES_CONFIRM="yes"
  run _position_set_leverage --symbol BTCUSDT --leverage 5 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
}

@test "set-leverage: mainnet over FUTURES_MAX_LEVERAGE -> blocked" {
  export FUTURES_NETWORK="mainnet"
  export FUTURES_CONFIRM="yes"
  export FUTURES_MAX_LEVERAGE="5"
  run _position_set_leverage --symbol BTCUSDT --leverage 10 --confirm --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
}

@test "set-leverage: mainnet within all limits with --confirm -> passes" {
  export FUTURES_NETWORK="mainnet"
  export FUTURES_CONFIRM="yes"
  export FUTURES_MAX_LEVERAGE="20"
  run _position_set_leverage --symbol BTCUSDT --leverage 5 --confirm --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.network == "mainnet"' >/dev/null
}

# ----------------------------------------------------------- set-margin-type

@test "set-margin-type dry-run: ISOLATED upper-cased into request" {
  run _position_set_margin_type --symbol BTCUSDT --margin-type isolated --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.marginType == "ISOLATED"' >/dev/null
  [ "$(_q "$output" marginType)" = "ISOLATED" ]
}

@test "set-margin-type dry-run: CROSSED accepted" {
  run _position_set_margin_type --symbol BTCUSDT --margin-type CROSSED --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.marginType == "CROSSED"' >/dev/null
}

@test "set-margin-type: invalid value rejected with hint" {
  run _position_set_margin_type --symbol BTCUSDT --margin-type CROSS --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.hint | contains("ISOLATED")' >/dev/null
  echo "$output" | jq -e '.error.hint | contains("CROSSED")' >/dev/null
}

@test "set-margin-type: missing --margin-type -> BAD_ARGS" {
  run _position_set_margin_type --symbol BTCUSDT --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

# --------------------------------------------------------- set-position-mode

@test "set-position-mode --mode hedge -> dualSidePosition=true" {
  run _position_set_position_mode --mode hedge --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.mode == "hedge"' >/dev/null
  echo "$output" | jq -e '.data.dualSidePosition == "true"' >/dev/null
  [ "$(_q "$output" dualSidePosition)" = "true" ]
}

@test "set-position-mode --mode one-way -> dualSidePosition=false" {
  run _position_set_position_mode --mode one-way --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.mode == "one-way"' >/dev/null
  echo "$output" | jq -e '.data.dualSidePosition == "false"' >/dev/null
}

@test "set-position-mode legacy --dual flag still accepted" {
  run _position_set_position_mode --dual true --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.dualSidePosition == "true"' >/dev/null
}

@test "set-position-mode --mode garbage -> BAD_ARGS" {
  run _position_set_position_mode --mode sideways --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.hint | contains("hedge")' >/dev/null
}

@test "set-position-mode --dual yes (not true|false) -> BAD_ARGS" {
  run _position_set_position_mode --dual yes --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "set-position-mode without any flag -> BAD_ARGS" {
  run _position_set_position_mode --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("--mode hedge|one-way required")' >/dev/null
}

# --------------------------------------------------------- get-position-mode

@test "get-position-mode: success returns {mode, dualSidePosition}" {
  # Override the mocked signed_req to emit Binance's real shape.
  signed_req() {
    echo '{"dualSidePosition":true}'
  }
  export -f signed_req
  run _position_get_position_mode
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.mode == "hedge"'           >/dev/null
  echo "$output" | jq -e '.data.dualSidePosition == true'  >/dev/null
}

@test "get-position-mode: false -> one-way" {
  signed_req() { echo '{"dualSidePosition":false}'; }
  export -f signed_req
  run _position_get_position_mode
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.mode == "one-way"' >/dev/null
}

@test "get-position-mode: venue error normalised" {
  signed_req() { echo '{"code":-1022,"msg":"Signature for this request is not valid."}'; }
  export -f signed_req
  run _position_get_position_mode
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "SIGNATURE"' >/dev/null
}

# --------------------------------------------------------- adjust-margin

@test "adjust-margin dry-run: positive amount add (type=1)" {
  run _position_adjust_margin --symbol BTCUSDT --amount 50 --type 1 --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.action == "add"'           >/dev/null
  echo "$output" | jq -e '.data.amount == "50"'            >/dev/null
  [ "$(_q "$output" type)"   = "1" ]
  [ "$(_q "$output" amount)" = "50" ]
}

@test "adjust-margin: invalid type rejected" {
  run _position_adjust_margin --symbol BTCUSDT --amount 50 --type 9 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "adjust-margin: zero amount rejected" {
  run _position_adjust_margin --symbol BTCUSDT --amount 0 --type 1 --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
  echo "$output" | jq -e '.error.message | contains("must be positive")' >/dev/null
}

@test "adjust-margin: mainnet over FUTURES_MAX_NOTIONAL blocks (uses amount as gate notional)" {
  export FUTURES_NETWORK="mainnet"
  export FUTURES_CONFIRM="yes"
  export FUTURES_MAX_NOTIONAL="100"
  run _position_adjust_margin --symbol BTCUSDT --amount 500 --type 1 --confirm --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "CONFIRMATION_REQUIRED"' >/dev/null
}
