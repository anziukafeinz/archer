# shellcheck shell=bash
# calc.sh — offline calculators (`calc`), public-data scanners (`scan`),
# and technical-analysis helpers (`ta`).
#
# `calc` subcommands are pure compute and never call the venue.
# `scan funding` and the `ta` family call public market endpoints (no auth).
set -euo pipefail

# --------------------------------------------------------------------------
# calc — risk sizing, liquidation estimate, what-if PnL, futures basis
# --------------------------------------------------------------------------
calc_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="calc $sub"
  case "$sub" in
    size)  _calc_size  "$@" ;;
    liq)   _calc_liq   "$@" ;;
    pnl)   _calc_pnl   "$@" ;;
    basis) _calc_basis "$@" ;;
    *) die "UNKNOWN_CMD" "calc $sub" "futures-cli calc --help" ;;
  esac
}

_calc_size() {
  local equity="" risk="" entry="" stop=""
  while [ $# -gt 0 ]; do case "$1" in
    --equity)   equity="$2"; shift 2;;
    --risk-pct) risk="$2"; shift 2;;
    --entry)    entry="$2"; shift 2;;
    --stop)     stop="$2"; shift 2;;
    *) shift;; esac; done
  if [ -z "$equity" ] || [ -z "$risk" ] || [ -z "$entry" ] || [ -z "$stop" ]; then
    die "BAD_ARGS" "--equity, --risk-pct, --entry, --stop required" \
        "Example: calc size --equity 1000 --risk-pct 1 --entry 60000 --stop 59000"
  fi
  local d
  d=$(python3 - "$equity" "$risk" "$entry" "$stop" <<'PY'
import sys, json
from decimal import Decimal as D, InvalidOperation
try:
    eq, rk, en, st = (D(x) for x in sys.argv[1:5])
except InvalidOperation as e:
    print(json.dumps({"_err": f"non-numeric argument: {e}"})); sys.exit(0)
if eq <= 0:
    print(json.dumps({"_err": "equity must be positive"})); sys.exit(0)
if rk <= 0 or rk > 100:
    print(json.dumps({"_err": "risk-pct must be in (0, 100]"})); sys.exit(0)
if en == st:
    print(json.dumps({"_err": "entry and stop must differ"})); sys.exit(0)
risk_usd = eq * rk / D(100)
per_unit = abs(en - st)
qty      = risk_usd / per_unit
print(json.dumps({
    "equity_usd":         str(eq),
    "risk_pct":           str(rk),
    "risk_usd":           str(risk_usd),
    "entry":              str(en),
    "stop":               str(st),
    "per_unit_loss":      str(per_unit),
    "suggested_quantity": str(qty),
}))
PY
)
  local err
  err=$(echo "$d" | jq -r '._err // empty')
  [ -n "$err" ] && die "BAD_ARGS" "$err" \
      "Example: calc size --equity 1000 --risk-pct 1 --entry 60000 --stop 59000"
  ok_json "$CMD" "$d"
}

