# Factorio Telemetry

Stream a Factorio **2.0 / Space Age** server's production, power, logistics,
alerts, and game events into **Prometheus + Loki + Grafana** — so you can watch
your factory from anywhere, live, with history.

**Mod page:** https://mods.factorio.com/mod/factorio-telemetry

It's read‑only (no gameplay changes) and multiplayer‑safe — the mod is on the
Factorio Mod Portal, so connected clients auto‑sync it like any other mod.

---

## What you get

- **Production / consumption / SPM** — per‑item and per‑fluid rates, net
  surplus/deficit, and a science‑per‑minute (research throughput) KPI.
- **Power** — per‑surface generation/consumption, satisfaction, and
  per‑network power via player‑placed probes (see below).
- **Logistics** — logistic‑network item stock and bot availability.
- **Game state** — pollution, evolution, research progress, players online,
  rockets launched.
- **Events log** — chat, deaths, joins/leaves, research, rockets, and biter
  losses streamed to Loki and viewable as logs in Grafana.
- **Probes** — tick a **"Connect to Telemetry"** checkbox on any in‑game
  **Programmable Speaker** to track exactly the network you care about: its
  electric flow, plus anything you wire into it (a roboport's *read logistics*
  → every item + count, an accumulator's charge, any combinator output).
- A ready‑made Grafana dashboard with searchable item/probe pickers and a
  per‑minute / per‑second toggle.

## How it works

Factorio mods are sandboxed Lua — they can't open sockets. So:

```
Factorio server (mod: factorio-telemetry)
  │  builds a JSON snapshot:
  │   • FAST lane (~5s): production/fluids/science/research/events  — cheap, no scans
  │   • SLOW lane (incremental, time-sliced): electric / accumulators / logistics
  │   • PROBES: player-tagged speakers, read every fast tick
  ▼  RCON   remote.call("telemetry","snapshot")
Exporter (Go)
  │  scrapes via RCON → Prometheus metrics on /metrics
  │  pushes recent game events → Loki   (also a JSON /events endpoint)
  ▼
Prometheus + Loki ──► Grafana ("Factorio Telemetry" dashboard)
```

The mod builds its snapshot incrementally across ticks so it never stalls the
game, even on a multi‑surface megabase.

## Repository layout

| Path | What |
|---|---|
| `mod/factorio-telemetry/` | The Lua mod (`control.lua`, `settings.lua`, `info.json`). |
| `exporter/` | Go RCON→Prometheus exporter + Loki event pusher. |
| `deploy/exporter.yaml` | Exporter Deployment + Service + ServiceMonitor. |
| `deploy/loki.yaml` | Single‑binary Loki + Grafana datasource. |
| `deploy/dashboards/` | The Grafana dashboard JSON. |
| `deploy/deploy-mod.sh` | One‑command release: build → publish → stage → restart → verify. |
| `deploy/publish-mod.sh`, `publish_mod.py` | Mod Portal upload helpers. |
| `build/build-mod.sh` | Packages the mod into a portal‑ready zip. |
| `CLAUDE.md` | Operational notes, deploy steps, design decisions. |

## Quick start

**Use the mod:** install **[factorio-telemetry](https://mods.factorio.com/mod/factorio-telemetry)**
from the Mod Portal on your server (clients auto‑sync). Settings: snapshot
interval, item allow‑list, logistics on/off.

**Read the data out:** point the exporter at your server's RCON
(`RCON_ADDR`, `RCON_PASSWORD`), scrape `/metrics` with Prometheus, and
(optionally) set `LOKI_URL` to ship the event log to Loki. Import the dashboard
in `deploy/dashboards/`.

This repo's `deploy/` targets a k3d homelab (Prometheus Operator + Grafana);
the deploy host is parameterized via `DEPLOY_HOST`. See `CLAUDE.md` for the
exact flow. The exporter is plain Prometheus/Loki, so it adapts to any setup.

## Probes (the fun part)

Open any **Programmable Speaker** in‑game → tick **"Connect to Telemetry"** →
name it. The mod then reads, every few seconds:

- the **electric network** the speaker is powered from (produced/consumed W);
- every **circuit signal** wired into the speaker.

So wire a **roboport** (enable *read logistics* / *read robot statistics*) for
a live searchable table of every item in that network; wire an **accumulator**
for its charge %; or wire any combinator output you want on a graph. No map
scanning — you choose exactly what's tracked.

## Key metrics

`factorio_up`, `factorio_players_online`, `factorio_research_progress`,
`factorio_surface_pollution`, `factorio_evolution_factor`,
`factorio_item_produced_total` / `factorio_item_consumed_total`,
`factorio_fluid_produced_total` / `_consumed_total`,
`factorio_electric_energy_produced_joules_total` / `_consumed_total`,
`factorio_accumulator_charge_joules` / `_capacity_joules`,
`factorio_logistic_item_count`, `factorio_logistic_robots_*`,
`factorio_active_alerts`, `factorio_events_total`,
`factorio_probe_info`, `factorio_probe_electric_*_joules_total`,
`factorio_probe_signal`. Events also stream to Loki under
`{job="factorio-telemetry"}`.

## License

MIT — see `LICENSE`.
