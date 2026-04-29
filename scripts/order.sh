# shellcheck shell=bash
# order.sh — order placement, cancellation, and queries.
set -euo pipefail

order_dispatch() {
  local sub="${1:-}"; shift || true
  CMD="order $sub"
  case "$sub" in
    place)         _order_place "$@" ;;
    cancel)        _order_cancel "$@" ;;
    cancel-all)    _order_cancel_all "$@" ;;
    query)         _order_query "$@" ;;
    open)          _order_open "$@" ;;
    history)       _order_history "$@" ;;
    trades)        _order_trades "$@" ;;
    bracket)       _order_bracket "$@" ;;
    place-batch)   die "NOT_IMPLEMENTED" "place-batch in v0.1.0" "Loop place for now" ;;
    cancel-batch)  die "NOT_IMPLEMENTED" "cancel-batch in v0.1.0" "Loop cancel for now" ;;
    *) die "UNKNOWN_CMD" "order $sub" "futures-cli order --help" ;;
  esac
}

_order_place() {
  local sym="" side="" type="" qty="" price="0" tif="" sl="" tp="" cb="" pside="BOTH"
  local reduce_only="" close_position="" working="" price_protect=""
  local coid=""; local dry_run=0; ARG_CONFIRM=0
  local max_slip="${FUTURES_MAX_SLIPPAGE:-0.005}"
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)         sym="$2"; shift 2;;
    --side)           side="$2"; shift 2;;
    --type)           type="$2"; shift 2;;
    --quantity)       qty="$2"; shift 2;;
    --price)          price="$2"; shift 2;;
    --time-in-force)  tif="$2"; shift 2;;
    --stop-price)     sl="$2"; shift 2;;
    --activation-price) tp="$2"; shift 2;;
    --callback-rate)  cb="$2"; shift 2;;
    --position-side)  pside="$2"; shift 2;;
    --reduce-only)    reduce_only="true"; shift;;
    --close-position) close_position="true"; shift;;
    --working-type)   working="$2"; shift 2;;
    --price-protect)  price_protect="true"; shift;;
    --client-order-id) coid="$2"; shift 2;;
    --max-slippage)   max_slip="$2"; shift 2;;
    --dry-run)        dry_run=1; shift;;
    --confirm)        ARG_CONFIRM=1; shift;;
    --mainnet|--testnet) shift;;   # already resolved at startup
    *) shift;;
  esac; done
  [ -z "$sym" ] || [ -z "$side" ] || [ -z "$type" ] || [ -z "$qty" ] \
    && die "BAD_ARGS" "--symbol --side --type --quantity required" ""

  # Validate / round qty + price against exchange filters.
  read -r qty price <<< "$(validate_order "$sym" "$qty" "$price")"

  # Estimate notional for confirmation gate. For MARKET we use mark price.
  local ref_price="$price"
  if [ "$ref_price" = "0" ]; then
    ref_price=$(public_get /fapi/v1/premiumIndex "symbol=$sym" | jq -r .markPrice)
  fi
  local notional; notional=$(python3 -c "import sys,decimal;print(decimal.Decimal(sys.argv[1])*decimal.Decimal(sys.argv[2]))" "$qty" "$ref_price")

  # Pull current leverage for the gate (best-effort; may be 0 if no position yet).
  local lev=1
  lev=$(signed_req GET /fapi/v3/positionRisk "symbol=$sym" 2>/dev/null \
        | jq -r --arg s "$sym" '[.[]|select(.symbol==$s)|.leverage|tonumber][0] // 1' || echo 1)
  require_confirmation "$notional" "$lev"

  [ -z "$coid" ] && coid=$(gen_client_order_id)

  # Build query
  local q="symbol=$sym&side=$side&type=$type&quantity=$qty&newClientOrderId=$coid"
  [ "$type" = "LIMIT" ] && q="$q&timeInForce=${tif:-GTC}&price=$price"
  [ -n "$sl" ]              && q="$q&stopPrice=$sl"
  [ -n "$cb" ]              && q="$q&callbackRate=$cb"
  [ "$pside" != "BOTH" ]    && q="$q&positionSide=$pside"
  [ -n "$reduce_only" ]     && q="$q&reduceOnly=true"
  [ -n "$close_position" ]  && q="$q&closePosition=true"
  [ -n "$working" ]         && q="$q&workingType=$working"
  [ -n "$price_protect" ]   && q="$q&priceProtect=true"

  if [ "$dry_run" -eq 1 ]; then
    jq -nc --arg c "$CMD" --arg q "$q" --arg coid "$coid" \
          --arg n "$notional" --arg l "$lev" \
          '{ok:true,command:$c,data:{would_send:$q,clientOrderId:$coid,
            estimated_notional:$n,leverage:$l},dry_run:true}'
    return 0
  fi
  signed_req POST /fapi/v1/order "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_cancel() {
  local sym="" oid="" coid=""
  while [ $# -gt 0 ]; do case "$1" in
    --symbol) sym="$2"; shift 2;;
    --order-id) oid="$2"; shift 2;;
    --client-order-id) coid="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
  local q="symbol=$sym"
  [ -n "$oid" ]  && q="$q&orderId=$oid"
  [ -n "$coid" ] && q="$q&origClientOrderId=$coid"
  signed_req DELETE /fapi/v1/order "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_cancel_all() {
  local sym=""; while [ $# -gt 0 ]; do case "$1" in --symbol) sym="$2"; shift 2;; *) shift;; esac; done
  [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
  signed_req DELETE /fapi/v1/allOpenOrders "symbol=$sym" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_query() {
  local sym="" oid="" coid=""
  while [ $# -gt 0 ]; do case "$1" in
    --symbol) sym="$2"; shift 2;;
    --order-id) oid="$2"; shift 2;;
    --client-order-id) coid="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
  local q="symbol=$sym"
  [ -n "$oid" ]  && q="$q&orderId=$oid"
  [ -n "$coid" ] && q="$q&origClientOrderId=$coid"
  signed_req GET /fapi/v1/order "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_open() {
  local q=""; while [ $# -gt 0 ]; do case "$1" in --symbol) q="symbol=$2"; shift 2;; *) shift;; esac; done
  signed_req GET /fapi/v1/openOrders "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_history() {
  local q=""; while [ $# -gt 0 ]; do case "$1" in
    --symbol) q="${q:+$q&}symbol=$2"; shift 2;;
    --limit)  q="${q:+$q&}limit=$2";  shift 2;;
    *) shift;; esac; done
  signed_req GET /fapi/v1/allOrders "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_trades() {
  local q=""; while [ $# -gt 0 ]; do case "$1" in
    --symbol) q="${q:+$q&}symbol=$2"; shift 2;;
    --limit)  q="${q:+$q&}limit=$2";  shift 2;;
    *) shift;; esac; done
  signed_req GET /fapi/v1/userTrades "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

