# shellcheck shell=bash
# calc.sh — offline calculators, scanners, and TA helpers.
# These never need an API key, but `scan funding` does call public market data.
set -euo pipefail

calc_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="calc $sub"
  case "$sub" in
    size)
      local equity="" risk="" entry="" stop=""
      while [ $# -gt 0 ]; do case "$1" in
        --equity) equity="$2"; shift 2;;
        --risk-pct) risk="$2"; shift 2;;
        --entry) entry="$2"; shift 2;;
        --stop) stop="$2"; shift 2;;
        *) shift;; esac; done
      python3 - "$equity" "$risk" "$entry" "$stop" <<'PY' | { read -r d; ok_json "$CMD" "$d"; }
import sys, json
from decimal import Decimal as D
eq, rk, en, st = (D(x) for x in sys.argv[1:5])
risk_usd = eq * rk / D(100)
per_unit = abs(en - st)
qty = (risk_usd / per_unit) if per_unit > 0 else D(0)
print(json.dumps({
    "equity_usd": str(eq), "risk_pct": str(rk), "risk_usd": str(risk_usd),
    "entry": str(en), "stop": str(st), "per_unit_loss": str(per_unit),
    "suggested_quantity": str(qty)
}))
PY
      ;;
    liq)
      local entry="" qty="" lev="" mmr="0.004" side="LONG"
      while [ $# -gt 0 ]; do case "$1" in
        --entry) entry="$2"; shift 2;;
        --quantity) qty="$2"; shift 2;;
        --leverage) lev="$2"; shift 2;;
        --side) side="$2"; shift 2;;
        --mmr) mmr="$2"; shift 2;;
        *) shift;; esac; done
      python3 - "$entry" "$qty" "$lev" "$side" "$mmr" <<'PY' | { read -r d; ok_json "$CMD" "$d"; }
import sys, json
from decimal import Decimal as D
en, qty, lev, side, mmr = sys.argv[1:6]
en, qty, lev, mmr = D(en), D(qty), D(lev), D(mmr)
# Simplified isolated-margin liq estimate.
if side.upper() == "LONG":
    liq = en * (D(1) - D(1)/lev + mmr)
else:
    liq = en * (D(1) + D(1)/lev - mmr)
print(json.dumps({"entry": str(en), "side": side.upper(),
                  "leverage": str(lev), "estimated_liq_price": str(liq),
                  "note": "Isolated margin approximation; ignores fees & funding."}))
PY
      ;;
    pnl)
      local entry="" exit="" qty="" side="LONG"
      while [ $# -gt 0 ]; do case "$1" in
        --entry) entry="$2"; shift 2;;
        --exit)  exit="$2";  shift 2;;
        --quantity) qty="$2"; shift 2;;
        --side) side="$2"; shift 2;;
        *) shift;; esac; done
      python3 - "$entry" "$exit" "$qty" "$side" <<'PY' | { read -r d; ok_json "$CMD" "$d"; }
import sys, json
from decimal import Decimal as D
en, ex, qty, side = sys.argv[1:5]
en, ex, qty = D(en), D(ex), D(qty)
pnl = (ex - en) * qty if side.upper() == "LONG" else (en - ex) * qty
print(json.dumps({"side": side.upper(), "entry": str(en), "exit": str(ex),
                  "quantity": str(qty), "pnl_quote": str(pnl)}))
PY
      ;;
    *) die "UNKNOWN_CMD" "calc $sub" "futures-cli calc --help" ;;
  esac
}

scan_dispatch() {
  local sub="${1:-funding}"; shift || true
  CMD="scan $sub"
  case "$sub" in
    funding)
      local top=10
      while [ $# -gt 0 ]; do case "$1" in --top) top="$2"; shift 2;; *) shift;; esac; done
      local raw; raw=$(public_get /fapi/v1/premiumIndex "")
      echo "$raw" | jq -c --argjson n "$top" \
        '[.[] | {symbol, markPrice, lastFundingRate, nextFundingTime}] |
         sort_by(.lastFundingRate|tonumber) as $asc |
         {top_negative: $asc[0:$n], top_positive: ($asc | reverse)[0:$n]}' \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    *) die "UNKNOWN_CMD" "scan $sub" "" ;;
  esac
}

ta_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="ta $sub"
  local sym="" iv="1h" len="" period=14
  while [ $# -gt 0 ]; do case "$1" in
    --symbol) sym="$2"; shift 2;;
    --interval) iv="$2"; shift 2;;
    --length) len="$2"; shift 2;;
    --period) period="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
  local raw; raw=$(public_get /fapi/v1/klines "symbol=$sym&interval=$iv&limit=500")
  python3 - "$sub" "${len:-$period}" <<PY <<<"$raw" | { read -r d; ok_json "$CMD" "$d"; }
import sys, json
fn, n = sys.argv[1], int(sys.argv[2])
data = json.load(sys.stdin)
closes = [float(c[4]) for c in data]
def sma(xs, n): return sum(xs[-n:])/n if len(xs) >= n else None
def ema(xs, n):
    if len(xs) < n: return None
    k = 2/(n+1); e = sum(xs[:n])/n
    for x in xs[n:]: e = x*k + e*(1-k)
    return e
def rsi(xs, n):
    if len(xs) <= n: return None
    gains=losses=0
    for i in range(1,n+1):
        d = xs[i]-xs[i-1]
        gains += max(d,0); losses += max(-d,0)
    ag, al = gains/n, losses/n
    for i in range(n+1, len(xs)):
        d = xs[i]-xs[i-1]
        ag = (ag*(n-1)+max(d,0))/n
        al = (al*(n-1)+max(-d,0))/n
    if al == 0: return 100.0
    rs = ag/al
    return 100 - 100/(1+rs)
out = {"symbol": "$sym", "interval": "$iv", "length": n, "last_close": closes[-1]}
if fn == "sma":     out["sma"] = sma(closes, n)
elif fn == "ema":   out["ema"] = ema(closes, n)
elif fn == "rsi":   out["rsi"] = rsi(closes, n)
elif fn == "atr":
    highs=[float(c[2]) for c in data]; lows=[float(c[3]) for c in data]
    trs=[max(highs[i]-lows[i], abs(highs[i]-closes[i-1]), abs(lows[i]-closes[i-1])) for i in range(1,len(data))]
    out["atr"] = sum(trs[-n:])/n if len(trs)>=n else None
elif fn == "bbands":
    import statistics as s
    if len(closes) >= n:
        m=sum(closes[-n:])/n; sd=s.pstdev(closes[-n:])
        out["bbands"]={"middle":m,"upper":m+2*sd,"lower":m-2*sd}
print(json.dumps(out))
PY
}
