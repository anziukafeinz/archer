#!/usr/bin/env python3
"""LLM benchmark runner for crypto-futures-trading skill.

Runs all scenarios across configured providers, collects raw responses,
and writes them to results/<timestamp>/raw_responses.json.

Usage:
    python3 runner.py --dry-run            # mock provider only
    python3 runner.py --provider all       # live (needs API keys)
    python3 runner.py --provider anthropic # specific provider
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).parent
SCENARIOS_PATH = ROOT / "scenarios.json"
PROMPT_TEMPLATE_PATH = ROOT / "prompt_template.md"


# -------- provider plugins --------


class Provider:
    """Base provider interface."""

    name: str = "base"
    model: str = ""

    async def complete(self, system_prompt: str, user_message: str) -> str:
        raise NotImplementedError


class MockProvider(Provider):
    """Deterministic mock that returns canned responses based on scenario category.

    Used for dry-run pipeline validation. Returns a JSON string that mostly
    matches ground truth for ~70% of scenarios so we can verify the scorer.
    """

    name = "mock"
    model = "mock-deterministic-v1"

    async def complete(self, system_prompt: str, user_message: str) -> str:
        try:
            scenario = json.loads(user_message)
        except json.JSONDecodeError:
            return json.dumps({"decision": "SKIP", "reasoning": "parse error", "commands": []})

        category = scenario.get("category", "")
        gt = scenario.get("_ground_truth_for_mock", {})  # mock peeks at GT for partial accuracy
        canned = self._canned_response(category, gt, scenario)
        return json.dumps(canned)

    @staticmethod
    def _canned_response(category: str, gt: dict, scenario: dict) -> dict:
        """Return a response that's ~70% accurate vs ground truth (mock realism)."""
        direction = gt.get("direction", "SKIP")
        # Coerce composite directions to a single token
        direction_map = {
            "SKIP_OR_SHORT": "SKIP",
            "REJECT_OR_WARN": "REJECT",
            "REJECT_OR_REQUEST_CONFIRMATION": "REJECT",
            "RECONSIDER": "WAIT",
            "REFUSE_AND_FLAG": "REFUSE",
            "REFUSE_OR_WARN": "REFUSE",
            "CONDITIONAL_LONG": "LONG",
            "SHORT_OR_DELTA_NEUTRAL": "SHORT",
            "MANAGE": "MANAGE",
            "FLAT": "FLAT",
            "RECALCULATE": "RECALCULATE",
            "WAIT": "WAIT",
            "REJECT": "REJECT",
            "REFUSE": "REFUSE",
            "SKIP": "SKIP",
            "LONG": "LONG",
            "SHORT": "SHORT",
            "N/A": "SKIP",
        }
        decision = direction_map.get(direction, "SKIP")

        # Synthesize plausible commands from expected_commands
        cmds = []
        for cmd_prefix in gt.get("expected_commands", []):
            cmds.append(cmd_prefix + " --symbol BTCUSDT")
        # Inject some noise: skip last command 30% of the time (sce-id parity check)
        sid_num = int(scenario.get("id", "sce-000").split("-")[1])
        if sid_num % 3 == 0 and cmds:
            cmds = cmds[:-1]

        warnings = []
        if gt.get("must_warn") or gt.get("must_refuse") or gt.get("must_reject"):
            warnings.append("risk-flagged: " + scenario.get("title", ""))

        kw = gt.get("reasoning_keywords", [])
        # Mock includes ~60% of keywords
        kw_in_reasoning = " ".join(kw[: max(1, int(len(kw) * 0.6))])

        return {
            "decision": decision,
            "reasoning": f"Mock reasoning: {kw_in_reasoning}".strip(),
            "commands": cmds,
            "order_type": (
                "LIMIT" if decision in ("LONG", "SHORT") and sid_num % 2 == 0
                else "MARKET" if decision in ("LONG", "SHORT")
                else None
            ),
            "stop_loss_set": gt.get("must_set_stop", False),
            "risk_reward_ratio": (
                2.0 if gt.get("min_rr") and gt["min_rr"] >= 1.0 else None
            ),
            "warnings": warnings,
        }


class AnthropicProvider(Provider):
    """Claude via Anthropic Messages API."""

    name = "anthropic"

    def __init__(self, api_key: str, model: str = "claude-sonnet-4-5-20250929"):
        self.api_key = api_key
        self.model = model

    async def complete(self, system_prompt: str, user_message: str) -> str:
        import httpx
        async with httpx.AsyncClient(timeout=120.0) as client:
            r = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": self.api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": self.model,
                    "max_tokens": 2048,
                    "system": system_prompt,
                    "messages": [{"role": "user", "content": user_message}],
                },
            )
            r.raise_for_status()
            data = r.json()
            return data["content"][0]["text"]


class OpenAIProvider(Provider):
    """GPT via OpenAI Chat Completions API."""

    name = "openai"

    def __init__(self, api_key: str, model: str = "gpt-5"):
        self.api_key = api_key
        self.model = model

    async def complete(self, system_prompt: str, user_message: str) -> str:
        import httpx
        async with httpx.AsyncClient(timeout=120.0) as client:
            r = await client.post(
                "https://api.openai.com/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "content-type": "application/json",
                },
                json={
                    "model": self.model,
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": user_message},
                    ],
                    "response_format": {"type": "json_object"},
                },
            )
            r.raise_for_status()
            data = r.json()
            return data["choices"][0]["message"]["content"]