_calc_liq() {
  local entry="" qty="" lev="" mmr="0.004" side="LONG"
  while [ $# -gt 0 ]; do case "$1" in
    --entry)    entry="$2"; shift 2;;
    --quantity) qty="$2";   shift 2;;
    --leverage) lev="$2";   shift 2;;
    --side)     side="$2";  shift 2;;
    --mmr)      mmr="$2";   shift 2;;
    *) shift;; esac; done
  if [ -z "$entry" ] || [ -z "$qty" ] || [ -z "$lev" ]; then
    die "BAD_ARGS" "--entry, --quantity, --leverage required" \
        "Example: calc liq --entry 60000 --quantity 0.01 --leverage 5 --side LONG"
  fi
  case "$(printf '%s' "$side" | tr '[:lower:]' '[:upper:]')" in
    LONG|SHORT) ;;
    *) die "BAD_ARGS" "--side must be LONG or SHORT" "Got: $side" ;;
  esac
  local d
  d=$(python3 - "$entry" "$qty" "$lev" "$side" "$mmr" <<'PY'
import sys, json
from decimal import Decimal as D, InvalidOperation
try:
    en, qty, lev, mmr = (D(sys.argv[i]) for i in (1,2,3,5))
except InvalidOperation as e:
    print(json.dumps({"_err": f"non-numeric argument: {e}"})); sys.exit(0)
side = sys.argv[4].upper()
if lev <= 0:
    print(json.dumps({"_err": "leverage must be positive"})); sys.exit(0)
# Isolated-margin approximation: liq is where balance is wiped out by adverse
# move. Ignores fees, funding payments, and tier-based maintMargin steps.
if side == "LONG":
    liq = en * (D(1) - D(1)/lev + mmr)
else:
    liq = en * (D(1) + D(1)/lev - mmr)
print(json.dumps({
    "entry":               str(en),
    "side":                side,
    "leverage":            str(lev),
    "quantity":            str(qty),
    "maint_margin_rate":   str(mmr),
    "estimated_liq_price": str(liq),
    "note": "Isolated-margin approximation; ignores fees, funding, and tiered MMR steps.",
}))
PY
)
  local err
  err=$(echo "$d" | jq -r '._err // empty')
  [ -n "$err" ] && die "BAD_ARGS" "$err" ""
  ok_json "$CMD" "$d"
}

_calc_pnl() {
  local entry="" exit_p="" qty="" side="LONG" lev=""
  while [ $# -gt 0 ]; do case "$1" in
    --entry)    entry="$2";  shift 2;;
    --exit)     exit_p="$2"; shift 2;;
    --quantity) qty="$2";    shift 2;;
    --side)     side="$2";   shift 2;;
    --leverage) lev="$2";    shift 2;;
    *) shift;; esac; done
  if [ -z "$entry" ] || [ -z "$exit_p" ] || [ -z "$qty" ]; then
    die "BAD_ARGS" "--entry, --exit, --quantity required" \
        "Optional: --side LONG|SHORT (default LONG), --leverage <n> for ROI%"
  fi
  case "$(printf '%s' "$side" | tr '[:lower:]' '[:upper:]')" in
    LONG|SHORT) ;;
    *) die "BAD_ARGS" "--side must be LONG or SHORT" "Got: $side" ;;
  esac
  local d
  d=$(python3 - "$entry" "$exit_p" "$qty" "$side" "${lev:-0}" <<'PY'
import sys, json
from decimal import Decimal as D, InvalidOperation
try:
    en, ex, qty, lev = (D(sys.argv[i]) for i in (1,2,3,5))
except InvalidOperation as e:
    print(json.dumps({"_err": f"non-numeric argument: {e}"})); sys.exit(0)
side = sys.argv[4].upper()
move = (ex - en) if side == "LONG" else (en - ex)
pnl_quote = move * qty
notional  = en * qty
out = {
    "side":         side,
    "entry":        str(en),
    "exit":         str(ex),
    "quantity":     str(qty),
    "notional":     str(notional),
    "pnl_quote":    str(pnl_quote),
    "pnl_pct":      str(move / en * D(100)) if en > 0 else "0",
}
if lev > 0:
    # ROI on margin = pnl_quote / (notional / leverage)
    margin = notional / lev
    out["leverage"]      = str(lev)
    out["margin_used"]   = str(margin)
    out["roi_on_margin"] = str(pnl_quote / margin * D(100)) if margin > 0 else "0"
print(json.dumps(out))
PY
)
  local err
  err=$(echo "$d" | jq -r '._err // empty')
  [ -n "$err" ] && die "BAD_ARGS" "$err" ""
  ok_json "$CMD" "$d"
}

