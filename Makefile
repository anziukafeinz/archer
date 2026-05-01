.PHONY: test lint check

# Run all unit tests (bats-core). Hermetic — no network.
test:
	bats tests/

# Static analysis on the M4 + M7 surface. calc.sh has a pre-existing
# SC2261 issue and is not gated here yet.
lint:
	shellcheck --severity=error -x -P scripts/ \
	  scripts/futures-cli scripts/_common.sh scripts/order.sh \
	  scripts/account.sh scripts/market.sh scripts/risk.sh

check: lint test
