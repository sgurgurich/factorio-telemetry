# factorio-telemetry

Factorio 2.0 / Space Age telemetry → Prometheus + Loki + Grafana, running on
Stefan's homelab k3d cluster.

## Components

- `mod/factorio-telemetry/` — Lua mod. `control.lua` builds a JSON snapshot,
  exposed via `remote.call("telemetry","snapshot")`. `settings.lua`,
  `info.json` (version — bump before every deploy).
- `exporter/` — Go RCON→Prometheus exporter + Loki pusher (`rcon.go`,
  `collector.go`, `loki.go`, `main.go`, `Dockerfile`).
- `deploy/` — `exporter.yaml`, `loki.yaml`, `dashboards/factorio-telemetry.json`,
  `deploy-mod.sh` (full mod release flow), `deploy-exporter.sh`,
  `stage_mods.py`, `publish_mod.py`, `rcon_cmd.py`.
- `build/build-mod.sh` — zips the mod.

Cluster: `factorio` ns (StatefulSet `factorio-default`, RCON
`factorio-default-rcon:27015`, exporter, dashboard CM); `monitoring` ns
(kube-prometheus-stack + our Loki). Mod is PUBLISHED on mods.factorio.com
(owner `theirontip`) so multiplayer clients auto-sync it.

## Deploy (run on the Mac Mini — `ssh ${DEPLOY_HOST}`)

`DEPLOY_HOST` = the cluster SSH target (the box with docker/k3d/kubectl + this
repo synced). Set it in your shell, e.g. `export DEPLOY_HOST=user@host`.

1. Bump `mod/factorio-telemetry/info.json` version.
2. `rsync -az --exclude .git --exclude dist ./ ${DEPLOY_HOST}:~/factorio-telemetry/`
3. `ssh ${DEPLOY_HOST} 'cd ~/factorio-telemetry && bash deploy/deploy-mod.sh'`
   - Idempotent. Publishes to portal FIRST, then save → stage → restart → verify.
   - Restart disconnects players ~1–2 min; they reconnect and the client
     auto-syncs the new version from the portal.
   - API key is in k8s secret `factorio-telemetry-publish` (factorio ns).
4. Dashboard-only changes: just refresh the CM (Grafana hot-reloads, no restart):
   `kubectl -n factorio create configmap factorio-telemetry-dashboard --from-file=factorio-telemetry.json=deploy/dashboards/factorio-telemetry.json --dry-run=client -o yaml | kubectl apply -f - && kubectl -n factorio label configmap factorio-telemetry-dashboard grafana_dashboard=1 --overwrite`

No local Lua linter — correctness rests on careful review + the deploy's
log-grep verify. A hotfix is one more `deploy-mod.sh` run.

---

# Dashboard rate window [5m]→[2m] — DEPLOYED 2026-05-17

Dashboard-only (ConfigMap hot-reload, no server restart). The 7
production/consumption/SPM panels (SPM, Item Prod/Cons, Net Item Production,
Science Consumed by Pack, Fluid Prod/Cons) dropped `rate(...[5m])` → `[2m]`
now that Task A's fast lane refreshes counters ~5s — more live, still smooth.
Power panels are unaffected (already on the 0.4.2 `*_watts` gauges, no rate()).
This is live in the cluster; the mod/exporter remain on 0.4.1.

# 0.4.4 — item quality split — IMPLEMENTED, NOT DEPLOYED

