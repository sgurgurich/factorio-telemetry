import json
import urllib.parse
import urllib.request

B = "http://monitoring-kube-prometheus-prometheus:9090/api/v1/query"


def q(expr):
    url = B + "?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)["data"]["result"]


print("=== factorio_probe_info series ===")
for r in q("factorio_probe_info"):
    print(" ", r["metric"])

print("=== produced counter (instant) ===")
for r in q("factorio_probe_electric_produced_joules_total"):
    print(" ", r["metric"].get("probe"), r["metric"].get("surface"), r["value"][1])

print("=== produced rate[5m] (W) for fulgora-main-power ===")
res = q('rate(factorio_probe_electric_produced_joules_total{probe="fulgora-main-power"}[5m])')
print("  results:", len(res), [x["value"][1] for x in res])

print("=== produced rate[2m] ===")
res = q('rate(factorio_probe_electric_produced_joules_total{probe="fulgora-main-power"}[2m])')
print("  results:", len(res), [x["value"][1] for x in res])

print("=== surface label values (surface var) ===")
print("  ", sorted(r["metric"]["surface"] for r in q("group by (surface)(factorio_surface_pollution)")))
