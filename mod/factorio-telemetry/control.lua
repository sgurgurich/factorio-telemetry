-- factorio-telemetry
--
-- Two-lane snapshot builder:
--
--  * FAST lane (on_nth_tick = the sample-interval setting, default 5s):
--    cheap, no entity scans — production/consumption/fluids/pollution/
--    evolution/research/players/events. Rebuilds the served JSON every tick,
--    merging in the most recent SLOW-lane cache. This is what makes SPM and
--    production rates fresh/responsive.
--
--  * SLOW lane (incremental chunk stepper, a few chunks/tick): the expensive
--    bits — per-network electric stats, accumulator charge, logistic-network
--    contents, alerts. Time-sliced so no tick ever stalls (the megabase
--    anti-stutter design). Writes results into storage.slow{,_alerts}; never
--    serialises the snapshot itself.
--
-- Served over RCON: /silent-command rcon.print(remote.call("telemetry","snapshot"))

local SNAPSHOT_VERSION = 2
local REPORTED_FORCE = "player"
local EVENT_BUFFER = 50

-- SLOW-lane tuning. STEP_TICKS: stepper cadence (4 = ~15x/sec).
-- CHUNKS_PER_STEP: chunk cells scanned per step (bounds per-tick cost).
local STEP_TICKS = 4
local CHUNKS_PER_STEP = 24

-- Fallback fast period if storage has none yet (ticks). Real value comes from
-- the factorio-telemetry-sample-interval setting (min 60 = 1s).
local DEFAULT_FAST_PERIOD = 300

