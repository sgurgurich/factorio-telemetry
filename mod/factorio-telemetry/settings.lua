data:extend({
  {
    type = "int-setting",
    name = "factorio-telemetry-sample-interval",
    setting_type = "runtime-global",
    default_value = 300,
    minimum_value = 60,
    maximum_value = 3600,
    order = "a",
  },
  {
    -- Comma-separated item/fluid prototype names. Empty = export everything
    -- the force has produced or consumed (still bounded by the base game's
    -- own statistics dictionaries).
    type = "string-setting",
    name = "factorio-telemetry-item-allowlist",
    setting_type = "runtime-global",
    default_value = "",
    allow_blank = true,
    order = "b",
  },
  {
    -- Iterating every logistic network's contents is the heaviest part of the
    -- snapshot on large multi-surface saves. Toggle off if it stutters.
    type = "bool-setting",
    name = "factorio-telemetry-logistics",
    setting_type = "runtime-global",
    default_value = true,
    order = "c",
  },
  {
    -- Split item produced/consumed by quality (normal/uncommon/rare/epic/
    -- legendary). Adds a per-(item x quality) statistics lookup to the fast
    -- lane; toggle off if a megabase stutters (the dashboard "Group by"
    -- selector still works, everything just collapses to normal).
    type = "bool-setting",
    name = "factorio-telemetry-quality-split",
    setting_type = "runtime-global",
    default_value = true,
    order = "d",
  },
})
