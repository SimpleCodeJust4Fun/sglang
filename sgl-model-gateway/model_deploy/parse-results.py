#!/usr/bin/env python3
import json
import glob
import os

results_dir = "/mnt/e/dev/sglang/sgl-model-gateway/model_deploy/benchmark-results"
files = sorted(glob.glob(os.path.join(results_dir, "*.jsonl")))

print("=" * 100)
print(f"{'File':<55} {'TTFT Mean':>10} {'TTFT Med':>10} {'TTFT P99':>10} {'TPOT':>8} {'Tok/s':>10} {'Success':>10}")
print("=" * 100)

for f in files:
    fname = os.path.basename(f).replace("bench_", "").replace(".jsonl", "")
    try:
        data = json.load(open(f))
        ttft_mean = data.get("mean_ttft_ms", 0)
        ttft_med = data.get("median_ttft_ms", 0)
        ttft_p99 = data.get("p99_ttft_ms", 0)
        tpot = data.get("mean_tpot_ms", 0)
        throughput = data.get("total_throughput", 0)
        completed = data.get("completed", 0)
        print(f"{fname:<55} {ttft_mean:>9.0f}ms {ttft_med:>9.0f}ms {ttft_p99:>9.0f}ms {tpot:>7.2f}ms {throughput:>9.0f} {completed:>6}/50")
    except Exception as e:
        print(f"{fname:<55} ERROR: {e}")

print("=" * 100)