Splits item produced/consumed by quality (normal/uncommon/rare/epic/
legendary). Factorio's lifetime counter `LuaFlowStatistics.input_counts`
is NOT keyed by quality, so `control.lua` fetches per-quality via
`get_input_count/get_output_count(name, quality)` and emits the uniform
nested schema `items.produced = { item = { quality = count } }`
(`wrap_normal()` for the off/non-SpaceAge path so the schema is
unconditional). FEASIBILITY UNKNOWN, handled defensively: the exact
quality-arg API shape is unverified — `split_by_quality()` tries positional
then table-arg forms in pcall and only publishes the split if it
RECONCILES with the trusted aggregate counter (sum ≈ total, 0.5% tol);
otherwise it falls back to `{normal=total}` (numbers identical to today)
and `log()`s a one-time warning. So a wrong API guess CANNOT publish bad
data — it just behaves like pre-0.4.4. New mod bool-setting
`factorio-telemetry-quality-split` (default true) is the in-game perf
kill-switch (mirrors `-logistics`; per-(item×quality) lookups land in the
stutter-sensitive FAST lane — MUST do the in-game "play a minute, zero
stutter" check on the megabase before trusting it). Exporter:
`factorio_item_produced_total` / `_consumed_total` gain a `quality` label.
Dashboard: new custom var `group` (`By quality`→`item, quality` default /
`Combined`→`item`); Item Production Rate, Item Consumption Rate, Net Item
Production repointed to `sum by (${group})` + legend `{{item}} {{quality}}`.
Scope is items only — fluids, logistic stock, Science-Consumed-by-Pack
deliberately unchanged. Mod 0.4.4, exporter image 0.4.4. Ships with the
rest of the gated 0.4.x bundle (PR → deploy-safe auto-applies exporter+
dashboard, then manual deploy-mod for the mod/server restart). Post-deploy
verify: in-game log has NO "quality-split ... reporting as normal" warning,
and the dashboard "Group by" toggle actually breaks out qualities.

# 0.4.3 — probe signal type label — IMPLEMENTED, NOT DEPLOYED

Fix for "probe Accumulator Charge panel is inaccurate and shows logistics
items too" (one speaker wired to power + accumulator + a roboport reading
logistics). Root cause: the mod keyed probe circuit signals only by name and
the exporter emitted `factorio_probe_signal{probe,surface,signal}` with no
signal class, so the Accumulator panel (no signal filter) plotted every wire
signal including all logistics items, with no attribute to isolate the
accumulator's *virtual* charge signal. (The multi-accumulator "sum" is
inherent circuit-network behaviour, not a code bug — documented for the user.)
Fix: `control.lua` now stores each probe signal as
`{ type = s.signal.type or "item", count = ... }` (type nil = plain item);
exporter `probe` struct gains `probeSignal{Type,Count}`, the `probe_signal`
desc gains a `type` label, Collect passes `ps.Type`. Dashboard: Accumulator
panel query → `factorio_probe_signal{probe=~"$probe", type="virtual"}`, Wired
Signals table → `type="item"` (and the `type` column excluded in the organize
transform). Mod 0.4.3, exporter image 0.4.3. Deploy = same bundle as the
other pending 0.4.x work: `deploy-mod.sh` (restart) + exporter rebuild +
dashboard CM. Verify in-game: with a speaker wired to an accumulator + a
roboport, the Accumulator panel shows only the charge signal and Wired
Signals shows only logistics items.

# 0.4.2 — power via get_flow_count — IMPLEMENTED, NOT DEPLOYED

Fix for "probe power graphs don't match in-game / wrong shape". Root cause:
`rate()` of the cumulative `electric_network_statistics` joules counter aliases
badly (mod updates ~5s, exporter cache ~3s, Prometheus scrape 15s beat against
each other → sawtooth). Counter itself is fine/monotonic. Fix: the mod now
also reports instantaneous power via Factorio's own smoothed
`LuaFlowStatistics.get_flow_count{precision_index=one_minute}` (per-tick for
electric → *60 = W) — the same data the in-game electric graph shows. New
JSON fields `electric.produced_w/consumed_w` (per-surface, slow lane) and
`probes[].electric.produced_w/consumed_w`. Exporter exposes GAUGES
`factorio_electric_power_produced_watts{surface}` / `_consumed_watts` and
`factorio_probe_power_produced_watts{probe,surface}` / `_consumed_watts`
(cumulative joules counters kept too). Dashboard power + satisfaction panels
repointed to the gauges (no rate()). Mod 0.4.2, exporter image 0.4.2.
Item/fluid production still uses rate() (left as a possible follow-up).
Deploy = `deploy-mod.sh` (restart) + exporter rebuild + dashboard CM. Verify
in-game: probe/surface power should match the in-game electric-network number
and be smooth.

# Task A — fast/slow snapshot split — IMPLEMENTED in 0.3.1, NOT YET DEPLOYED