# `calc basis` — futures premium relative to mark price, annualized using
# the next-funding interval. Pure compute given user-supplied numbers, OR
# fetched from /fapi/v1/premiumIndex if `--symbol` is given.
_calc_basis() {
  local sym="" futures="" spot="" hours="8"
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)        sym="$2";     shift 2;;
    --futures-price) futures="$2"; shift 2;;
    --spot-price)    spot="$2";    shift 2;;
    --hours)         hours="$2";   shift 2;;  # funding interval in hours
    *) shift;; esac; done

  if [ -z "$sym" ] && { [ -z "$futures" ] || [ -z "$spot" ]; }; then
    die "BAD_ARGS" \
        "Either --symbol (live fetch) or both --futures-price and --spot-price required" \
        "Example: calc basis --symbol BTCUSDT  /  calc basis --futures-price 60100 --spot-price 60000"
  fi

  if [ -n "$sym" ]; then
    local raw; raw=$(public_get /fapi/v1/premiumIndex "symbol=$sym")
    futures=$(echo "$raw" | jq -r '.markPrice')
    spot=$(echo    "$raw" | jq -r '.indexPrice')
    if [ -z "$futures" ] || [ "$futures" = "null" ] || \
       [ -z "$spot" ]    || [ "$spot" = "null" ]; then
      die "INVALID_SYMBOL" "could not fetch premiumIndex for $sym" \
          "Verify symbol exists: futures-cli market exchange-info --symbol $sym"
    fi
  fi

  local d
  d=$(python3 - "$futures" "$spot" "$hours" "$sym" <<'PY'
import sys, json
from decimal import Decimal as D, InvalidOperation
try:
    fp, sp, h = (D(sys.argv[i]) for i in (1,2,3))
except InvalidOperation as e:
    print(json.dumps({"_err": f"non-numeric argument: {e}"})); sys.exit(0)
if sp <= 0:
    print(json.dumps({"_err": "spot price must be positive"})); sys.exit(0)
basis_pct = (fp - sp) / sp * D(100)
# Annualize: number of funding windows per year = (24/h) * 365.
windows   = (D(24) / h) * D(365) if h > 0 else D(0)
basis_apr = basis_pct * windows
print(json.dumps({
    "symbol":            sys.argv[4] or None,
    "futures_price":     str(fp),
    "spot_price":        str(sp),
    "interval_hours":    str(h),
    "basis_pct":         str(basis_pct),
    "basis_annualized_pct": str(basis_apr),
}))
PY
)
  local err
  err=$(echo "$d" | jq -r '._err // empty')
  [ -n "$err" ] && die "BAD_ARGS" "$err" ""
  ok_json "$CMD" "$d"
}

# --------------------------------------------------------------------------
# scan — public-data scanners (no auth)
# --------------------------------------------------------------------------
scan_dispatch() {
  local sub="${1:-funding}"; shift || true
  CMD="scan $sub"
  case "$sub" in
    funding) _scan_funding "$@" ;;
    *) die "UNKNOWN_CMD" "scan $sub" "futures-cli scan funding [--top N]" ;;
  esac
}

_scan_funding() {
  local top=10
  while [ $# -gt 0 ]; do case "$1" in
    --top) top="$2"; shift 2;;
    *) shift;; esac; done
  if ! [[ "$top" =~ ^[0-9]+$ ]] || [ "$top" -le 0 ]; then
    die "BAD_ARGS" "--top must be a positive integer" "Got: $top"
  fi
  local raw; raw=$(public_get /fapi/v1/premiumIndex "")
  # premiumIndex returns either an array (no symbol) or a single object.
  if ! echo "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die "BAD_RESPONSE" "premiumIndex did not return an array" \
        "Got: $(echo "$raw" | head -c 80)"
  fi
  local d
  d=$(echo "$raw" | jq -c --argjson n "$top" '
    [.[] | {symbol, markPrice, lastFundingRate, nextFundingTime}]
    | sort_by(.lastFundingRate | tonumber) as $asc
    | { top_negative: $asc[0:$n],
        top_positive: ($asc | reverse)[0:$n],
        count:        ($asc | length) }
  ')
  ok_json "$CMD" "$d"
}

