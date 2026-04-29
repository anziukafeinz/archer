# shellcheck shell=bash
# _common.sh — signing, requests, validation, JSON output. Sourced by all
# other scripts. Never executed directly.
set -euo pipefail

: "${FUTURES_VENUE:=binance}"
: "${FUTURES_NETWORK:=testnet}"
: "${FUTURES_API_KEY:=}"
: "${FUTURES_API_SECRET:=}"

# Binance retired the old testnet.binancefuture.com domain in favour of the
# unified "Demo Mode" surface. Generate keys at https://demo.binance.com
# (My Settings -> API Management) and trade against demo-fapi.binance.com.
#
# Some networks / regions still get geo-blocked on demo-fapi while the
# legacy testnet host stays reachable. `FUTURES_BASE_URL`, when set,
# overrides the resolved BASE_URL for every request — useful for sandboxed
# CI runners and the legacy `https://testnet.binancefuture.com` host.
if [ -n "${FUTURES_BASE_URL:-}" ]; then
  BASE_URL="$FUTURES_BASE_URL"
else
  case "$FUTURES_VENUE:$FUTURES_NETWORK" in
    binance:testnet|binance:demo) BASE_URL="https://demo-fapi.binance.com" ;;
    binance:mainnet)               BASE_URL="https://fapi.binance.com" ;;
    *) echo "unsupported venue/network: $FUTURES_VENUE/$FUTURES_NETWORK" >&2; exit 2 ;;
  esac
fi

# --- output helpers -----------------------------------------------------------

ok_json() { # $1 = command label, $2 = data json
  jq -nc --arg v "$FUTURES_VENUE" --arg n "$FUTURES_NETWORK" \
        --arg c "$1" --argjson d "$2" \
        '{ok:true,venue:$v,network:$n,command:$c,data:$d,warnings:[],error:null}'
}

err_json() { # $1 = command, $2 = code, $3 = message, $4 = hint, $5 = raw json (optional)
  local raw="${5:-null}"
  jq -nc --arg v "$FUTURES_VENUE" --arg n "$FUTURES_NETWORK" \
        --arg c "$1" --arg code "$2" --arg msg "$3" --arg hint "$4" \
        --argjson raw "$raw" \
        '{ok:false,venue:$v,network:$n,command:$c,data:null,warnings:[],
          error:{code:$code,message:$msg,hint:$hint,raw:$raw}}'
}

die() { err_json "${CMD:-unknown}" "$1" "$2" "${3:-}"; exit 1; }

# --- time sync ----------------------------------------------------------------

_TS_OFFSET=""
sync_time() {
  [ -n "$_TS_OFFSET" ] && return 0
  local server local_
  server=$(curl -sS "$BASE_URL/fapi/v1/time" | jq -r .serverTime)
  local_=$(date +%s%3N)
  _TS_OFFSET=$((server - local_))
}
now_ms() { sync_time; echo $(( $(date +%s%3N) + _TS_OFFSET )); }

# --- signing ------------------------------------------------------------------

sign() { # $1 = querystring, returns hex sig on stdout
  printf '%s' "$1" | openssl dgst -sha256 -hmac "$FUTURES_API_SECRET" | awk '{print $NF}'
}

require_auth() {
  [ -n "$FUTURES_API_KEY" ]    || die "AUTH" "FUTURES_API_KEY not set" "export FUTURES_API_KEY"
  [ -n "$FUTURES_API_SECRET" ] || die "AUTH" "FUTURES_API_SECRET not set" "export FUTURES_API_SECRET"
}

# Public GET (no auth)
public_get() { # $1 = path, $2 = query
  curl -sS "$BASE_URL$1?$2"
}

# Signed request: $1 = METHOD, $2 = path, $3 = query (without ts/sig)
signed_req() {
  require_auth
  local method="$1" path="$2" q="${3:-}"
  local ts; ts=$(now_ms)
  local qs="${q:+$q&}timestamp=$ts&recvWindow=5000"
  local sig; sig=$(sign "$qs")
  curl -sS -X "$method" \
    -H "X-MBX-APIKEY: $FUTURES_API_KEY" \
    "$BASE_URL$path?$qs&signature=$sig"
}

# --- error normalization ------------------------------------------------------

normalize_error() { # stdin = raw venue response, stdout = normalized error or echo back if not error
  local raw; raw=$(cat)
  local code msg
  code=$(echo "$raw" | jq -r '.code // empty')
  msg=$(echo  "$raw" | jq -r '.msg  // empty')
  if [ -z "$code" ]; then echo "$raw"; return 0; fi

  local norm hint
  case "$code" in
    -2019) norm="INSUFFICIENT_MARGIN"; hint="Reduce qty, lower leverage, or top up" ;;
    -4003|-1013) norm="INVALID_QUANTITY"; hint="Round qty to stepSize (see exchangeInfo)" ;;
    -4014) norm="INVALID_PRICE"; hint="Round price to tickSize" ;;
    -4164) norm="MIN_NOTIONAL"; hint="Increase qty*price >= minNotional" ;;
    -4028) norm="LEVERAGE_TOO_HIGH"; hint="Lower leverage; check tier ladder" ;;
    -4061) norm="POSITION_SIDE_MISMATCH"; hint="Set positionSide=LONG/SHORT in hedge mode" ;;
    -2022) norm="REDUCE_ONLY_REJECT"; hint="Position too small or wrong side" ;;
    -1003|-1015) norm="RATE_LIMIT"; hint="Back off and respect Retry-After" ;;
    -1021) norm="TIMESTAMP"; hint="Run sync_time; increase recvWindow up to 60000" ;;
    -1022) norm="SIGNATURE"; hint="Check secret + querystring encoding" ;;
    -2013) norm="UNKNOWN_ORDER"; hint="Order id wrong or already filled/cancelled" ;;
    *)     norm="VENUE_ERROR"; hint="See raw" ;;
  esac
  err_json "${CMD:-unknown}" "$norm" "$msg" "$hint" "$raw"
  return 1
}