# Synthetic bracket: entry + STOP_MARKET (SL, closePosition) + TAKE_PROFIT_MARKET (TP, closePosition).
# Sends SL/TP immediately with reduceOnly so they survive the entry fill.
_order_bracket() {
  local sym="" side="" qty="" etype="LIMIT" eprice="" sl="" tp=""
  while [ $# -gt 0 ]; do case "$1" in
    --symbol) sym="$2"; shift 2;;
    --side) side="$2"; shift 2;;
    --quantity) qty="$2"; shift 2;;
    --entry-type) etype="$2"; shift 2;;
    --entry-price) eprice="$2"; shift 2;;
    --stop-loss) sl="$2"; shift 2;;
    --take-profit) tp="$2"; shift 2;;
    *) shift;; esac; done
  [ -z "$sym" ] || [ -z "$side" ] || [ -z "$qty" ] || [ -z "$sl" ] || [ -z "$tp" ] \
    && die "BAD_ARGS" "--symbol --side --quantity --stop-loss --take-profit required" ""
  local exit_side; [ "$side" = "BUY" ] && exit_side="SELL" || exit_side="BUY"

  local entry_args=(--symbol "$sym" --side "$side" --type "$etype" --quantity "$qty")
  [ "$etype" = "LIMIT" ] && entry_args+=(--price "$eprice" --time-in-force GTC)

  local entry sl_o tp_o
  entry=$(_order_place "${entry_args[@]}" "$@")
  sl_o=$(_order_place --symbol "$sym" --side "$exit_side" --type STOP_MARKET \
        --quantity "$qty" --stop-price "$sl" --close-position --working-type MARK_PRICE "$@")
  tp_o=$(_order_place --symbol "$sym" --side "$exit_side" --type TAKE_PROFIT_MARKET \
        --quantity "$qty" --stop-price "$tp" --close-position --working-type MARK_PRICE "$@")

  jq -nc --argjson e "$entry" --argjson s "$sl_o" --argjson t "$tp_o" \
        '{ok:true,command:"order bracket",data:{entry:$e,stop_loss:$s,take_profit:$t}}'
}
