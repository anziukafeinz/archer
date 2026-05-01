# shellcheck shell=bash
# account.sh — account & position subcommands (auth required).
set -euo pipefail

account_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="account $sub"
  case "$sub" in
    info)        signed_req GET /fapi/v3/account ""    | normalize_error | { read -r d; ok_json "$CMD" "$d"; } ;;
    balance)     signed_req GET /fapi/v3/balance ""    | normalize_error | { read -r d; ok_json "$CMD" "$d"; } ;;
    config)      signed_req GET /fapi/v1/accountConfig "" | normalize_error | { read -r d; ok_json "$CMD" "$d"; } ;;
    commission)
      local sym=""; while [ $# -gt 0 ]; do case "$1" in --symbol) sym="$2"; shift 2;; *) shift;; esac; done
      [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
      signed_req GET /fapi/v1/commissionRate "symbol=$sym" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    income)
      local q=""; while [ $# -gt 0 ]; do case "$1" in
        --symbol)      q="${q:+$q&}symbol=$2"; shift 2;;
        --income-type) q="${q:+$q&}incomeType=$2"; shift 2;;
        --start)       q="${q:+$q&}startTime=$2"; shift 2;;
        --end)         q="${q:+$q&}endTime=$2"; shift 2;;
        --limit)       q="${q:+$q&}limit=$2"; shift 2;;
        *) shift;; esac; done
      signed_req GET /fapi/v1/income "$q" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    *) die "UNKNOWN_CMD" "account $sub" "futures-cli account --help" ;;
  esac
}

position_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="position $sub"
  case "$sub" in
    list)              _position_list "$@" ;;
    set-leverage)      _position_set_leverage "$@" ;;
    set-margin-type)   _position_set_margin_type "$@" ;;
    set-position-mode) _position_set_position_mode "$@" ;;
    get-position-mode) _position_get_position_mode "$@" ;;
    adjust-margin)     _position_adjust_margin "$@" ;;
    *) die "UNKNOWN_CMD" "position $sub" "futures-cli position --help" ;;
  esac
}

_position_list() {
  local q=""
  while [ $# -gt 0 ]; do case "$1" in
    --symbol) q="symbol=$2"; shift 2;;
    *) shift;; esac; done
  signed_req GET /fapi/v3/positionRisk "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

# ---- set-leverage ----------------------------------------------------------
_position_set_leverage() {
  local sym="" lev="" dry_run=0
  # ARG_CONFIRM is read by require_confirmation in _common.sh.
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)   sym="$2"; shift 2;;
    --leverage) lev="$2"; shift 2;;
    --dry-run)  dry_run=1; shift;;
    --confirm)  ARG_CONFIRM=1; shift;;
    --mainnet|--testnet) shift;;
    *) shift;; esac; done
  if [ -z "$sym" ] || [ -z "$lev" ]; then
    die "BAD_ARGS" "--symbol and --leverage required" \
        "Usage: futures-cli position set-leverage --symbol BTCUSDT --leverage 5"
  fi
  # Binance hard cap is 1..125; reject anything outside before signing.
  if ! python3 -c "
import sys
v = sys.argv[1]
try:
    n = int(v)
except ValueError:
    sys.exit(2)
sys.exit(0 if 1 <= n <= 125 else 1)" "$lev"; then
    die "BAD_ARGS" "--leverage $lev out of range" \
        "Binance accepts integer 1..125 (per-symbol; tier ladder enforced server-side)"
  fi

  # Mainnet gate: notional 0 (this is not an order), but FUTURES_MAX_LEVERAGE
  # is still enforced via require_confirmation. --confirm + FUTURES_CONFIRM=yes
  # are required because a leverage hike can affect already-open positions.
  require_confirmation "0" "$lev"

  local q="symbol=$sym&leverage=$lev"
  if [ "$dry_run" -eq 1 ]; then
    ok_json "$CMD" "$(jq -nc --arg q "$q" --arg s "$sym" \
                            --argjson l "$lev" \
       '{would_send:$q, symbol:$s, leverage:$l, dry_run:true}')"
    return 0
  fi
  signed_req POST /fapi/v1/leverage "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

# ---- set-margin-type -------------------------------------------------------
_position_set_margin_type() {
  local sym="" mt="" dry_run=0
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)      sym="$2"; shift 2;;
    --margin-type) mt="$2";  shift 2;;
    --dry-run)     dry_run=1; shift;;
    --confirm)     ARG_CONFIRM=1; shift;;
    --mainnet|--testnet) shift;;
    *) shift;; esac; done
  if [ -z "$sym" ] || [ -z "$mt" ]; then
    die "BAD_ARGS" "--symbol and --margin-type required" \
        "Usage: futures-cli position set-margin-type --symbol BTCUSDT --margin-type ISOLATED"
  fi
  # Normalise to uppercase so callers can pass either form.
  mt=$(printf '%s' "$mt" | tr '[:lower:]' '[:upper:]')
  case "$mt" in
    ISOLATED|CROSSED) ;;
    *) die "BAD_ARGS" "invalid --margin-type $mt" \
           "Accepted: ISOLATED, CROSSED" ;;
  esac

  require_confirmation "0" "1"

  local q="symbol=$sym&marginType=$mt"
  if [ "$dry_run" -eq 1 ]; then
    ok_json "$CMD" "$(jq -nc --arg q "$q" --arg s "$sym" --arg m "$mt" \
       '{would_send:$q, symbol:$s, marginType:$m, dry_run:true}')"
    return 0
  fi
  signed_req POST /fapi/v1/marginType "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

