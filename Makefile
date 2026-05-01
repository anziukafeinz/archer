.PHONY: test lint check

# Run all unit tests (bats-core). Hermetic — no network.
test:
	bats tests/

# Static analysis on the full active surface. M8 fixed the pre-existing
# SC2261 in calc.sh, so it's now part of the lint set.
lint:
	shellcheck --severity=error -x -P scripts/ \
	  scripts/futures-cli scripts/_common.sh scripts/order.sh \
	  scripts/account.sh scripts/market.sh scripts/risk.sh \
	  scripts/calc.sh

check: lint test
