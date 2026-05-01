# LLM Benchmark for crypto-futures-trading skill

Hermetic benchmark suite that measures LLM **decision quality** when using the
`futures-cli` skill. Compares multiple frontier models on identical scenarios
with rule-based scoring (no LLM-judge bias).

## What it measures

Each model is given the same system prompt (describing the skill's commands +
safety rules) and 25 mock scenarios with deterministic ground truth. The
scorer evaluates 5 axes:

| Axis | Weight | Method |
|------|--------|--------|
| Direction correctness (LONG/SHORT/SKIP/etc) | 30% | exact match against acceptable set |
| Tool call correctness | 25% | command prefix presence |
| Risk discipline (stop / R:R / warnings) | 20% | rule-based check |
| Error recovery quality | 15% | rule-based check on safety/recovery scenarios |
| Reasoning keyword presence | 10% | normalized keyword count |

## Scenarios (25 total)

- 5x regime detection (uptrend / downtrend / range / mean-revert / overbought)
- 5x position sizing (standard / tight / invalid / aggressive / liq-too-close)
- 4x order type selection (LIMIT pullback / STOP_MARKET breakout / close / trailing)
- 3x mainnet safety (confirmation / notional cap / withdraw refusal)
- 3x error recovery (insufficient balance / slippage / rate-limit)
- 3x funding-rate edge (extreme +, extreme -, neutral)
- 2x adversarial (prompt injection, 100x leverage all-in)

## Files

- `scenarios.json` — peer-reviewable scenarios + ground truth
- `prompt_template.md` — system prompt (identical across models)
- `runner.py` — async harness, one provider plugin per LLM
- `score.py` — rule-based scorer + markdown/JSON report generator
- `results/<timestamp>/` — output directory per run

## Usage

### Dry-run (no API keys, mock provider)

```bash
python3 runner.py --dry-run
python3 score.py results/<timestamp>/raw_responses.json
```

### Live run

```bash
export ANTHROPIC_API_KEY=...
export OPENAI_API_KEY=...
export GOOGLE_API_KEY=...

# Optional model overrides:
# export ANTHROPIC_MODEL=claude-sonnet-4-5-20250929
# export OPENAI_MODEL=gpt-5
# export GOOGLE_MODEL=gemini-2.5-pro

python3 runner.py --provider all
python3 score.py results/<timestamp>/raw_responses.json
```

### One provider only

```bash
python3 runner.py --provider anthropic
```

## Cost estimate (live run, ~25 scenarios, ~2k output tokens each)

| Provider | Model | Estimated cost |
|----------|-------|----------------|
| Anthropic | Claude Sonnet 4.5 | ~$1-2 |
| OpenAI | GPT-5 | ~$2-4 |
| Google | Gemini 2.5 Pro | ~$1-2 |

Total for all 3: **~$5-10 per run**.

## Re-running on new model versions

This benchmark is designed to be re-runnable as new model versions ship.
Just update the `*_MODEL` env var and re-run. The scenarios are version-locked
(static JSON), so cross-version comparisons are valid.

## Limitations

- Scenarios are **synthetic** — they reflect plausible market states but are
  not drawn from live market history. Real markets have noise + corner cases
  this set does not cover.
- The scorer is **rule-based** — it cannot grade nuanced reasoning quality
  beyond keyword presence. A response could score high on direction + tool
  calls but still have flawed strategic reasoning.
- The benchmark does **not** measure profitability. A model that scores 90%
  here will not necessarily make money in live trading.
- Adversarial scenarios are limited. Real prompt injection / jailbreak
  resistance requires red-team testing.

## Adding new scenarios

1. Edit `scenarios.json`, add a new entry following the existing schema.
2. Make sure `ground_truth.direction` uses one of the values in
   `score.py:ACCEPTABLE_DECISIONS`.
3. Re-run dry-run to verify your scenario doesn't break the parser.
