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
    place-batch)   _order_place_batch "$@" ;;
    cancel-batch)  _order_cancel_batch "$@" ;;
    *) die "UNKNOWN_CMD" "order $sub" "futures-cli order --help" ;;
  esac
}

_order_place() {
  local sym="" side="" type="" qty="" price="0" tif="" sl="" act="" cb="" pside="BOTH"
  local reduce_only="" close_position="" working="" price_protect=""
  local coid=""; local dry_run=0
  # ARG_CONFIRM is read by require_confirmation in _common.sh.
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  local max_slip="${FUTURES_MAX_SLIPPAGE:-0.005}"
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)         sym="$2"; shift 2;;
    --side)           side="$2"; shift 2;;
    --type)           type="$2"; shift 2;;
    --quantity)       qty="$2"; shift 2;;
    --price)          price="$2"; shift 2;;
    --time-in-force)  tif="$2"; shift 2;;
    --stop-price)     sl="$2"; shift 2;;
    --activation-price) act="$2"; shift 2;;
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
  if [ -z "$sym" ] || [ -z "$side" ] || [ -z "$type" ] || [ -z "$qty" ]; then
    die "BAD_ARGS" "--symbol --side --type --quantity required" ""
  fi

  # ---- per-type required-arg validation ----------------------------------
  case "$type" in
    LIMIT)
      [ "$price" = "0" ] && die "BAD_ARGS" "LIMIT requires --price" ""
      ;;
    MARKET)
      # MARKET: no price / timeInForce. Force price=0 so validate_order skips
      # the minNotional check (Binance enforces it server-side via mark).
      price="0"
      ;;
    STOP|TAKE_PROFIT)
      # Stop-limit variants: need both --price (limit) and --stop-price (trigger).
      [ -z "$sl" ]       && die "BAD_ARGS" "$type requires --stop-price" ""
      [ "$price" = "0" ] && die "BAD_ARGS" "$type requires --price" ""
      ;;
    STOP_MARKET|TAKE_PROFIT_MARKET)
      [ -z "$sl" ] && die "BAD_ARGS" "$type requires --stop-price" ""
      price="0"
      ;;
    TRAILING_STOP_MARKET)
      [ -z "$cb" ] && die "BAD_ARGS" \
        "TRAILING_STOP_MARKET requires --callback-rate" \
        "Pass percentage (0.1..5.0); e.g. --callback-rate 1.0"
      python3 -c "
import sys, decimal as d
cb = d.Decimal(sys.argv[1])
sys.exit(0 if d.Decimal('0.1') <= cb <= d.Decimal('5.0') else 1)" "$cb" \
        || die "BAD_ARGS" "callbackRate $cb out of range" \
               "Binance accepts 0.1..5.0 (% trailing offset)"
      price="0"
      ;;
    *)
      die "BAD_ARGS" "unsupported --type $type" \
          "Use one of: LIMIT MARKET STOP STOP_MARKET TAKE_PROFIT TAKE_PROFIT_MARKET TRAILING_STOP_MARKET"
      ;;
  esac

  # ---- closePosition / reduceOnly mutual constraints ---------------------
  if [ -n "$close_position" ]; then
    case "$type" in
      STOP_MARKET|TAKE_PROFIT_MARKET) ;;
      *) die "BAD_ARGS" "--close-position only valid on STOP_MARKET / TAKE_PROFIT_MARKET" \
             "Use --reduce-only on other types" ;;
    esac
    [ -n "$reduce_only" ] \
      && die "BAD_ARGS" "--reduce-only and --close-position are mutually exclusive" \
             "closePosition already implies a reducing exit"
  fi

  # ---- qty / price filter rounding ---------------------------------------
  # closePosition orders ignore quantity server-side; we still round qty to
  # stepSize but skip the minQty / minNotional gates (Binance won't enforce
  # them when closePosition=true). For all other types validate_order runs.
  if [ -n "$close_position" ]; then
    local _filt; _filt=$(symbol_filters "$sym")
    [ -z "$_filt" ] && die "INVALID_SYMBOL" "symbol $sym not found" \
      "Run: futures-cli market exchange-info"
    local _step; _step=$(echo "$_filt" | jq -r .stepSize)
    qty=$(round_down "$qty" "$_step")
  else
    read -r qty price <<<"$(validate_order "$sym" "$qty" "$price")"
  fi

  # Always round stopPrice to tickSize when present.
  if [ -n "$sl" ]; then
    local _tick; _tick=$(symbol_filters "$sym" | jq -r .tickSize)
    sl=$(round_down "$sl" "$_tick")
  fi
  if [ -n "$act" ]; then
    local _tick2; _tick2=$(symbol_filters "$sym" | jq -r .tickSize)
    act=$(round_down "$act" "$_tick2")
  fi

  # ---- slippage gate (price-bearing types only) --------------------------
  # Catches typos like a BUY LIMIT 1.5x mark or a STOP entry 50% off mark.
  # Bypassed entirely when --max-slippage 0 (effectively "off").
  if [ "$price" != "0" ]; then
    if python3 -c "import sys,decimal as d; sys.exit(0 if d.Decimal(sys.argv[1])>0 else 1)" "$max_slip"; then
      local _mark
      _mark=$(public_get /fapi/v1/premiumIndex "symbol=$sym" | jq -r .markPrice)
      if ! python3 -c "
