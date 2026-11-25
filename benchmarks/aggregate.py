#!/usr/bin/env python3
"""Aggregate k6 summary-export JSONs into per-operation, per-level tables plus a CSV.

Input : results/<stack>-<op>-vus<level>-rep<n>.json
Output: aggregated.csv (and charts/<op>_<metric>.png if matplotlib is installed)
Run   : python3 aggregate.py [results_dir]
"""
import sys, os, re, json, glob, statistics as st
from collections import defaultdict

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results"
NAME_RE = re.compile(r"(?P<stack>[a-zA-Z]+)-(?P<op>[a-zA-Z]+)-vus(?P<vus>\d+)-rep(?P<rep>\d+)\.json$")
METRICS = ("throughput", "p95_ms", "mean_ms", "fail_rate")


def extract(path):
    with open(path) as fh:
        m = json.load(fh).get("metrics", {})
    dur = m.get("http_req_duration", {})
    return {
        "throughput": m.get("http_reqs", {}).get("rate", 0.0),
        "mean_ms": dur.get("avg", 0.0),
        "p95_ms": dur.get("p(95)", dur.get("p95", 0.0)),
        "fail_rate": m.get("http_req_failed", {}).get("value", 0.0) * 100.0,
    }


def ms(vals):
    return st.mean(vals), (st.stdev(vals) if len(vals) > 1 else 0.0)


def main():
    files = sorted(glob.glob(os.path.join(RESULTS, "*.json")))
    if not files:
        sys.exit(f"No JSON summaries found in {RESULTS}/")

    groups = defaultdict(lambda: defaultdict(list))
    for f in files:
        mo = NAME_RE.search(os.path.basename(f))
        if not mo:
            print(f"  skip (name): {f}")
            continue
        key = (mo["stack"].lower(), mo["op"].lower(), int(mo["vus"]))
        for k, v in extract(f).items():
            groups[key][k].append(v)

    rows = []
    for (stack, op, vus) in sorted(groups):
        g = groups[(stack, op, vus)]
        r = {"op": op, "stack": stack, "vus": vus, "reps": len(g["throughput"])}
        for k in METRICS:
            r[k + "_mean"], r[k + "_sd"] = ms(g[k])
        rows.append(r)

    ops = sorted({r["op"] for r in rows})
    stacks = sorted({r["stack"] for r in rows})

    for op in ops:
        print(f"\n=== OPERATION: {op} ===")
        print(f"{'stack':>6} {'VUs':>6} {'n':>3} {'throughput req/s':>22} {'p95 ms':>14} {'mean ms':>14} {'fail %':>10}")
        for r in sorted([x for x in rows if x["op"] == op], key=lambda r: (r["stack"], r["vus"])):
            print(f"{r['stack']:>6} {r['vus']:>6} {r['reps']:>3} "
                  f"{r['throughput_mean']:>10.0f} ± {r['throughput_sd']:>7.0f} "
                  f"{r['p95_ms_mean']:>7.0f} ± {r['p95_ms_sd']:>4.0f} "
                  f"{r['mean_ms_mean']:>7.0f} ± {r['mean_ms_sd']:>4.0f} "
                  f"{r['fail_rate_mean']:>6.2f} ± {r['fail_rate_sd']:>4.2f}")


    import csv
    cols = ["op", "stack", "vus", "reps"]
    for k in METRICS:
        cols += [k + "_mean", k + "_sd"]
    with open("aggregated.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow({c: r[c] for c in cols})
    print("\nWrote aggregated.csv")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        print("matplotlib not installed, skipping charts (CSV still written). Run pip3 install matplotlib for PNGs.")
        return

    os.makedirs("charts", exist_ok=True)
    labels = {
        "throughput": ("Throughput (req/s)", "throughput"),
        "p95_ms": ("p95 latency (ms)", "p95"),
        "fail_rate": ("Failure rate (%)", "failrate"),
    }
    for op in ops:
        for metric, (ylabel, short) in labels.items():
            plt.figure(figsize=(7, 4.5))
            plotted = False
            for s in stacks:
                pts = sorted([r for r in rows if r["op"] == op and r["stack"] == s], key=lambda r: r["vus"])
                if not pts:
                    continue
                xs = [r["vus"] for r in pts]
                ys = [r[metric + "_mean"] for r in pts]
                es = [r[metric + "_sd"] for r in pts]
                plt.errorbar(xs, ys, yerr=es, marker="o", capsize=3, label=s.upper())
                plotted = True
            if not plotted:
                plt.close(); continue
            plt.xlabel("Concurrent virtual users")
            plt.ylabel(ylabel)
            plt.title(f"{op}: {ylabel}")
            plt.legend(); plt.grid(True, alpha=0.3); plt.tight_layout()
            plt.savefig(os.path.join("charts", f"{op}_{short}.png"), dpi=130)
            plt.close()
    print(f"Wrote charts/ ({len(ops)} ops x 3 metrics)")


if __name__ == "__main__":
    main()
