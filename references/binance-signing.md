# Binance HMAC-SHA256 signing

Required for all `USER_DATA` and `TRADE` endpoints on `/fapi/*`.

## Algorithm
1. Build query string from all params (sorted is fine, not required) including
   `timestamp` (ms since epoch) and optional `recvWindow`.
2. Compute `signature = HMAC_SHA256(query_string, api_secret)` as lowercase hex.
3. Append `&signature=<sig>` to the query (or as form body for POST).
4. Send `X-MBX-APIKEY: <api_key>` header.

## Reference shell impl
```bash
sign() {
  # $1 = query string, $2 = secret
  printf '%s' "$1" | openssl dgst -sha256 -hmac "$2" | awk '{print $2}'
}

req() {
  # $1 = METHOD, $2 = path, $3 = query (without timestamp/signature)
  local method="$1" path="$2" q="$3"
  local ts="$(date +%s%3N)"
  local qs="${q:+$q&}timestamp=$ts&recvWindow=5000"
  local sig
  sig="$(sign "$qs" "$FUTURES_API_SECRET")"
  curl -sS -X "$method" \
    -H "X-MBX-APIKEY: $FUTURES_API_KEY" \
    "$BASE_URL$path?$qs&signature=$sig"
}
```

## Time sync
Drift > 1s causes `-1021 Timestamp for this request is outside of the recvWindow`.
Fix:
```bash
SERVER_TS=$(curl -sS "$BASE_URL/fapi/v1/time" | jq -r .serverTime)
LOCAL_TS=$(date +%s%3N)
TS_OFFSET=$((SERVER_TS - LOCAL_TS))
# then use: ts=$(( $(date +%s%3N) + TS_OFFSET ))
```

## Common errors
| Code | Meaning | Fix |
|---|---|---|
| -1021 | Timestamp outside recvWindow | sync time, increase recvWindow up to 60000 |
| -1022 | Invalid signature | check secret, query string ordering, URL-encoding of `&`/`=` in values |
| -2014 | API-key format invalid | trim whitespace from key |
| -2015 | Invalid API-key, IP, or permissions | check IP allowlist + Futures permission enabled |
| -4131 | PERCENT_PRICE filter | price too far from mark, widen or use MARK working type |
| -4164 | Order's notional too small | increase qty/price to meet `minNotional` |
| -2019 | Margin is insufficient | reduce qty or leverage, top up |
| -4061 | Order's position side does not match user's setting | hedge mode mismatch — set `positionSide` |