import sys, decimal as d
p, m, s = d.Decimal(sys.argv[1]), d.Decimal(sys.argv[2]), d.Decimal(sys.argv[3])
sys.exit(0 if abs(p - m) / m <= s else 1)" "$price" "$_mark" "$max_slip"; then
        die "SLIPPAGE_EXCEEDED" \
            "limit price $price deviates from mark $_mark by more than $max_slip" \
            "Move price closer to mark or raise --max-slippage / FUTURES_MAX_SLIPPAGE"
      fi
    fi
  fi

  # ---- confirmation gate (notional × leverage) ---------------------------
  local ref_price="$price"
  if [ "$ref_price" = "0" ]; then
    ref_price=$(public_get /fapi/v1/premiumIndex "symbol=$sym" | jq -r .markPrice)
  fi
  local notional
  notional=$(python3 -c "import sys,decimal;print(decimal.Decimal(sys.argv[1])*decimal.Decimal(sys.argv[2]))" "$qty" "$ref_price")
  # closePosition orders: Binance ignores quantity, so the notional we just
  # computed is meaningless. Pass 0 to require_confirmation so it doesn't
  # trip the FUTURES_MAX_NOTIONAL ceiling on what is really an exit-only
  # request. The confirm flag + env are still required on mainnet.
  [ -n "$close_position" ] && notional="0"

  local lev=1
  lev=$(signed_req GET /fapi/v3/positionRisk "symbol=$sym" 2>/dev/null \
        | jq -r --arg s "$sym" '[.[]|select(.symbol==$s)|.leverage|tonumber][0] // 1' \
        || echo 1)
  require_confirmation "$notional" "$lev"

  [ -z "$coid" ] && coid=$(gen_client_order_id)

  # ---- build query (type-specific shape) ---------------------------------
  local q="symbol=$sym&side=$side&type=$type&newClientOrderId=$coid"
  [ -z "$close_position" ] && q="$q&quantity=$qty"
  case "$type" in
    LIMIT)
      q="$q&timeInForce=${tif:-GTC}&price=$price" ;;
    STOP|TAKE_PROFIT)
      q="$q&timeInForce=${tif:-GTC}&price=$price&stopPrice=$sl" ;;
    STOP_MARKET|TAKE_PROFIT_MARKET)
      q="$q&stopPrice=$sl" ;;
    TRAILING_STOP_MARKET)
      q="$q&callbackRate=$cb"
      [ -n "$act" ] && q="$q&activationPrice=$act" ;;
    MARKET) ;;
  esac
  [ "$pside" != "BOTH" ]    && q="$q&positionSide=$pside"
  [ -n "$reduce_only" ]     && q="$q&reduceOnly=true"
  [ -n "$close_position" ]  && q="$q&closePosition=true"
  [ -n "$working" ]         && q="$q&workingType=$working"
  [ -n "$price_protect" ]   && q="$q&priceProtect=true"

  if [ "$dry_run" -eq 1 ]; then
    ok_json "$CMD" "$(jq -nc \
      --arg q "$q" --arg coid "$coid" --arg type "$type" \
      --arg n "$notional" --arg l "$lev" --arg slip "$max_slip" \
      '{would_send:$q, clientOrderId:$coid, type:$type,
        estimated_notional:$n, leverage:$l,
        max_slippage:$slip, dry_run:true}')"
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

