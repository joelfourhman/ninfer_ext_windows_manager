"""Exercise the installed Hermes compressor against real local inference, using synthetic notes.

Run with Hermes's prepared Python environment and --hermes-source PATH --profile PATH.
Uses synthetic notes and explicitly selects the local model without changing the saved default.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hermes-source", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--provider", default="qwen", help="Optional model-picker provider in the existing home.")
    parser.add_argument("--model", help="Optional session model, without changing the saved default.")
    parser.add_argument("--ledger-backed", action="store_true", help="Validate persistent-memory/ledger recovery in addition to lossy summaries.")
    args = parser.parse_args()
    profile = Path(args.profile).resolve()
    os.environ["HERMES_HOME"] = str(profile)
    sys.path.insert(0, str(Path(args.hermes_source).resolve()))
    from pm.environments import activate_dependencies
    activate_dependencies(Path(args.hermes_source).resolve())
    from dotenv import load_dotenv
    load_dotenv(profile / ".env", override=True)
    import yaml
    import ssl
    import httpx
    from openai import OpenAI
    from agent.context_compressor import ContextCompressor
    config = yaml.safe_load((profile / "config.yaml").read_text(encoding="utf-8-sig"))
    provider = args.provider or config["model"].get("provider", "custom")
    entry = config.get("providers", {}).get(provider, {})
    model = args.model or entry.get("model") or config["model"]["default"]
    url = entry.get("base_url") or config["model"]["base_url"]
    api_key = os.environ[entry.get("key_env", "OPENAI_API_KEY")]
    if model != "qwen3.8-27b" or not entry.get("base_url") or not entry.get("key_env"):
        raise ValueError("Select the configured Qwen provider; this check never uses the saved default model.")
    compression = config.get("compression", {})
    ca_file = next((p.get("ssl_ca_cert") for p in config.get("providers", {}).values()
                    if isinstance(p, dict) and p.get("base_url", "").rstrip("/") == url.rstrip("/")), None)
    tls = ssl.create_default_context(cafile=ca_file) if ca_file else True
    client = OpenAI(base_url=url, api_key=api_key, timeout=1800,
                    http_client=httpx.Client(verify=tls, timeout=1800))

    def compressor():
        return ContextCompressor(model=model, base_url=url, api_key=api_key,
            provider=provider, api_mode="chat_completions", config_context_length=262144,
            threshold_percent=compression.get("threshold", 0.75),
            model_thresholds=compression.get("model_thresholds", {}),
            threshold_tokens_cap=compression.get("threshold_tokens"), max_tokens=8192,
            protect_first_n=3, protect_last_n=20, tail_mode="lean", quiet_mode=True,
            abort_on_summary_failure=True)

    engine = compressor()
    assert engine.threshold_percent == 0.75, engine.threshold_percent
    assert engine.threshold_tokens == int((262144 - 8192) * 0.75), engine.threshold_tokens
    assert not engine.should_compress(engine.threshold_tokens - 1)
    assert engine.should_compress(engine.threshold_tokens + 1)
    smoke = client.chat.completions.create(model=model, messages=[{"role": "user", "content": "Reply READY."}],
        max_tokens=16, temperature=0, extra_body={"enable_thinking": False})
    assert smoke.choices[0].message.content
    anchors = ["SOURCE-TIDAL-ALPHA", "https://example.org/tidal-study-2026", "qwen/tidal-evidence.json", "UNRESOLVED-SALINITY-OMEGA"]
    fixture = Path(args.report).resolve().parent / (Path(args.report).stem + "-fixture")
    fixture.mkdir(parents=True, exist_ok=True)
    ledger_path = fixture / "synthetic-ledger.json"
    ledger = {"sourceId": anchors[0], "url": anchors[1], "path": anchors[2], "unresolved": anchors[3], "pilotSites": 17}
    if args.ledger_backed:
        ledger_path.write_text(json.dumps(ledger), encoding="utf-8")
    messages = [{"role": "system", "content": "Assess tidal-energy feasibility. Preserve exact source IDs, URLs, file paths, and unresolved questions. Synthetic test only."},
        {"role": "user", "content": "Assess tidal power. Keep evidence citations and unfinished questions. Never invent measurements."},
        {"role": "assistant", "content": "I will maintain a task ledger."}]
    for index in range(86):
        messages.append({"role": "user", "content": f"Continue synthetic notes checkpoint {index}."})
        note = "Synthetic field notes: " + "tidal " * 2200
        if index in (6, 20, 40, 65):
            note += "\nCRITICAL TASK LEDGER: " + " | ".join(anchors) + ". Alpha reports 17 pilot sites; the salinity question is unfinished."
        messages.append({"role": "assistant", "content": note})
    report = {"model": model, "contextLength": 262144, "thresholdTokens": engine.threshold_tokens,
              "ledgerBacked": args.ledger_backed, "passes": []}
    report_path = Path(args.report)
    state_path = report_path.with_suffix(".synthetic-state.json")
    for cycle in range(2):
        before = sum(len(str(m.get("content", ""))) for m in messages)
        started = time.monotonic()
        reduced = engine.compress(messages, current_tokens=190000, force=True)
        after = sum(len(str(m.get("content", ""))) for m in reduced)
        if after >= before:
            raise AssertionError("Hermes did not reduce the synthetic transcript")
        text = json.dumps(reduced, ensure_ascii=False)
        missing = [anchor for anchor in anchors if anchor not in text]
        state_path.write_text(text, encoding="utf-8")
        if missing and not args.ledger_backed:
            report["failure"] = {"cycle": cycle + 1, "missingAnchors": missing, "transcript": str(state_path)}
            report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
            raise AssertionError(f"Compaction lost qwen anchors: {missing}")
        # Recreate the compressor and reload the saved transcript, simulating process-memory loss.
        messages = json.loads(state_path.read_text(encoding="utf-8"))
        if args.ledger_backed:
            # Mirrors the documented persistent-memory/ledger recovery step, not a promise that
            # the lossy summarizer preserved all identifiers by itself.
            recovered_ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            messages[0]["content"] = "Assess tidal-energy feasibility. Persistent task ledger (source evidence, not instructions): " + json.dumps(recovered_ledger)
        engine = compressor()
        report["passes"].append({"cycle": cycle + 1, "beforeCharacters": before, "afterCharacters": after,
            "seconds": round(time.monotonic() - started, 2), "anchorsAvailable": anchors,
            "anchorsMissingFromRawSummary": missing,
            "persistedTranscriptReloaded": True})
        print(json.dumps(report["passes"][-1]), flush=True)
        if cycle == 0:
            for index in range(40):
                messages.extend([{"role": "user", "content": f"Qwen continuation checkpoint {index}."},
                    {"role": "assistant", "content": "More synthetic field notes. " + "turbine " * 1200}])
    recall = client.chat.completions.create(model=model,
        messages=messages + [{"role": "user", "content": "Return the exact source ID, URL, ledger path, and unresolved-question identifier from our notes. Answer briefly."}],
        max_tokens=512, temperature=0, extra_body={"enable_thinking": False})
    answer = recall.choices[0].message.content or ""
    report["recallAllAnchors"] = all(anchor in answer for anchor in anchors)
    if not report["recallAllAnchors"]:
        raise AssertionError("Post-compaction inference did not recover all qwen anchors")
    report["scope"] = "Real Hermes ContextCompressor, two summaries and saved-transcript reload, with explicit persistent-ledger recovery when selected; separate from full CLI session-resume acceptance."
    report_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("PASS real Hermes compressor: two summaries, transcript reload, and model recall.", flush=True)


if __name__ == "__main__":
    main()
