# shellcheck shell=bash
# risk.sh — view + reset risk-layer state. Persistent state lives in
# ~/.futures-cli/state.json (JSON for v0.1; SQLite later).
set -euo pipefail

RISK_DIR="${HOME}/.futures-cli"
RISK_STATE="$RISK_DIR/state.json"
RISK_LIMITS="$RISK_DIR/limits.json"

risk_dispatch() {
  local sub="${1:-show}"; shift || true
  CMD="risk $sub"
  mkdir -p "$RISK_DIR"
  [ -f "$RISK_LIMITS" ] || cat > "$RISK_LIMITS" <<'JSON'
{
  "max_leverage": 5,
  "max_notional_usd": 1000,
  "max_daily_loss_usd": 200,
  "allowed_symbols": [],
  "circuit_breaker": {
    "drawdown_pct": 5,
    "window_minutes": 60,
    "action": "cancel_all_and_block"
  }
}
JSON
  [ -f "$RISK_STATE" ] || echo '{"daily_pnl_usd":0,"trades":[],"blocked":false}' > "$RISK_STATE"

  case "$sub" in
    show)  jq -nc --slurpfile l "$RISK_LIMITS" --slurpfile s "$RISK_STATE" \
              '{ok:true,command:"risk show",data:{limits:$l[0],state:$s[0]}}' ;;
    reset) echo '{"daily_pnl_usd":0,"trades":[],"blocked":false}' > "$RISK_STATE"
           ok_json "$CMD" '{"reset":true}' ;;
    *) die "UNKNOWN_CMD" "risk $sub" "futures-cli risk show|reset" ;;
  esac
}