# ---- set-position-mode -----------------------------------------------------
# CLI surface accepts a friendly --mode hedge|one-way (mapped to Binance's
# dualSidePosition true|false). The legacy --dual true|false is still
# accepted for backward compatibility with the v0.1.0 draft.
_position_set_position_mode() {
  local mode="" dual="" dry_run=0
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  while [ $# -gt 0 ]; do case "$1" in
    --mode)    mode="$2"; shift 2;;
    --dual)    dual="$2"; shift 2;;
    --dry-run) dry_run=1; shift;;
    --confirm) ARG_CONFIRM=1; shift;;
    --mainnet|--testnet) shift;;
    *) shift;; esac; done

  if [ -n "$mode" ]; then
    case "$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')" in
      hedge)        dual="true" ;;
      one-way|oneway|onew) dual="false" ;;
      *) die "BAD_ARGS" "invalid --mode $mode" \
             "Accepted: hedge, one-way" ;;
    esac
  fi
  if [ -z "$dual" ]; then
    die "BAD_ARGS" "--mode hedge|one-way required" \
        "Or pass legacy --dual true|false"
  fi
  case "$dual" in
    true|false) ;;
    *) die "BAD_ARGS" "--dual must be true or false" "Got: $dual" ;;
  esac

  require_confirmation "0" "1"

  local q="dualSidePosition=$dual"
  if [ "$dry_run" -eq 1 ]; then
    local human="one-way"; [ "$dual" = "true" ] && human="hedge"
    ok_json "$CMD" "$(jq -nc --arg q "$q" --arg d "$dual" --arg m "$human" \
       '{would_send:$q, mode:$m, dualSidePosition:$d, dry_run:true}')"
    return 0
  fi
  signed_req POST /fapi/v1/positionSide/dual "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

# ---- get-position-mode (read-only convenience) -----------------------------
_position_get_position_mode() {
  local raw mode dual
  raw=$(signed_req GET /fapi/v1/positionSide/dual "")
  # Surface venue errors via normalize_error.
  if echo "$raw" | jq -e '.code // empty' >/dev/null 2>&1; then
    echo "$raw" | normalize_error
    return 1
  fi
  dual=$(echo "$raw" | jq -r '.dualSidePosition')
  mode="one-way"; [ "$dual" = "true" ] && mode="hedge"
  ok_json "$CMD" "$(jq -nc --arg m "$mode" --argjson d "$dual" \
     '{mode:$m, dualSidePosition:$d}')"
}

# ---- adjust-margin (per-position margin add/reduce; ISOLATED only) ---------
_position_adjust_margin() {
  local sym="" amt="" mtype="" pside="BOTH" dry_run=0
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)        sym="$2"; shift 2;;
    --amount)        amt="$2"; shift 2;;
    --type)          mtype="$2"; shift 2;;   # 1=add, 2=reduce
    --position-side) pside="$2"; shift 2;;
    --dry-run)       dry_run=1; shift;;
    --confirm)       ARG_CONFIRM=1; shift;;
    --mainnet|--testnet) shift;;
    *) shift;; esac; done
  if [ -z "$sym" ] || [ -z "$amt" ] || [ -z "$mtype" ]; then
    die "BAD_ARGS" "--symbol, --amount, --type (1=add 2=reduce) required" \
        "Only valid on ISOLATED-margin positions"
  fi
  case "$mtype" in
    1|2) ;;
    *) die "BAD_ARGS" "--type must be 1 (add) or 2 (reduce)" "Got: $mtype" ;;
  esac
  if ! python3 -c "import sys,decimal as d;sys.exit(0 if d.Decimal(sys.argv[1])>0 else 1)" "$amt"; then
    die "BAD_ARGS" "--amount must be positive" "Got: $amt"
  fi

  # Treat the margin amount as the notional under risk for the gate. This is
  # not perfect (margin != notional), but it's a useful upper bound to prevent
  # accidentally pumping six figures of collateral into a stuck position.
  require_confirmation "$amt" "1"

  local q="symbol=$sym&amount=$amt&type=$mtype&positionSide=$pside"
  if [ "$dry_run" -eq 1 ]; then
    local human="add"; [ "$mtype" = "2" ] && human="reduce"
    ok_json "$CMD" "$(jq -nc --arg q "$q" --arg s "$sym" --arg a "$amt" \
                            --arg act "$human" --arg ps "$pside" \
       '{would_send:$q, symbol:$s, amount:$a, action:$act,
         positionSide:$ps, dry_run:true}')"
    return 0
  fi
  signed_req POST /fapi/v1/positionMargin "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}