# Validate one order from a batch JSON object. Echoes a one-line JSON
# `{order, notional}` on stdout. Aborts via die() on validation failure.
_batch_normalize_one() { # $1 = idx, $2 = order JSON
  local idx="$1" o="$2"
  local sym side type qty price tif coid pside ro cp wt sp cb
  sym=$(jq -r '.symbol             // empty'                <<<"$o")
  side=$(jq -r '.side              // empty'                <<<"$o")
  type=$(jq -r '.type              // empty'                <<<"$o")
  qty=$(jq -r  '.quantity          // empty'                <<<"$o")
  price=$(jq -r '.price            // "0"'                  <<<"$o")
  tif=$(jq -r  '.timeInForce       // "GTC"'                <<<"$o")
  coid=$(jq -r '.newClientOrderId  // .clientOrderId // ""' <<<"$o")
  pside=$(jq -r '.positionSide     // "BOTH"'               <<<"$o")
  ro=$(jq -r   '.reduceOnly        // ""'                   <<<"$o")
  cp=$(jq -r   '.closePosition     // ""'                   <<<"$o")
  wt=$(jq -r   '.workingType       // ""'                   <<<"$o")
  sp=$(jq -r   '.stopPrice         // ""'                   <<<"$o")
  cb=$(jq -r   '.callbackRate      // ""'                   <<<"$o")

  if [ -z "$sym" ] || [ -z "$side" ] || [ -z "$type" ] || [ -z "$qty" ]; then
    die "BAD_ARGS" "order[$idx] missing symbol/side/type/quantity" \
        "Each batch order requires symbol, side, type, quantity"
  fi

  # validate_order rounds qty/price; aborts on minQty / minNotional fails.
  # When it dies, its err_json comes out as $_vres. Re-emit a single
  # batch-aware error so callers get one clean JSON with the index.
  local _vres
  if ! _vres=$(validate_order "$sym" "$qty" "$price"); then
    local inner_code inner_msg
    inner_code=$(echo "$_vres" | jq -r '.error.code    // "INVALID_ORDER"' 2>/dev/null || echo INVALID_ORDER)
    inner_msg=$( echo "$_vres" | jq -r '.error.message // ""'              2>/dev/null || echo "")
    die "$inner_code" "order[$idx] $inner_msg" "Per-order validation failed"
  fi
  read -r qty price <<<"$_vres"
  [ -z "$coid" ] && coid=$(gen_client_order_id)

  # Reference price for notional accounting: limit price if set, else mark.
  local ref="$price"
  if [ "$ref" = "0" ]; then
    ref=$(public_get /fapi/v1/premiumIndex "symbol=$sym" | jq -r .markPrice)
  fi
  local notional
  notional=$(python3 -c \
    "import sys,decimal as d;print(d.Decimal(sys.argv[1])*d.Decimal(sys.argv[2]))" \
    "$qty" "$ref")

  jq -nc \
    --arg sym "$sym" --arg side "$side" --arg type "$type" \
    --arg qty "$qty" --arg price "$price" --arg tif "$tif" \
    --arg coid "$coid" --arg pside "$pside" \
    --arg ro "$ro" --arg cp "$cp" --arg wt "$wt" \
    --arg sp "$sp" --arg cb "$cb" --arg n "$notional" \
    '{order: ({symbol:$sym, side:$side, type:$type, quantity:$qty, newClientOrderId:$coid}
              + (if $type=="LIMIT" then {timeInForce:$tif, price:$price} else {} end)
              + (if $pside!="BOTH"  then {positionSide:$pside} else {} end)
              + (if $ro=="true"     then {reduceOnly:"true"} else {} end)
              + (if $cp=="true"     then {closePosition:"true"} else {} end)
              + (if $wt!=""         then {workingType:$wt} else {} end)
              + (if $sp!=""         then {stopPrice:$sp} else {} end)
              + (if $cb!=""         then {callbackRate:$cb} else {} end)),
      notional:$n}'
}