class GoogleProvider(Provider):
    """Gemini via Google Generative AI API."""

    name = "google"

    def __init__(self, api_key: str, model: str = "gemini-2.5-pro"):
        self.api_key = api_key
        self.model = model

    async def complete(self, system_prompt: str, user_message: str) -> str:
        import httpx
        url = (
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self.model}:generateContent?key={self.api_key}"
        )
        async with httpx.AsyncClient(timeout=120.0) as client:
            r = await client.post(
                url,
                json={
                    "contents": [
                        {"role": "user", "parts": [{"text": user_message}]}
                    ],
                    "systemInstruction": {"parts": [{"text": system_prompt}]},
                    "generationConfig": {
                        "responseMimeType": "application/json",
                        "maxOutputTokens": 2048,
                    },
                },
            )
            r.raise_for_status()
            data = r.json()
            return data["candidates"][0]["content"]["parts"][0]["text"]


# -------- runner --------


def load_scenarios() -> list[dict]:
    return json.loads(SCENARIOS_PATH.read_text())["scenarios"]


def load_prompt_template() -> str:
    return PROMPT_TEMPLATE_PATH.read_text()


def build_user_message(scenario: dict, include_gt_for_mock: bool = False) -> str:
    """Strip ground_truth from the scenario before sending to the LLM.

    For mock provider, optionally embed it under _ground_truth_for_mock so mock
    can synthesize plausible answers."""
    payload = {
        "id": scenario["id"],
        "category": scenario["category"],
        "title": scenario["title"],
        "market_state": scenario["market_state"],
        "user_question": scenario["user_question"],
    }
    if include_gt_for_mock:
        payload["_ground_truth_for_mock"] = scenario["ground_truth"]
    return json.dumps(payload, indent=2)


async def run_scenario(provider: Provider, scenario: dict, system_prompt: str) -> dict:
    """Run one scenario through one provider; return raw record."""
    is_mock = isinstance(provider, MockProvider)
    user_message = build_user_message(scenario, include_gt_for_mock=is_mock)

    record = {
        "scenario_id": scenario["id"],
        "provider": provider.name,
        "model": provider.model,
        "started_at": dt.datetime.now(dt.timezone.utc).isoformat() + "Z",
        "raw_response": None,
        "parsed": None,
        "error": None,
    }
    try:
        raw = await provider.complete(system_prompt, user_message)
        record["raw_response"] = raw
        record["parsed"] = parse_json_response(raw)
    except Exception as e:
        record["error"] = f"{type(e).__name__}: {e}"
    record["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat() + "Z"
    return record


def parse_json_response(raw: str) -> dict | None:
    """Extract JSON object from LLM response. Tolerates code fences."""
    if not raw:
        return None
    # Strip markdown fences if present
    s = raw.strip()
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    # Find first { and last }
    start = s.find("{")
    end = s.rfind("}")
    if start == -1 or end == -1:
        return None
    try:
        return json.loads(s[start : end + 1])
    except json.JSONDecodeError:
        return None


async def run_provider(provider: Provider, scenarios: list[dict], system_prompt: str) -> list[dict]:
    """Run all scenarios sequentially for one provider (kind to rate limits)."""
    print(f"  Running {provider.name} ({provider.model})...", flush=True)
    records = []
    for sc in scenarios:
        rec = await run_scenario(provider, sc, system_prompt)
        records.append(rec)
        status = "ok" if rec["parsed"] else ("err: " + (rec.get("error") or "no JSON"))
        print(f"    {sc['id']}: {status}", flush=True)
    return records


def make_providers(args: argparse.Namespace) -> list[Provider]:
    """Resolve which providers to instantiate based on flags + env."""
    providers = []
    if args.dry_run:
        return [MockProvider()]

    selected = args.provider
    if selected in ("all", "anthropic"):
        key = os.environ.get("ANTHROPIC_API_KEY")
        if key:
            providers.append(
                AnthropicProvider(key, model=os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-4-5-20250929"))
            )
        else:
            print("  Skipping anthropic: no ANTHROPIC_API_KEY")
    if selected in ("all", "openai"):
        key = os.environ.get("OPENAI_API_KEY")
        if key:
            providers.append(OpenAIProvider(key, model=os.environ.get("OPENAI_MODEL", "gpt-5")))
        else:
            print("  Skipping openai: no OPENAI_API_KEY")
    if selected in ("all", "google"):
        key = os.environ.get("GOOGLE_API_KEY")
        if key:
            providers.append(GoogleProvider(key, model=os.environ.get("GOOGLE_MODEL", "gemini-2.5-pro")))
        else:
            print("  Skipping google: no GOOGLE_API_KEY")

    return providers


async def main_async(args: argparse.Namespace) -> int:
    scenarios = load_scenarios()
    system_prompt = load_prompt_template().split("# User message")[0].strip()
    providers = make_providers(args)
    if not providers:
        print("ERROR: no providers configured. Set API keys or use --dry-run.", file=sys.stderr)
        return 2

    print(f"Running {len(scenarios)} scenarios across {len(providers)} provider(s)")
    print(f"Providers: {[p.name + '(' + p.model + ')' for p in providers]}")
    print()

    all_records = []
    for prov in providers:
        recs = await run_provider(prov, scenarios, system_prompt)
        all_records.extend(recs)

    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = ROOT / "results" / ts
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "raw_responses.json"
    out_path.write_text(json.dumps({
        "run_started_at": ts,
        "scenario_count": len(scenarios),
        "providers": [{"name": p.name, "model": p.model} for p in providers],
        "records": all_records,
    }, indent=2))
    print(f"\nWrote {len(all_records)} records to {out_path}")
    print(f"Next: python3 score.py {out_path}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="LLM benchmark runner")
    parser.add_argument("--dry-run", action="store_true", help="use mock provider only")
    parser.add_argument(
        "--provider",
        default="all",
        choices=["all", "anthropic", "openai", "google"],
    )
    args = parser.parse_args()
    sys.exit(asyncio.run(main_async(args)))


if __name__ == "__main__":
    main()
