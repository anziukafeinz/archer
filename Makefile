.PHONY: test lint check

# Run all unit tests (bats-core). Hermetic — no network.
test:
	bats tests/

# Static analysis on the active surface (everything except calc.sh, which
# has a pre-existing SC2261 issue tracked separately).
lint:
	shellcheck --severity=error -x -P scripts/ \
	  scripts/futures-cli scripts/_common.sh scripts/order.sh \
	  scripts/account.sh scripts/market.sh scripts/risk.sh

check: lint test