-- Player-curated probes: a "Connect to Telemetry" checkbox is anchored to the
-- vanilla Programmable Speaker GUI (engine GUIs can't be modified directly, so
-- this uses gui.relative anchored to programmable_speaker_gui). A ticked
-- speaker is read every fast tick — its electric_network_statistics (the
-- network it's powered from) plus any circuit signals wired into it (e.g. a
-- roboport set to read logistics/robot stats, or an accumulator's charge).
-- O(#probes), no scanning.
local PROBE_FRAME = "ftel-probe-frame"
local PROBE_ENABLE = "ftel-probe-enable"
local PROBE_LABEL = "ftel-probe-label"
local SPEAKER_NAME = "programmable-speaker"

local alert_type_name

local function ensure_alert_map()
  if alert_type_name then
    return
  end
  alert_type_name = {}
  for name, value in pairs(defines.alert_type) do
    alert_type_name[value] = name
  end
end

local function get_interval()
  return settings.global["factorio-telemetry-sample-interval"].value
end

local function logistics_enabled()
  return settings.global["factorio-telemetry-logistics"].value
end

local function get_allowlist()
  local raw = settings.global["factorio-telemetry-item-allowlist"].value
  if not raw or raw == "" then
    return nil
  end
  local set = {}
  for token in string.gmatch(raw, "([^,]+)") do
    local name = token:match("^%s*(.-)%s*$")
    if name ~= "" then
      set[name] = true
    end
  end
  return set
end

local function filtered_counts(counts, allow)
  local out = {}
  for name, value in pairs(counts) do
    if value ~= 0 and (allow == nil or allow[name]) then
      out[name] = value
    end
  end
  return out
end

local function player_name(index)
  local p = index and game.get_player(index)
  return p and p.name or "?"
end

local function push_event(kind, msg, who)
  local buf = storage.events
  storage.event_seq = (storage.event_seq or 0) + 1
  buf[#buf + 1] = {
    seq = storage.event_seq,
    t = game.tick,
    kind = kind,
    who = who or "",
    msg = msg and string.sub(msg, 1, 200) or "",
  }
  while #buf > EVENT_BUFFER do
    table.remove(buf, 1)
  end
end

-- Max alert count per (surface name, alert type) across players.
local function collect_alerts()
  ensure_alert_map()
  local idx2name = {}
  for _, s in pairs(game.surfaces) do
    idx2name[s.index] = s.name
  end
  local by_surface = {}
  for _, player in pairs(game.players) do
    local ok, res = pcall(function()
      return player.get_alerts({})
    end)
    if ok and res then
      for sidx, by_type in pairs(res) do
        local sname = idx2name[sidx]
        if sname then
          local acc = by_surface[sname] or {}
          for atype, list in pairs(by_type) do
            local tn = alert_type_name[atype] or tostring(atype)
            if (acc[tn] or 0) < #list then
              acc[tn] = #list
            end
          end
          by_surface[sname] = acc
        end
      end
    end
  end
  return by_surface
end

-- ---------------------------------------------------------------------------
-- SLOW lane: incremental electric/accumulator scan + logistics + alerts.
-- State in storage.b; results accumulate in b.result / b.result_alerts and
-- are swapped into storage.slow / storage.slow_alerts only when a full pass
-- completes (the served snapshot always sees a consistent set).
-- ---------------------------------------------------------------------------

local function begin_slow_pass()
  local names = {}
  for _, s in pairs(game.surfaces) do
    names[#names + 1] = s.name
  end
  storage.b = {
    phase = "scan_init",
    surfaces = names,
    si = 1,
    result = {},
    result_alerts = {},
  }
end

local function slow_next_surface(b)
  b.si = b.si + 1
  b.scan = nil
  if b.si > #b.surfaces then
    b.phase = "alerts"
  else
    b.phase = "scan_init"
  end
end

local function do_scan_init(b)
  local sname = b.surfaces[b.si]
  local surface = game.get_surface(sname)
  if not (surface and surface.valid) then
    slow_next_surface(b)
    return
  end
  -- Chunk bounding box (coords only — no entity work).
  local minx, miny, maxx, maxy
  for c in surface.get_chunks() do
    if not minx then
      minx, maxx, miny, maxy = c.x, c.x, c.y, c.y
    else
      if c.x < minx then minx = c.x end
      if c.x > maxx then maxx = c.x end
      if c.y < miny then miny = c.y end
      if c.y > maxy then maxy = c.y end
    end
  end
  b.scan = {
    minx = minx, maxx = maxx, miny = miny, maxy = maxy,
    cx = minx, cy = miny,
    e_in = 0.0, e_out = 0.0, nets = 0,
    acc_c = 0.0, acc_cap = 0.0,
    seen_net = {}, seen_acc = {},
    done = (minx == nil),
  }
  b.phase = "scan"
end

local function do_scan(b)
  local sname = b.surfaces[b.si]
  local surface = game.get_surface(sname)
  local sc = b.scan
  if not (surface and surface.valid) or sc.done then
    b.result[sname] = b.result[sname] or {}
    b.result[sname].electric = {
      produced_j = sc.e_in,
      consumed_j = sc.e_out,
      networks = sc.nets,
      accumulator_charge_j = sc.acc_c,
      accumulator_capacity_j = sc.acc_cap,
    }
    b.phase = "logi"
    return
  end

  -- Bounded number of chunk cells per step (generated or not).
  for _ = 1, CHUNKS_PER_STEP do
    local cx, cy = sc.cx, sc.cy
    if surface.is_chunk_generated({ x = cx, y = cy }) then
      local ents = surface.find_entities_filtered({
        area = { { cx * 32, cy * 32 }, { cx * 32 + 32, cy * 32 + 32 } },
        type = { "electric-pole", "accumulator" },
      })
      for _, e in pairs(ents) do
        if e.valid then
          if e.type == "electric-pole" then
            local nid = e.electric_network_id
            if nid and not sc.seen_net[nid] then
              sc.seen_net[nid] = true
              sc.nets = sc.nets + 1
              local st = e.electric_network_statistics
              for _, v in pairs(st.input_counts) do
                sc.e_in = sc.e_in + v
              end
              for _, v in pairs(st.output_counts) do
                sc.e_out = sc.e_out + v
              end
            end
          else -- accumulator
            local un = e.unit_number
            if un and not sc.seen_acc[un] then
              sc.seen_acc[un] = true
              sc.acc_c = sc.acc_c + (e.energy or 0)
              sc.acc_cap = sc.acc_cap + (e.electric_buffer_size or 0)
            end
          end
        end
      end
    end
    if sc.cx >= sc.maxx then
      if sc.cy >= sc.maxy then
        sc.done = true
        break
      end
      sc.cx = sc.minx
      sc.cy = sc.cy + 1
    else
      sc.cx = sc.cx + 1
    end
  end
end

local function do_logi(b)
  local sname = b.surfaces[b.si]
  b.result[sname] = b.result[sname] or {}
  if logistics_enabled() then
    local force = game.forces[REPORTED_FORCE]
    local nets = force and force.valid and force.logistic_networks[sname]
    if nets then
      local allow = get_allowlist()
      local items = {}
      local n, la, lt, ca, ct = 0, 0, 0, 0, 0
      for _, net in pairs(nets) do
        n = n + 1
        la = la + net.available_logistic_robots
        lt = lt + net.all_logistic_robots
        ca = ca + net.available_construction_robots
        ct = ct + net.all_construction_robots
        for _, entry in pairs(net.get_contents()) do
          if allow == nil or allow[entry.name] then
            items[entry.name] = (items[entry.name] or 0) + entry.count
          end
        end
      end
      local out = {}
      for k, v in pairs(items) do
        if v ~= 0 then
          out[k] = v
        end
      end
      b.result[sname].logistics = {
        networks = n,
        items = out,
        robots = {
          logistic_available = la,
          logistic_total = lt,
          construction_available = ca,
          construction_total = ct,
        },
      }
    end
  end
  slow_next_surface(b)
end

local function do_alerts(b)
  local ok, res = pcall(collect_alerts)
  b.result_alerts = ok and res or {}
  b.phase = "finalize"
end

local function do_finalize_slow(b)
  storage.slow = b.result
  storage.slow_alerts = b.result_alerts
  storage.next_pass_tick = game.tick + get_interval()
  storage.b = nil
end

local function slow_step()
  local b = storage.b
  if not b then
    if game.tick >= (storage.next_pass_tick or 0) then
      begin_slow_pass()
    end
    return
  end
  local ph = b.phase
  if ph == "scan_init" then
    do_scan_init(b)
  elseif ph == "scan" then
    do_scan(b)
  elseif ph == "logi" then
    do_logi(b)
  elseif ph == "alerts" then
    do_alerts(b)
  elseif ph == "finalize" then
    do_finalize_slow(b)
  end
end

-- Read all player-tagged probe speakers. O(#probes); cleans up invalids.
local CIRCUIT_CONNECTORS = {
  defines.wire_connector_id.circuit_red,
  defines.wire_connector_id.circuit_green,
}

local function read_probes()
  local out = {}
  for un, p in pairs(storage.probes) do
    local e = p.e
    if e and e.valid then
      local pr = { surface = e.surface.name }

      -- A speaker has no electric_network_statistics (that is pole-only), but
      -- it does have electric_network_id for the network powering it. Read the
      -- network's flow from a cached electric pole on that same network; the
      -- pole is found by a tiny localized search and only re-resolved when the
      -- cached one is gone or its network changed.
      local nid = e.electric_network_id
      if nid then
        local pole = p.pole
        if not (pole and pole.valid and pole.electric_network_id == nid) then
          pole = nil
          for _, c in pairs(e.surface.find_entities_filtered({
            type = "electric-pole", position = e.position, radius = 16,
          })) do
            if c.valid and c.electric_network_id == nid then
              pole = c
              break
            end
          end
          p.pole = pole
        end
        if pole then
          local ok, st = pcall(function()
            return pole.electric_network_statistics
          end)
          if ok and st then
            local i, o = 0.0, 0.0
            for _, v in pairs(st.input_counts) do
              i = i + v
            end
            for _, v in pairs(st.output_counts) do
              o = o + v
            end
            pr.electric = { produced_j = i, consumed_j = o }
          end
        end
      end

      local sig = {}
      for _, conn in pairs(CIRCUIT_CONNECTORS) do
        local cok, net = pcall(function()
          return e.get_circuit_network(conn)
        end)
        if cok and net and net.signals then
          for _, s in pairs(net.signals) do
            sig[s.signal.name] = (sig[s.signal.name] or 0) + s.count
          end
        end
      end
      pr.signals = sig

      out[p.label] = pr
    else
      storage.probes[un] = nil
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- FAST lane: cheap full-snapshot rebuild, merging the slow cache.
-- ---------------------------------------------------------------------------

local function fast_refresh()
  local force = game.forces[REPORTED_FORCE]
  local enemy = game.forces["enemy"]
  local allow = get_allowlist()
  local slow = storage.slow or {}
  local slow_alerts = storage.slow_alerts or {}

  local snap = {
    v = SNAPSHOT_VERSION,
    tick = game.tick,
    game_speed = game.speed,
    players_online = #game.connected_players,
    players_total = #game.players,
    research_completed_total = storage.research_completed or 0,
    event_counts = storage.ev,
    events_recent = storage.events,
    surfaces = {},
  }
  if force and force.valid then
    local cur = force.current_research
    snap.research_current = cur and cur.name or ""
    snap.research_progress = force.research_progress or 0
  end

  for _, surface in pairs(game.surfaces) do
    local sname = surface.name
    local s = {}

    local ok, pollution = pcall(function()
      return surface.get_total_pollution()
    end)
    s.pollution = ok and pollution or 0

    if enemy and enemy.valid then
      local eok, ev = pcall(function()
        return enemy.get_evolution_factor(surface)
      end)
      s.evolution = eok and ev or 0
    else
      s.evolution = 0
    end

    s.rockets_launched_total = (storage.rockets and storage.rockets[sname]) or 0

    if force and force.valid then
      local istats = force.get_item_production_statistics(surface)
      local fstats = force.get_fluid_production_statistics(surface)
      s.items = {
        produced = filtered_counts(istats.input_counts, allow),
        consumed = filtered_counts(istats.output_counts, allow),
      }
      s.fluids = {
        produced = filtered_counts(fstats.input_counts, allow),
        consumed = filtered_counts(fstats.output_counts, allow),
      }
    end

    -- Merge the most recent slow-lane results (may lag by a slow pass; that
    -- is fine — electric/logistics change slowly).
    local sc = slow[sname]
    if sc then
      s.electric = sc.electric
      s.logistics = sc.logistics
    end
    s.alerts = slow_alerts[sname] or {}

    snap.surfaces[sname] = s
  end

  snap.probes = read_probes()

  storage.snapshot_json = helpers.table_to_json(snap)
end

-- ---------------------------------------------------------------------------
-- Timer registration. SLOW stepper is a constant period; FAST period follows
-- the sample-interval setting (re-registered on change / load).
-- ---------------------------------------------------------------------------

local function register_timers()
  script.on_nth_tick(STEP_TICKS, slow_step)
  local period = storage.fast_period or DEFAULT_FAST_PERIOD
  script.on_nth_tick(period, fast_refresh)
end

local function rearm_fast_timer()
  if storage.fast_period then
    script.on_nth_tick(storage.fast_period, nil)
  end
  storage.fast_period = get_interval()
  script.on_nth_tick(storage.fast_period, fast_refresh)
end

local function init_storage()
  storage.research_completed = storage.research_completed or 0
  storage.rockets = storage.rockets or {}
  storage.events = storage.events or {}
  storage.event_seq = storage.event_seq or 0
  storage.ev = storage.ev or {
    chat = 0, death = 0, command = 0, join = 0,
    leave = 0, rocket = 0, research = 0, entity_lost = 0,
  }
  storage.slow = storage.slow or {}
  storage.slow_alerts = storage.slow_alerts or {}
  storage.probes = storage.probes or {}        -- [unit_number] = {e=LuaEntity, label=string}
  storage.gui_speaker = storage.gui_speaker or {} -- [player_index] = LuaEntity (open speaker)
  storage.next_pass_tick = storage.next_pass_tick or 0
  -- Drop any in-progress slow pass (shape may differ across mod versions).
  storage.b = nil
end

script.on_init(function()
  init_storage()
  storage.fast_period = get_interval()
  register_timers()
  fast_refresh()
end)

script.on_load(function()
  -- No game access here; just re-arm timers from persisted period.
  register_timers()
end)

script.on_configuration_changed(function()
  init_storage()
  rearm_fast_timer()
  script.on_nth_tick(STEP_TICKS, slow_step)
  fast_refresh()
end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "factorio-telemetry-sample-interval" then
    rearm_fast_timer()
  end
end)

script.on_event(defines.events.on_rocket_launched, function(event)
  local surface = event.rocket and event.rocket.valid and event.rocket.surface
  local name = surface and surface.name or "unknown"
  storage.rockets[name] = (storage.rockets[name] or 0) + 1
  storage.ev.rocket = storage.ev.rocket + 1
  push_event("rocket", name)
end)

script.on_event(defines.events.on_research_finished, function(event)
  storage.research_completed = (storage.research_completed or 0) + 1
  storage.ev.research = storage.ev.research + 1
  push_event("research", event.research and event.research.name or "?")
end)

script.on_event(defines.events.on_console_chat, function(event)
  storage.ev.chat = storage.ev.chat + 1
  push_event("chat", event.message, player_name(event.player_index))
end)

script.on_event(defines.events.on_console_command, function(event)
  storage.ev.command = storage.ev.command + 1
  push_event("command", event.command, player_name(event.player_index))
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  storage.ev.join = storage.ev.join + 1
  push_event("join", "", player_name(event.player_index))
end)

script.on_event(defines.events.on_player_left_game, function(event)
  storage.ev.leave = storage.ev.leave + 1
  push_event("leave", "", player_name(event.player_index))
end)

script.on_event(defines.events.on_player_died, function(event)
  storage.ev.death = storage.ev.death + 1
  local cause = event.cause and event.cause.valid and event.cause.name or "unknown"
  push_event("death", "killed by " .. cause, player_name(event.player_index))
end)

script.on_event(defines.events.on_entity_died, function(event)
  local cause = event.cause
  if cause and cause.valid and cause.force and cause.force.name == "enemy" then
    storage.ev.entity_lost = storage.ev.entity_lost + 1
    local ent = event.entity
    local where = ent and ent.valid and ent.surface and ent.surface.name or "?"
    local what = ent and ent.valid and ent.name or "?"
    push_event("entity_lost", what .. " on " .. where)
  end
end, { { filter = "force", force = "player" } })

-- "Connect to Telemetry" checkbox anchored to the Programmable Speaker GUI.
script.on_event(defines.events.on_gui_opened, function(event)
  if event.gui_type ~= defines.gui_type.entity then
    return
  end
  local e = event.entity
  if not (e and e.valid and e.name == SPEAKER_NAME) then
    return
  end
  local player = game.get_player(event.player_index)
  if not player then
    return
  end
  storage.gui_speaker[event.player_index] = e

  local rel = player.gui.relative
  local frame = rel[PROBE_FRAME]
  if not frame then
    frame = rel.add({
      type = "frame",
      name = PROBE_FRAME,
      direction = "vertical",
      caption = "Telemetry",
      anchor = {
        gui = defines.relative_gui_type.programmable_speaker_gui,
        position = defines.relative_gui_position.right,
      },
    })
    frame.add({
      type = "checkbox",
      name = PROBE_ENABLE,
      caption = "Connect to Telemetry",
      state = false,
    })
    frame.add({ type = "label", caption = "Probe label:" })
    frame.add({ type = "textfield", name = PROBE_LABEL, text = "" })
  end

  local p = storage.probes[e.unit_number]
  frame[PROBE_ENABLE].state = p ~= nil
  local lbl = frame[PROBE_LABEL]
  lbl.text = (p and p.label) or ("probe-" .. e.unit_number)
  lbl.enabled = p ~= nil
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  local el = event.element
  if not (el and el.valid and el.name == PROBE_ENABLE) then
    return
  end
  local player = game.get_player(event.player_index)
  local e = storage.gui_speaker[event.player_index]
  if not (player and e and e.valid) then
    return
  end
  local frame = player.gui.relative[PROBE_FRAME]
  local lbl = frame and frame[PROBE_LABEL]
  if el.state then
    local text = (lbl and lbl.text ~= "" and lbl.text)
      or ("probe-" .. e.unit_number)
    storage.probes[e.unit_number] = { e = e, label = text }
    if lbl then
      lbl.enabled = true
    end
  else
    storage.probes[e.unit_number] = nil
    if lbl then
      lbl.enabled = false
    end
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  local el = event.element
  if not (el and el.valid and el.name == PROBE_LABEL) then
    return
  end
  local e = storage.gui_speaker[event.player_index]
  if e and e.valid and storage.probes[e.unit_number] then
    local t = el.text
    if t == "" then
      t = "probe-" .. e.unit_number
    end
    storage.probes[e.unit_number].label = t
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if event.gui_type == defines.gui_type.entity then
    storage.gui_speaker[event.player_index] = nil
  end
end)

remote.add_interface("telemetry", {
  -- Last fast-refreshed snapshot (JSON). "{}" only before the very first
  -- fast refresh.
  snapshot = function()
    return storage.snapshot_json or "{}"
  end,
  -- Force a fresh fast rebuild now and kick a slow pass asap. Cheap (no
  -- entity scans) so safe to call from an RCON command.
  rebuild = function()
    storage.next_pass_tick = 0
    fast_refresh()
    return storage.snapshot_json or "{}"
  end,
})
