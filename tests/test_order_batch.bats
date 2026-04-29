#!/usr/bin/env bats
# Unit tests for `order place-batch` and `order cancel-batch` (M7).
# Network is mocked so these run offline.

load helpers.bash

setup() {
  source_common_and_order
  mock_signed_req
  CMD="order test"
}

# Tiny helper to write a JSON orders array to a temp file.
_orders_file() {  # $1 = JSON array string
  local f="$TMPDIR/orders.json"
  printf '%s' "$1" >"$f"
  echo "$f"
}

# -------------------------------------------------------------- place-batch (dry)

@test "place-batch dry-run: 2 LIMIT orders returns normalized array + summed notional" {
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY", "type":"LIMIT","quantity":"0.002","price":"60000","timeInForce":"GTC"},
    {"symbol":"ETHUSDT","side":"SELL","type":"LIMIT","quantity":"0.10","price":"3000","timeInForce":"GTC"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.ok == true'                          >/dev/null
  echo "$output" | jq -e '.command == "order test"'             >/dev/null
  echo "$output" | jq -e '.network == "testnet"'                >/dev/null
  echo "$output" | jq -e '.data.dry_run == true'                >/dev/null
  echo "$output" | jq -e '.data.count == 2'                     >/dev/null
  echo "$output" | jq -e '.data.would_send | length == 2'       >/dev/null
  echo "$output" | jq -e '.data.would_send[0].symbol == "BTCUSDT"'    >/dev/null
  echo "$output" | jq -e '.data.would_send[0].quantity == "0.002"'    >/dev/null
  echo "$output" | jq -e '.data.would_send[0].price == "60000.00"'    >/dev/null
  echo "$output" | jq -e '.data.would_send[0].newClientOrderId | startswith("ai-")' >/dev/null
  echo "$output" | jq -e '.data.would_send[1].symbol == "ETHUSDT"'    >/dev/null
  # 0.002 * 60000 + 0.10 * 3000 = 120 + 300 = 420
  echo "$output" | jq -e '.data.estimated_notional == "420.00000"' >/dev/null
}

@test "place-batch dry-run: rounds qty/price per filter before emitting" {
  # BTCUSDT stepSize=0.001 / tickSize=0.10. 0.0059 -> 0.005, 60000.55 -> 60000.50
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.0059","price":"60000.55","timeInForce":"GTC"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.would_send[0].quantity == "0.005"'    >/dev/null
  echo "$output" | jq -e '.data.would_send[0].price    == "60000.50"' >/dev/null
}

@test "place-batch dry-run: respects user-supplied newClientOrderId (idempotency)" {
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60000",
     "timeInForce":"GTC","newClientOrderId":"my-key-001"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.would_send[0].newClientOrderId == "my-key-001"' >/dev/null
}

@test "place-batch dry-run: optional flags (reduceOnly / positionSide / stopPrice) round-trip" {
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"SELL","type":"STOP_MARKET","quantity":"0.002",
     "stopPrice":"58000","reduceOnly":"true","positionSide":"LONG"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.data.would_send[0].type         == "STOP_MARKET"' >/dev/null
  echo "$output" | jq -e '.data.would_send[0].stopPrice    == "58000"'        >/dev/null
  echo "$output" | jq -e '.data.would_send[0].reduceOnly   == "true"'         >/dev/null
  echo "$output" | jq -e '.data.would_send[0].positionSide == "LONG"'         >/dev/null
  # MARKET-style: no price/timeInForce should be present
  echo "$output" | jq -e '.data.would_send[0] | has("price") | not'           >/dev/null
}

# -------------------------------------------------------------- place-batch (errors)

@test "place-batch: missing both --orders-file and --orders -> BAD_ARGS" {
  run _order_place_batch --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "place-batch: empty array -> BATCH_SIZE error" {
  local f; f=$(_orders_file '[]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BATCH_SIZE"' >/dev/null
}

@test "place-batch: 6 orders -> BATCH_SIZE error" {
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60000"},
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60001"},
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60002"},
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60003"},
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60004"},
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60005"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BATCH_SIZE"'         >/dev/null
  echo "$output" | jq -re '.error.message' | grep -q 'got 6'
}

@test "place-batch: per-order missing required field -> BAD_ARGS at idx" {
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60000"},
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","price":"60000"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"'        >/dev/null
  echo "$output" | jq -re '.error.message' | grep -q 'order\[1\]'
}

@test "place-batch: per-order minNotional violation surfaces INVALID_ORDER" {
  # BTCUSDT minNotional=5; 0.001 * 1 = 0.001 USDT < 5
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.001","price":"1"}
  ]')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -ne 0 ]
  # validate_order itself dies with MIN_NOTIONAL; that JSON is what surfaces.
  echo "$output" | jq -e '.error.code == "MIN_NOTIONAL"' >/dev/null
}

@test "place-batch: non-array JSON payload -> BAD_ARGS" {
  local f; f=$(_orders_file '{"not":"an-array"}')
  run _order_place_batch --orders-file "$f" --dry-run
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

# -------------------------------------------------------------- place-batch (live, mocked)

@test "place-batch (mocked): sends POST /fapi/v1/batchOrders with URL-encoded JSON" {
  local f
  f=$(_orders_file '[
    {"symbol":"BTCUSDT","side":"BUY","type":"LIMIT","quantity":"0.002","price":"60000","timeInForce":"GTC"}
  ]')
  run _order_place_batch --orders-file "$f"
  [ "$status" -eq 0 ]
  # signed_req invocation logged
  [ -s "$SIGNED_REQ_LOG" ]
  local line method path q
  line=$(cat "$SIGNED_REQ_LOG")
  method=$(echo "$line" | cut -f1)
  path=$(echo   "$line" | cut -f2)
  q=$(echo      "$line" | cut -f3)
  [ "$method" = "POST" ]
  [ "$path"   = "/fapi/v1/batchOrders" ]
  [[ "$q" == batchOrders=* ]]
  # The encoded JSON should round-trip back to a 1-element array
  python3 -c "
import sys, urllib.parse, json
q = sys.argv[1]
assert q.startswith('batchOrders=')
arr = json.loads(urllib.parse.unquote(q[len('batchOrders='):]))
assert isinstance(arr, list) and len(arr) == 1
assert arr[0]['symbol'] == 'BTCUSDT'
assert arr[0]['quantity'] == '0.002'
assert arr[0]['price'] == '60000.00'
" "$q"
}

# -------------------------------------------------------------- cancel-batch

@test "cancel-batch: missing --symbol -> BAD_ARGS" {
  run _order_cancel_batch --order-ids 1,2,3
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "cancel-batch: missing both id lists -> BAD_ARGS" {
  run _order_cancel_batch --symbol BTCUSDT
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}

@test "cancel-batch: --order-ids builds DELETE with orderIdList=[1,2,3]" {
  run _order_cancel_batch --symbol BTCUSDT --order-ids 1,2,3
  [ "$status" -eq 0 ]
  local line method path q
  line=$(cat "$SIGNED_REQ_LOG")
  method=$(echo "$line" | cut -f1)
  path=$(echo   "$line" | cut -f2)
  q=$(echo      "$line" | cut -f3)
  [ "$method" = "DELETE" ]
  [ "$path"   = "/fapi/v1/batchOrders" ]
  [[ "$q" == *symbol=BTCUSDT* ]]
  [[ "$q" == *orderIdList=* ]]
  python3 -c "
import sys, urllib.parse, json
q = sys.argv[1]
parts = dict(p.split('=', 1) for p in q.split('&'))
ids = json.loads(urllib.parse.unquote(parts['orderIdList']))
assert ids == [1, 2, 3], ids
" "$q"
}

@test "cancel-batch: --client-order-ids builds origClientOrderIdList JSON array" {
  run _order_cancel_batch --symbol ETHUSDT --client-order-ids 'a,b,c'
  [ "$status" -eq 0 ]
  local q
  q=$(cut -f3 "$SIGNED_REQ_LOG")
  [[ "$q" == *origClientOrderIdList=* ]]
  python3 -c "
import sys, urllib.parse, json
q = sys.argv[1]
parts = dict(p.split('=', 1) for p in q.split('&'))
ids = json.loads(urllib.parse.unquote(parts['origClientOrderIdList']))
assert ids == ['a', 'b', 'c'], ids
" "$q"
}

@test "cancel-batch: --order-ids with non-numeric token fails BAD_ARGS" {
  run _order_cancel_batch --symbol BTCUSDT --order-ids '1,foo,3'
  [ "$status" -ne 0 ]
  echo "$output" | jq -e '.error.code == "BAD_ARGS"' >/dev/null
}
