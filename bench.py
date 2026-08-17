#!/usr/bin/env python3
"""Mide decode tok/s, prompt-eval tok/s y aceptación del drafter MTP.

Usa el bloque `timings` (estilo llama.cpp) que devuelve el servidor mlx-vlm en
/v1/chat/completions, así que las cifras son las del propio motor, no un
cronómetro externo.
"""

import argparse
import json
import statistics
import time
import urllib.request

PROMPTS = [
    "Write a complete Python implementation of a red-black tree with insert, "
    "delete and search, plus docstrings and a small usage example.",
    "Explain step by step how HTTP/3 and QUIC differ from HTTP/2 over TCP, "
    "covering handshake, multiplexing, head-of-line blocking and congestion control.",
    "Write a Rust function that parses an INI file into a nested HashMap, with "
    "error handling, unit tests and comments explaining each branch.",
]


def post(url: str, payload: dict, timeout: int = 900) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def run_one(url: str, model: str, prompt: str, max_tokens: int) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": False,
    }
    t0 = time.perf_counter()
    resp = post(url, body)
    wall = time.perf_counter() - t0
    t = resp.get("timings") or {}
    usage = resp.get("usage") or {}
    n, acc = t.get("draft_n"), t.get("draft_n_accepted")
    return {
        "decode_tok_s": t.get("predicted_per_second"),
        "prefill_tok_s": t.get("prompt_per_second"),
        "prompt_n": t.get("prompt_n"),
        "predicted_n": t.get("predicted_n") or usage.get("completion_tokens"),
        "peak_memory_gb": t.get("peak_memory"),
        "draft_kind": t.get("draft_kind"),
        "draft_n": n,
        "draft_n_accepted": acc,
        "acceptance_pct": (100.0 * acc / n) if n else None,
        "wall_s": wall,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://127.0.0.1:8080/v1/chat/completions")
    p.add_argument("--model", default="mlx-community/Qwen3.8-27B-4bit")
    p.add_argument("--max-tokens", type=int, default=512)
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--label", default="mlx-vlm + MTP")
    p.add_argument("--out", default=None)
    a = p.parse_args()

    print(f"warmup…", flush=True)
    run_one(a.url, a.model, "Say hello in one short sentence.", 32)

    runs = []
    for i in range(a.reps):
        r = run_one(a.url, a.model, PROMPTS[i % len(PROMPTS)], a.max_tokens)
        runs.append(r)
        acc = f"{r['acceptance_pct']:.1f}%" if r["acceptance_pct"] is not None else "—"
        print(
            f"  run {i + 1}: decode {r['decode_tok_s']:.1f} tok/s · "
            f"prefill {r['prefill_tok_s']:.1f} tok/s · "
            f"aceptación {acc} · {r['predicted_n']} tok · {r['wall_s']:.1f}s",
            flush=True,
        )

    def med(k):
        vals = [r[k] for r in runs if r.get(k) is not None]
        return statistics.median(vals) if vals else None

    tot_n = sum(r["draft_n"] or 0 for r in runs)
    tot_a = sum(r["draft_n_accepted"] or 0 for r in runs)
    summary = {
        "label": a.label,
        "model": a.model,
        "max_tokens": a.max_tokens,
        "reps": a.reps,
        "decode_tok_s_median": med("decode_tok_s"),
        "prefill_tok_s_median": med("prefill_tok_s"),
        "acceptance_pct_overall": (100.0 * tot_a / tot_n) if tot_n else None,
        "peak_memory_gb": med("peak_memory_gb"),
        "draft_kind": runs[0].get("draft_kind"),
        "runs": runs,
    }

    print("\n" + "=" * 62)
    print(f"  {a.label}")
    print("=" * 62)
    print(f"  decode        {summary['decode_tok_s_median']:.1f} tok/s (mediana)")
    print(f"  prompt eval   {summary['prefill_tok_s_median']:.1f} tok/s (mediana)")
    if summary["acceptance_pct_overall"] is not None:
        print(
            f"  aceptación    {summary['acceptance_pct_overall']:.1f}% "
            f"({tot_a}/{tot_n} tokens borrador)"
        )
    print(f"  pico memoria  {summary['peak_memory_gb']:.2f} GB")
    print("=" * 62)

    if a.out:
        with open(a.out, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"\nJSON -> {a.out}")


if __name__ == "__main__":
    main()