Status: `mod/factorio-telemetry/control.lua` was rewritten to the two-lane
design below and `info.json` bumped to **0.3.1**. It has NOT been deployed —
players were on the server. To ship it (server should ideally be quiet; the
restart kicks players ~1–2 min, client auto-resyncs from the portal):

    rsync -az --exclude .git --exclude dist ./ ${DEPLOY_HOST}:~/factorio-telemetry/
    ssh ${DEPLOY_HOST} 'cd ~/factorio-telemetry && bash deploy/deploy-mod.sh'

Then verify: with a player online read the snapshot twice ~8s apart — items
produced/consumed + `tick` should advance every ~5s (fast lane), not only per
slow pass; play a minute to confirm zero stutter; check Grafana SPM tracks
in-game closely. Post-deploy follow-up (dashboard-only, no restart): now that
counters refresh ~5s, drop the SPM / item-prod / item-cons / net rate windows
from `[5m]` to `[2m]` (or `[1m]`) for a near-live reading, then re-apply the
dashboard CM.

No local Lua linter was available — correctness rests on review; the deploy's
log-grep verify will catch a load error and a hotfix is one more deploy-mod.sh.

# Task B — Programmable-Speaker probes — IMPLEMENTED in 0.4.0, NOT DEPLOYED

Player-curated probes via the vanilla **Programmable Speaker** (no new
entity/item/data-stage, no scanning). Built on top of the 0.3.1 fast/slow
lanes; 0.4.0 also contains everything from 0.3.1 (so deploying 0.4.0 ships
both at once).

How it works:
- Engine entity GUIs can't be modified, so a `gui.relative` frame is anchored
  to `defines.relative_gui_type.programmable_speaker_gui` — a "Connect to
  Telemetry" checkbox (off by default) + a label textfield appear attached to
  the speaker GUI whenever one is opened.
- Ticking it registers that speaker in `storage.probes[unit_number] =
  {e=LuaEntity, label}`. Registry is purely GUI/event driven — no map scan.
  Invalids are cleaned lazily in `read_probes()`.
- Each fast tick `read_probes()` reads, per probe: `electric_network_statistics`
  (the network the speaker is powered from → produced/consumed J) and all
  circuit signals on its red/green wires (`get_circuit_network(...).signals`)
  — e.g. a roboport set to read logistics/robot-stats, or an accumulator's
  charge, wired into the speaker. Added to the snapshot as `snap.probes[label]`.
- Exporter: `factorio_probe_electric_produced_joules_total{probe,surface}`,
  `..._consumed_...`, `factorio_probe_signal{probe,surface,signal}`.
- Dashboard: `probe` template variable + "Probe — Network Power" and
  "Probe — Wired Signals" panels (deploy the dashboard CM whenever; harmless
  before the mod — panels just show no data).

