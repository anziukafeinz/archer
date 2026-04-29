# shellcheck shell=bash
# market.sh — public market-data subcommands.
set -euo pipefail

market_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="market $sub"
  case "$sub" in
    exchange-info)
      local symbol=""
      while [ $# -gt 0 ]; do case "$1" in
        --symbol) symbol="$2"; shift 2;;
        *) shift;; esac; done
      load_exchange_info
      if [ -n "$symbol" ]; then
        jq -c --arg s "$symbol" '.symbols[]|select(.symbol==$s)' "$EX_CACHE" \
          | { read -r d; ok_json "$CMD" "$d"; }
      else
        jq -c '{symbols:[.symbols[]|{symbol,status,contractType,baseAsset,quoteAsset}]}' "$EX_CACHE" \
          | { read -r d; ok_json "$CMD" "$d"; }
      fi ;;
    ticker)
      local q=""; while [ $# -gt 0 ]; do case "$1" in --symbol) q="symbol=$2"; shift 2;; *) shift;; esac; done
      ok_json "$CMD" "$(public_get /fapi/v1/ticker/24hr "$q")" ;;
    depth)
      local sym="" lim=100
      while [ $# -gt 0 ]; do case "$1" in
        --symbol) sym="$2"; shift 2;; --limit) lim="$2"; shift 2;; *) shift;; esac; done
      [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" "futures-cli market depth --symbol BTCUSDT"
      ok_json "$CMD" "$(public_get /fapi/v1/depth "symbol=$sym&limit=$lim")" ;;
    klines)
      local sym="" iv="" lim=500
      while [ $# -gt 0 ]; do case "$1" in
        --symbol) sym="$2"; shift 2;;
        --interval) iv="$2"; shift 2;;
        --limit) lim="$2"; shift 2;;
        *) shift;; esac; done
      [ -z "$sym" ] || [ -z "$iv" ] \
        && die "BAD_ARGS" "--symbol and --interval required" \
               "futures-cli market klines --symbol BTCUSDT --interval 1h"
      local raw; raw=$(public_get /fapi/v1/klines "symbol=$sym&interval=$iv&limit=$lim")
      ok_json "$CMD" "$raw" ;;
    mark-price)
      local q=""; while [ $# -gt 0 ]; do case "$1" in --symbol) q="symbol=$2"; shift 2;; *) shift;; esac; done
      ok_json "$CMD" "$(public_get /fapi/v1/premiumIndex "$q")" ;;
    funding-history)
      local q=""; while [ $# -gt 0 ]; do case "$1" in
        --symbol) q="${q:+$q&}symbol=$2"; shift 2;;
        --limit)  q="${q:+$q&}limit=$2";  shift 2;;
        *) shift;; esac; done
      ok_json "$CMD" "$(public_get /fapi/v1/fundingRate "$q")" ;;
    open-interest)
      local sym=""; while [ $# -gt 0 ]; do case "$1" in --symbol) sym="$2"; shift 2;; *) shift;; esac; done
      [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
      ok_json "$CMD" "$(public_get /fapi/v1/openInterest "symbol=$sym")" ;;
    liquidations)
      # auth required for forceOrders; expose under market for symmetry
      local q=""; while [ $# -gt 0 ]; do case "$1" in
        --symbol) q="${q:+$q&}symbol=$2"; shift 2;;
        --limit)  q="${q:+$q&}limit=$2";  shift 2;;
        *) shift;; esac; done
      signed_req GET /fapi/v1/forceOrders "$q" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    *) die "UNKNOWN_CMD" "market $sub" "futures-cli market --help" ;;
  esac
}
