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
    list)
      local q=""; while [ $# -gt 0 ]; do case "$1" in --symbol) q="symbol=$2"; shift 2;; *) shift;; esac; done
      signed_req GET /fapi/v3/positionRisk "$q" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    set-leverage)
      local sym="" lev=""
      while [ $# -gt 0 ]; do case "$1" in
        --symbol)   sym="$2"; shift 2;;
        --leverage) lev="$2"; shift 2;;
        *) shift;; esac; done
      [ -z "$sym" ] || [ -z "$lev" ] && die "BAD_ARGS" "--symbol & --leverage required" ""
      signed_req POST /fapi/v1/leverage "symbol=$sym&leverage=$lev" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    set-margin-type)
      local sym="" mt=""
      while [ $# -gt 0 ]; do case "$1" in
        --symbol)      sym="$2"; shift 2;;
        --margin-type) mt="$2";  shift 2;;
        *) shift;; esac; done
      [ -z "$sym" ] || [ -z "$mt" ] && die "BAD_ARGS" "--symbol & --margin-type required (ISOLATED|CROSSED)" ""
      signed_req POST /fapi/v1/marginType "symbol=$sym&marginType=$mt" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    set-position-mode)
      local dual=""
      while [ $# -gt 0 ]; do case "$1" in --dual) dual="$2"; shift 2;; *) shift;; esac; done
      [ -z "$dual" ] && die "BAD_ARGS" "--dual true|false required" ""
      signed_req POST /fapi/v1/positionSide/dual "dualSidePosition=$dual" | normalize_error \
        | { read -r d; ok_json "$CMD" "$d"; } ;;
    adjust-margin)
      local sym="" amt="" type="" pside="BOTH"
      while [ $# -gt 0 ]; do case "$1" in
        --symbol)        sym="$2"; shift 2;;
        --amount)        amt="$2"; shift 2;;
        --type)          type="$2"; shift 2;;   # 1=add, 2=reduce
        --position-side) pside="$2"; shift 2;;
        *) shift;; esac; done
      [ -z "$sym" ] || [ -z "$amt" ] || [ -z "$type" ] \
        && die "BAD_ARGS" "--symbol, --amount, --type (1=add 2=reduce) required" ""
      signed_req POST /fapi/v1/positionMargin \
        "symbol=$sym&amount=$amt&type=$type&positionSide=$pside" \
        | normalize_error | { read -r d; ok_json "$CMD" "$d"; } ;;
    *) die "UNKNOWN_CMD" "position $sub" "futures-cli position --help" ;;
  esac
}