Deploy = same one command as Task A (`deploy-mod.sh`, publishes 0.4.0 then
restarts). Risks to verify in-game after deploy: the `relative_gui_type`/
`relative_gui_position` define names (frame won't show if wrong — non-fatal),
and `get_circuit_network`/`electric_network_statistics` on the speaker. The
slow chunk-stepper is kept as the global/fallback electric+logistics source;
probes are the high-frequency, player-chosen overlay.

## Original plan (for reference)

## Why

v0.3.0 replaced the old one-shot scan (which froze megabases ~1s every 5s)
with a single incremental chunk stepper. That killed the stutter, but the
WHOLE snapshot now only refreshes once per full pass (tens of seconds on the
24-surface megabase). So fast-changing rates (SPM, production/consumption) are
under-resolved — only a ≥5-min Prometheus rate window is stable, and the
Grafana SPM reads far below the live in-game number.

Key insight: the stutter was ONLY from entity scans
(`find_entities_filtered` for electric-pole/accumulator) and logistic
`get_contents()`. The production/fluid/research/pollution/evolution calls are
cheap dictionary/scalar reads and are safe to do for all surfaces every ~5s.

## Goal

Production / consumption / science / research / players / events update every
~5s (near real-time, matches in-game closely) WITHOUT reintroducing stutter.
Electric / accumulator / logistics stay on the incremental stepper.

## Design (control.lua refactor, bump info.json → 0.3.1)

- **Fast lane** — `on_nth_tick(get_interval())` (reuse the
  `factorio-telemetry-sample-interval` setting, default 300 = 5s). Each fire:
  for every surface compute the CHEAP fields only — items produced/consumed
  (`force.get_item_production_statistics(surface).input_counts/output_counts`,
  filtered), fluids (same for fluids), `surface.get_total_pollution()`,
  `enemy.get_evolution_factor(surface)`, rockets, plus top-level research /
  players / `event_counts` / `events_recent`. Merge in the latest slow-lane
  cache per surface (electric, logistics, alerts). `helpers.table_to_json` →
  `storage.snapshot_json`. This is now the served value and is fresh every ~5s.
  - Cost check: ~24 surfaces × a few hundred item entries + one JSON encode
    every 5s = low ms, no entity scans → no stutter. Fine.
- **Slow lane** — keep the existing chunk-sliced stepper (state machine), but
  it no longer serializes the whole snapshot. It writes results into a cache:
  `storage.slow[surfacename] = { electric = {...}, logistics = {...} }` and
  `storage.slow_alerts[surfacename] = {...}`. Update in place when each pass
  completes; the fast lane reads whatever is currently cached (stale
  electric/logistics between slow passes is acceptable — they change slowly).
- Keep `SNAPSHOT_VERSION = 2` and the exact JSON schema (per-surface
  `items/fluids/electric/logistics/alerts`, top-level
  `event_counts/events_recent`) so the exporter and dashboard need NO changes.
- Settings unchanged. Tunables: fast period = the existing interval setting;
  slow `STEP_TICKS` / `CHUNKS_PER_STEP` constants at top of control.lua.

## Gotchas to PRESERVE (already learned — do not re-litigate)

- auto_pause: empty server → ticks frozen → `on_nth_tick` won't fire → served
  snapshot stays frozen at last completed. This is INTENDED (honest flatline).
  Do NOT add on-demand-rebuild-when-empty — it caused observer-effect jitter
  (RCON steps a paused server ~1 tick) and was deliberately reverted in 0.2.3.
- `helpers.table_to_json` serializes an empty Lua table as `{}` not `[]`;
  exporter has a custom `eventList` unmarshaller. Keep `events_recent` an
  array-shaped table.
- Never do a synchronous full entity scan (the whole reason 0.3.0 exists).
- `on_load` must not touch game state — only re-register `on_nth_tick`.
- Mod settings can't be set via RCON (only admin in-game GUI / the mod).
- RCON `/server-save` may time out while paused; the factoriotools image
  saves on SIGTERM, so `deploy-mod.sh`'s restart is safe — don't treat the
  save timeout as data loss (verify `_autosave1.zip` mtime if unsure).
- Factorio RCON: one response packet, ignores empty sentinel commands. The
  exporter's `rcon.go` reads a single response — do NOT reintroduce the Valve
  multi-packet trick.
- Multiplayer: deploy-mod.sh builds the zip ONCE and uses it for both the
  server PVC and the portal upload so client/server checksums match; it
  publishes to the portal BEFORE restarting so a connected client can resync.

## After deploy — verify

1. With a player online, read the snapshot twice ~8s apart:
   `remote.call("telemetry","snapshot")` — item produced/consumed counters and
   `tick` should advance every fast tick (~5s), NOT only per slow pass.
2. Play for a minute — confirm zero stutter.
3. Confirm Grafana SPM tracks the in-game number much more closely.
4. Counters now step every ~5s, so short Prometheus rate windows are valid
   again — consider editing the dashboard SPM / item prod / item cons / fluid
   panels from `[5m]` to `[2m]` for a more "live" feel, then redeploy the
   dashboard CM (no server restart).

## SPM metric (resolved)

The Grafana "Science / min (SPM)" stat uses
`sum(rate(factorio_item_produced_total{item=~"science"}[5m])) * 60`. Factorio
emits a single aggregate `item="science"` series in production stats that
equals research throughput and matches the in-game SPM number. Do NOT go back
to summing `*-science-pack` consumption (that overcounts and is skewed by
agricultural spoilage). Once Task A's fast lane lands, the counter refreshes
~5s so the SPM/prod/cons rate windows can drop from `[5m]` to `[2m]` for a
more live reading.