_order_place_batch() {
  local orders_file="" orders_inline="" dry_run=0
  # ARG_CONFIRM is read by require_confirmation in _common.sh.
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  while [ $# -gt 0 ]; do case "$1" in
    --orders-file)     orders_file="$2"; shift 2;;
    --orders)          orders_inline="$2"; shift 2;;
    --dry-run)         dry_run=1; shift;;
    --confirm)         ARG_CONFIRM=1; shift;;
    --mainnet|--testnet) shift;;
    *) shift;;
  esac; done

  local raw=""
  if [ -n "$orders_file" ]; then
    [ -f "$orders_file" ] || die "BAD_ARGS" "orders file not found: $orders_file" ""
    raw=$(cat "$orders_file")
  elif [ -n "$orders_inline" ]; then
    raw="$orders_inline"
  else
    die "BAD_ARGS" "--orders-file or --orders required" \
        "Pass JSON array of orders (max 5)"
  fi

  echo "$raw" | jq -e 'type=="array"' >/dev/null \
    || die "BAD_ARGS" "orders payload is not a JSON array" "Expected [{...}, ...]"
  local count
  count=$(echo "$raw" | jq 'length')
  if [ "$count" -lt 1 ] || [ "$count" -gt 5 ]; then
    die "BATCH_SIZE" "batch must contain 1..5 orders, got $count" \
        "Split into smaller batches"
  fi

  # Per-order: validate + normalize + accumulate notional. We don't rely on
  # `set -e` propagating from command substitutions (bats' `run` and other
  # callers disable errexit), so check exit status explicitly.
  local normalized="[]" total_notional="0"
  local i o pair _rc obj per_notional
  for ((i=0; i<count; i++)); do
    o=$(echo "$raw" | jq -c ".[$i]")
    pair=$(_batch_normalize_one "$i" "$o"); _rc=$?
    if [ $_rc -ne 0 ]; then
      # `pair` carries the err_json produced by die() inside the helper.
      printf '%s\n' "$pair"
      return $_rc
    fi
    obj=$(echo "$pair" | jq -c '.order')
    per_notional=$(echo "$pair" | jq -r '.notional')
    total_notional=$(python3 -c \
      "import sys,decimal as d;print(d.Decimal(sys.argv[1])+d.Decimal(sys.argv[2]))" \
      "$total_notional" "$per_notional")
    normalized=$(jq -nc --argjson a "$normalized" --argjson o "$obj" '$a + [$o]')
  done

  # Mainnet confirmation gate runs over aggregate notional. Per-symbol
  # leverage isn't queried (would multiply weight); use 1 as floor.
  require_confirmation "$total_notional" "1"

  # URL-encode the JSON array for the batchOrders query parameter.
  local encoded
  encoded=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe=''))" <<<"$normalized")
  local q="batchOrders=$encoded"

  if [ "$dry_run" -eq 1 ]; then
    jq -nc --arg v "$FUTURES_VENUE" --arg n "$FUTURES_NETWORK" \
          --arg c "$CMD" --arg tn "$total_notional" \
          --argjson o "$normalized" \
          '{ok:true,venue:$v,network:$n,command:$c,
            data:{would_send:$o,count:($o|length),estimated_notional:$tn,dry_run:true},
            warnings:[],error:null}'
    return 0
  fi
  signed_req POST /fapi/v1/batchOrders "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}

_order_cancel_batch() {
  local sym="" oids="" coids=""
  # ARG_CONFIRM is read by require_confirmation in _common.sh.
  # shellcheck disable=SC2034
  ARG_CONFIRM=0
  while [ $# -gt 0 ]; do case "$1" in
    --symbol)             sym="$2"; shift 2;;
    --order-ids)          oids="$2"; shift 2;;
    --client-order-ids)   coids="$2"; shift 2;;
    --confirm)            ARG_CONFIRM=1; shift;;
    --mainnet|--testnet)  shift;;
    *) shift;;
  esac; done
  [ -z "$sym" ] && die "BAD_ARGS" "--symbol required" ""
  if [ -z "$oids" ] && [ -z "$coids" ]; then
    die "BAD_ARGS" "--order-ids or --client-order-ids required" \
        "Comma-separated list, e.g. --order-ids 12345,67890"
  fi

  # Cancels are defensive: we still pass through the gate so mainnet users
  # get the same env/flag protection, but use notional 0 so it never blocks
  # on FUTURES_MAX_NOTIONAL.
  require_confirmation "0" "1"

  local q="symbol=$sym"
  local list enc
  if [ -n "$oids" ]; then
    list=$(echo "$oids" | jq -Rc 'split(",")|map(select(length>0)|tonumber)' 2>/dev/null) \
      || die "BAD_ARGS" "--order-ids must be comma-separated integers" \
             "Got: $oids"
    enc=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe=''))" <<<"$list")
    q="$q&orderIdList=$enc"
  fi
  if [ -n "$coids" ]; then
    list=$(echo "$coids" | jq -Rc 'split(",")|map(select(length>0))')
    enc=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe=''))" <<<"$list")
    q="$q&origClientOrderIdList=$enc"
  fi

  signed_req DELETE /fapi/v1/batchOrders "$q" | normalize_error \
    | { read -r d; ok_json "$CMD" "$d"; }
}
