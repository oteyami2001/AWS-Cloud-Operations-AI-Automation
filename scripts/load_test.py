#!/usr/bin/env python3
"""Dependency-free HTTP load test. Writes a JSON + Markdown report.

    python scripts/load_test.py --url http://<alb-dns> --duration 120 --concurrency 20 --path "/work?ms=20"
    python scripts/load_test.py --url http://127.0.0.1:8080 --duration 20 --label local

Reports throughput, error rate and latency percentiles. Point it at the ALB to drive the CPU alarm
(use a heavier --path such as /work?ms=200) and capture evidence for docs/evidence/.
"""

from __future__ import annotations

import argparse
import json
import statistics
import threading
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    k = max(0, min(len(values) - 1, round(p / 100 * (len(values) - 1))))
    return values[k]


def worker(url: str, stop_at: float, lat: list[float], codes: dict[int, int], lock: threading.Lock) -> None:
    while time.perf_counter() < stop_at:
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(url, timeout=10) as r:  # noqa: S310  # nosec B310 - operator-supplied URL
                r.read()
                code = r.status
        except urllib.error.HTTPError as e:
            code = e.code
        except Exception:  # noqa: BLE001 - connection errors are counted, not fatal
            code = 0
        dt = (time.perf_counter() - t0) * 1000
        with lock:
            lat.append(dt)
            codes[code] = codes.get(code, 0) + 1


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--path", default="/")
    ap.add_argument("--duration", type=int, default=30)
    ap.add_argument("--concurrency", type=int, default=10)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default="docs/evidence/load-tests")
    args = ap.parse_args()

    url = args.url.rstrip("/") + args.path
    lat: list[float] = []
    codes: dict[int, int] = {}
    lock = threading.Lock()
    start = time.perf_counter()
    stop_at = start + args.duration
    threads = [threading.Thread(target=worker, args=(url, stop_at, lat, codes, lock)) for _ in range(args.concurrency)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - start

    total = len(lat)
    errors = sum(v for k, v in codes.items() if k == 0 or k >= 500)
    report = {
        "label": args.label,
        "target": url,
        "started_utc": datetime.now(UTC).isoformat(timespec="seconds"),
        "duration_s": round(elapsed, 1),
        "concurrency": args.concurrency,
        "requests": total,
        "throughput_rps": round(total / elapsed, 1) if elapsed else 0,
        "status_codes": {str(k): v for k, v in sorted(codes.items())},
        "error_rate_pct": round(100 * errors / total, 2) if total else 0,
        "latency_ms": {
            "p50": round(pct(lat, 50), 1),
            "p90": round(pct(lat, 90), 1),
            "p95": round(pct(lat, 95), 1),
            "p99": round(pct(lat, 99), 1),
            "max": round(max(lat), 1) if lat else 0,
            "mean": round(statistics.fmean(lat), 1) if lat else 0,
        },
    }
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    stem = f"{args.label}-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}"
    (out / f"{stem}.json").write_text(json.dumps(report, indent=2))
    lm = report["latency_ms"]
    md = (
        f"# Load test: {args.label}\n\n| Metric | Value |\n|---|---|\n"
        f"| Target | `{url}` |\n| Duration | {report['duration_s']} s |\n| Concurrency | {args.concurrency} |\n"
        f"| Requests | {total} |\n| Throughput | {report['throughput_rps']} req/s |\n"
        f"| Error rate | {report['error_rate_pct']} % |\n| Status codes | {report['status_codes']} |\n"
        f"| Latency p50 / p90 / p95 / p99 | {lm['p50']} / {lm['p90']} / {lm['p95']} / {lm['p99']} ms |\n"
        f"| Latency max | {lm['max']} ms |\n"
    )
    (out / f"{stem}.md").write_text(md)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
