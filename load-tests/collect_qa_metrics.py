#!/usr/bin/env python3
"""Collect server-side numbers for a load-test window from QA (read-only) and write them as JSON.

  python3 load-tests/collect_qa_metrics.py <label> <start_epoch_seconds> <end_epoch_seconds>

Reads: Prometheus (through SSM on the QA box: HikariCP pool use, CPU, JVM threads, request rate, Tomcat
busy threads when the service exposes them) and CloudWatch for the RDS instance (connections, CPU, CPU
credits). Needs the AWS CLI with SSM + CloudWatch read access. Never writes to the cluster or the database.
"""
import json, subprocess, sys, time, datetime, os

INSTANCE, REGION, PROM = "i-0285595f45e8d9f7d", "eu-west-1", "http://10.43.15.207:9091"
DB_ID = "landers-db"

def ssm(script):
    cmd = "sudo -iu ubuntu bash <<'EOS'\n" + script + "\nEOS"
    p = json.dumps({"commands": [cmd]})
    cid = subprocess.check_output(["aws", "ssm", "send-command", "--region", REGION, "--instance-ids", INSTANCE,
        "--document-name", "AWS-RunShellScript", "--parameters", p, "--query", "Command.CommandId", "--output", "text"], text=True).strip()
    while True:
        st = subprocess.check_output(["aws", "ssm", "get-command-invocation", "--region", REGION, "--command-id", cid,
            "--instance-id", INSTANCE, "--query", "Status", "--output", "text"], text=True).strip()
        if st != "InProgress": break
        time.sleep(2)
    return subprocess.check_output(["aws", "ssm", "get-command-invocation", "--region", REGION, "--command-id", cid,
        "--instance-id", INSTANCE, "--query", "StandardOutputContent", "--output", "text"], text=True)

def main():
    label, start, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    w = max(30, end - start)
    # PromQL evaluated at the end of the window, looking back over it. By application (and pool where relevant).
    q = {
      "hikari_active_max":   f"max by (application) (max_over_time(hikaricp_connections_active[{w}s]))",
      "hikari_pending_max":  f"max by (application) (max_over_time(hikaricp_connections_pending[{w}s]))",
      "hikari_pool_max":     "max by (application) (hikaricp_connections_max)",
      "hikari_timeouts":     f"sum by (application) (increase(hikaricp_connections_timeout_total[{w}s]))",
      "hikari_acquire_avg_ms": f"1000 * sum by (application) (rate(hikaricp_connections_acquire_seconds_sum[{w}s])) / sum by (application) (rate(hikaricp_connections_acquire_seconds_count[{w}s]))",
      "cpu_avg":             f"avg by (application) (avg_over_time(process_cpu_usage[{w}s]))",
      "cpu_max":             f"max by (application) (max_over_time(process_cpu_usage[{w}s]))",
      "jvm_threads_max":     f"max by (application) (max_over_time(jvm_threads_live_threads[{w}s]))",
      "heap_used_max_mb":    f"max by (application) (max_over_time(jvm_memory_used_bytes{{area=\"heap\"}}[{w}s])) / 1048576",
      "gc_pause_seconds":    f"sum by (application) (increase(jvm_gc_pause_seconds_sum[{w}s]))",
      "tomcat_busy_max":     f"max by (application) (max_over_time(tomcat_threads_busy_threads[{w}s]))",
      "http_req_per_s":      f"sum by (application) (rate(http_server_requests_seconds_count{{uri!~\".*stream.*\"}}[{w}s]))",
      "http_avg_latency_ms": f"1000 * sum by (application) (rate(http_server_requests_seconds_sum[{w}s])) / sum by (application) (rate(http_server_requests_seconds_count{{uri!~\".*stream.*\"}}[{w}s]))",
      "http_5xx":            f"sum by (application) (increase(http_server_requests_seconds_count{{status=~\"5..\"}}[{w}s]))",
    }
    lines = ["import json,urllib.parse,urllib.request", f"end={end}", "out={}"]
    lines.append("def q(e):\n  u='%s/api/v1/query?'+urllib.parse.urlencode({'query':e,'time':end})\n  return json.load(urllib.request.urlopen(u,timeout=20))" % PROM)
    for k, e in q.items():
        lines.append(f"out[{k!r}]=q({e!r})")
    lines.append("print(json.dumps(out))")
    py = "\n".join(lines)
    raw = ssm("python3 - <<'PY'\n" + py + "\nPY")
    prom = json.loads(raw.strip().splitlines()[-1])
    summary = {}
    for k, v in prom.items():
        summary[k] = {r["metric"].get("application", "?"): round(float(r["value"][1]), 3)
                      for r in v["data"]["result"] if r["value"][1] not in ("NaN", "+Inf")}
    cw = {}
    fmt = lambda t: datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for metric, stats in (("DatabaseConnections", "Average Maximum"), ("CPUUtilization", "Average Maximum"), ("CPUCreditBalance", "Minimum")):
        out = subprocess.check_output(["aws", "cloudwatch", "get-metric-statistics", "--region", REGION, "--namespace", "AWS/RDS",
            "--metric-name", metric, "--dimensions", f"Name=DBInstanceIdentifier,Value={DB_ID}", "--start-time", fmt(start - 60),
            "--end-time", fmt(end + 60), "--period", "60", "--statistics", *stats.split(), "--output", "json"], text=True)
        pts = json.loads(out)["Datapoints"]
        cw[metric] = {s: (round((max if s != "Minimum" else min)(p[s] for p in pts), 2) if pts else None) for s in stats.split()}
    res = {"label": label, "window": [fmt(start), fmt(end)], "prometheus": summary, "rds": cw}
    os.makedirs(os.path.join(os.path.dirname(__file__), "results"), exist_ok=True)
    path = os.path.join(os.path.dirname(__file__), "results", f"{label}-server-metrics.json")
    json.dump(res, open(path, "w"), indent=2, sort_keys=True)
    print("wrote", path)

if __name__ == "__main__":
    main()