# --- validation against exchangeInfo -----------------------------------------

# Cache exchangeInfo to /tmp for 1 hour to avoid hammering on every call.
EX_CACHE="${TMPDIR:-/tmp}/futures-cli-exinfo-$FUTURES_VENUE-$FUTURES_NETWORK.json"
load_exchange_info() {
  if [ ! -f "$EX_CACHE" ] || [ "$(find "$EX_CACHE" -mmin -60 2>/dev/null)" = "" ]; then
    curl -sS "$BASE_URL/fapi/v1/exchangeInfo" > "$EX_CACHE.tmp" && mv "$EX_CACHE.tmp" "$EX_CACHE"
  fi
}

symbol_filters() { # $1 = symbol; emits {tickSize, stepSize, minQty, minNotional}
  load_exchange_info
  jq -c --arg s "$1" '
    .symbols[] | select(.symbol==$s) | {
      tickSize:    (.filters[] | select(.filterType=="PRICE_FILTER")  | .tickSize),
      stepSize:    (.filters[] | select(.filterType=="LOT_SIZE")      | .stepSize),
      minQty:      (.filters[] | select(.filterType=="LOT_SIZE")      | .minQty),
      minNotional: (.filters[] | select(.filterType=="MIN_NOTIONAL")  | .notional)
    }' "$EX_CACHE"
}

round_down() { # $1 = value, $2 = increment  (uses python for arbitrary precision)
  python3 -c "import sys,decimal;d=decimal.Decimal;v=d(sys.argv[1]);i=d(sys.argv[2]);print((v//i)*i)" "$1" "$2"
}

# Validate qty/price against exchange filters. Echoes the (possibly rounded)
# values on stdout as 'qty price'. Aborts on minNotional/minQty failure.
validate_order() { # $1=symbol $2=qty $3=price (or 0 for market)
  local sym="$1" qty="$2" price="$3"
  local filt; filt=$(symbol_filters "$sym")
  [ -z "$filt" ] && die "INVALID_SYMBOL" "symbol $sym not found" "Run: futures-cli market exchange-info"
  local tick step minq minn
  tick=$(echo "$filt" | jq -r .tickSize)
  step=$(echo "$filt" | jq -r .stepSize)
  minq=$(echo "$filt" | jq -r .minQty)
  minn=$(echo "$filt" | jq -r .minNotional)

  qty=$(round_down "$qty" "$step")
  if python3 -c "import sys,decimal;sys.exit(0 if decimal.Decimal(sys.argv[1])>=decimal.Decimal(sys.argv[2]) else 1)" "$qty" "$minq"; then :
  else die "INVALID_QUANTITY" "qty $qty < minQty $minq" "Increase qty"; fi

  if [ "$price" != "0" ]; then
    price=$(round_down "$price" "$tick")
    local notional
    notional=$(python3 -c "import sys,decimal;print(decimal.Decimal(sys.argv[1])*decimal.Decimal(sys.argv[2]))" "$qty" "$price")
    if python3 -c "import sys,decimal;sys.exit(0 if decimal.Decimal(sys.argv[1])>=decimal.Decimal(sys.argv[2]) else 1)" "$notional" "$minn"; then :
    else die "MIN_NOTIONAL" "notional $notional < $minn" "Increase qty or price"; fi
  fi
  echo "$qty $price"
}

# --- mainnet confirmation gate ------------------------------------------------

require_confirmation() { # $1 = notional in USD, $2 = leverage
  [ "$FUTURES_NETWORK" = "testnet" ] && return 0
  local notional="$1" lev="$2"
  local max_notional="${FUTURES_MAX_NOTIONAL:-1000}"
  local max_lev="${FUTURES_MAX_LEVERAGE:-5}"
  if [ "${FUTURES_CONFIRM:-}" != "yes" ]; then
    die "CONFIRMATION_REQUIRED" "Mainnet requires FUTURES_CONFIRM=yes" "export FUTURES_CONFIRM=yes"
  fi
  if [ "${ARG_CONFIRM:-0}" != "1" ]; then
    die "CONFIRMATION_REQUIRED" "Mainnet requires --confirm flag" "Add --confirm to the command"
  fi
  python3 -c "import sys,decimal;sys.exit(0 if decimal.Decimal(sys.argv[1])<=decimal.Decimal(sys.argv[2]) else 1)" \
    "$notional" "$max_notional" \
    || die "CONFIRMATION_REQUIRED" "notional $notional > FUTURES_MAX_NOTIONAL $max_notional" \
           "Lower qty or raise FUTURES_MAX_NOTIONAL"
  [ "$lev" -le "$max_lev" ] \
    || die "CONFIRMATION_REQUIRED" "leverage $lev > FUTURES_MAX_LEVERAGE $max_lev" \
           "Lower leverage or raise FUTURES_MAX_LEVERAGE"
}

# --- idempotency --------------------------------------------------------------

gen_client_order_id() {
  echo "ai-$(date +%s%3N)-$RANDOM"
}
