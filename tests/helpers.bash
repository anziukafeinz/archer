# shellcheck shell=bash
# Shared bats setup. Sourced by every test file.
#
# Important: scripts/_common.sh activates `set -euo pipefail` and resolves the
# BASE_URL from FUTURES_VENUE/NETWORK at source time, so we MUST export those
# before sourcing.

WORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$WORK_ROOT/scripts"
FIXTURES_DIR="$WORK_ROOT/tests/fixtures"

setup_futures_env() {
  export FUTURES_VENUE="binance"
  export FUTURES_NETWORK="testnet"
  export FUTURES_API_KEY="test-key"
  export FUTURES_API_SECRET="test-secret"
  unset FUTURES_CONFIRM FUTURES_MAX_NOTIONAL FUTURES_MAX_LEVERAGE \
        FUTURES_ALLOWED_SYMBOLS FUTURES_MAX_SLIPPAGE
  # Each test gets its own TMPDIR so EX_CACHE doesn't leak between tests.
  export TMPDIR="${BATS_TEST_TMPDIR:-/tmp/futures-cli-test-$$}"
  mkdir -p "$TMPDIR"
  # Pre-populate exchangeInfo cache so symbol_filters does not hit network.
  local cache="$TMPDIR/futures-cli-exinfo-binance-testnet.json"
  cp "$FIXTURES_DIR/exchangeInfo.json" "$cache"
  # Touch into the future so the 60-min freshness check passes.
  touch -d "+1 hour" "$cache" 2>/dev/null || touch "$cache"
}

source_common() {
  setup_futures_env
  # shellcheck source=../scripts/_common.sh
  source "$SCRIPTS_DIR/_common.sh"
}

source_common_and_order() {
  source_common
  # shellcheck source=../scripts/order.sh
  source "$SCRIPTS_DIR/order.sh"
}

source_common_and_account() {
  source_common
  # shellcheck source=../scripts/account.sh
  source "$SCRIPTS_DIR/account.sh"
}

# Stubs used by batch tests to avoid network. `signed_req` records its
# arguments to $SIGNED_REQ_LOG and emits a canned JSON success response.
mock_signed_req() {
  export SIGNED_REQ_LOG="$TMPDIR/signed-req.log"
  : >"$SIGNED_REQ_LOG"
  signed_req() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$SIGNED_REQ_LOG"
    # By default emit an empty array (batch endpoints).
    echo '[]'
  }
  public_get() {
    # Return a fake mark price for premiumIndex; otherwise empty.
    case "$2" in
      symbol=*) echo '{"markPrice":"60000.00"}' ;;
      *)        echo '{}' ;;
    esac
  }
  export -f signed_req public_get
}