# --------------------------------------------------------------------------
# ta — SMA / EMA / RSI / ATR / Bollinger Bands from /fapi/v1/klines
# --------------------------------------------------------------------------
ta_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="ta $sub"
  case "$sub" in
    sma|ema|rsi|atr|bbands) _ta_run "$sub" "$@" ;;
    *) die "UNKNOWN_CMD" "ta $sub" \
           "Supported: sma | ema | rsi | atr | bbands" ;;
  esac
}

_ta_run() {
  local fn="$1"; shift
  local sym="" iv="1h" period="" length=""
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)   sym="$2";    shift 2;;
    --interval) iv="$2";     shift 2;;
    --length)   length="$2"; shift 2;;
    --period)   period="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" \
      "Example: ta rsi --symbol BTCUSDT --interval 1h --period 14"
  local n="${length:-${period:-14}}"
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 2 ]; then
    die "BAD_ARGS" "--period / --length must be an integer >= 2" "Got: $n"
  fi

  local raw
  raw=$(public_get /fapi/v1/klines "symbol=$sym&interval=$iv&limit=500")
  if ! echo "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die "BAD_RESPONSE" "klines did not return an array" \
        "Got: $(echo "$raw" | head -c 80)"
  fi

  # Pass JSON via env var to keep it off both stdin (heredoc) and argv.
  local d
  d=$(KLINES_JSON="$raw" python3 - "$fn" "$n" "$sym" "$iv" <<'PY'
import os, sys, json, statistics
fn, n, sym, iv = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = json.loads(os.environ["KLINES_JSON"])
if not data:
    print(json.dumps({"_err": "klines returned empty array"})); sys.exit(0)
closes = [float(c[4]) for c in data]
highs  = [float(c[2]) for c in data]
lows   = [float(c[3]) for c in data]

def sma(xs, n): return sum(xs[-n:]) / n if len(xs) >= n else None
def ema(xs, n):
    if len(xs) < n: return None
    k = 2 / (n + 1)
    e = sum(xs[:n]) / n
    for x in xs[n:]:
        e = x * k + e * (1 - k)
    return e
def rsi(xs, n):
    if len(xs) <= n: return None
    g = l = 0.0
    for i in range(1, n + 1):
        d = xs[i] - xs[i-1]
        g += max(d, 0); l += max(-d, 0)
    ag, al = g / n, l / n
    for i in range(n + 1, len(xs)):
        d = xs[i] - xs[i-1]
        ag = (ag * (n - 1) + max(d, 0)) / n
        al = (al * (n - 1) + max(-d, 0)) / n
    if al == 0: return 100.0
    return 100 - 100 / (1 + ag / al)
def atr(hi, lo, cl, n):
    if len(cl) <= n: return None
    trs = [max(hi[i] - lo[i],
               abs(hi[i] - cl[i-1]),
               abs(lo[i] - cl[i-1]))
           for i in range(1, len(cl))]
    return sum(trs[-n:]) / n if len(trs) >= n else None
def bbands(xs, n, k=2.0):
    if len(xs) < n: return None
    window = xs[-n:]
    m = sum(window) / n
    sd = statistics.pstdev(window)
    return {"middle": m, "upper": m + k * sd, "lower": m - k * sd, "stddev": sd}

out = {
    "indicator":  fn,
    "symbol":     sym,
    "interval":   iv,
    "length":     n,
    "candles":    len(closes),
    "last_close": closes[-1],
}
if   fn == "sma":    out["value"] = sma(closes, n)
elif fn == "ema":    out["value"] = ema(closes, n)
elif fn == "rsi":    out["value"] = rsi(closes, n)
elif fn == "atr":    out["value"] = atr(highs, lows, closes, n)
elif fn == "bbands": out["bbands"] = bbands(closes, n)

print(json.dumps(out))
PY
)
  local err
  err=$(echo "$d" | jq -r '._err // empty')
  [ -n "$err" ] && die "BAD_RESPONSE" "$err" ""
  ok_json "$CMD" "$d"
}
