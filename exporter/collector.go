package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// Mirrors the JSON produced by the factorio-telemetry mod's remote interface.
type electric struct {
	ProducedJ            float64 `json:"produced_j"`
	ConsumedJ            float64 `json:"consumed_j"`
	Networks             float64 `json:"networks"`
	AccumulatorChargeJ   float64 `json:"accumulator_charge_j"`
	AccumulatorCapacityJ float64 `json:"accumulator_capacity_j"`
}

type logistics struct {
	Networks float64            `json:"networks"`
	Items    map[string]float64 `json:"items"`
	Robots   struct {
		LogisticAvailable     float64 `json:"logistic_available"`
		LogisticTotal         float64 `json:"logistic_total"`
		ConstructionAvailable float64 `json:"construction_available"`
		ConstructionTotal     float64 `json:"construction_total"`
	} `json:"robots"`
}

type surface struct {
	Pollution            float64            `json:"pollution"`
	Evolution            float64            `json:"evolution"`
	RocketsLaunchedTotal float64            `json:"rockets_launched_total"`
	Electric             *electric          `json:"electric"`
	Logistics            *logistics         `json:"logistics"`
	Alerts               map[string]float64 `json:"alerts"`
	Items                struct {
		Produced map[string]float64 `json:"produced"`
		Consumed map[string]float64 `json:"consumed"`
	} `json:"items"`
	Fluids struct {
		Produced map[string]float64 `json:"produced"`
		Consumed map[string]float64 `json:"consumed"`
	} `json:"fluids"`
}

// A player-tagged Programmable Speaker probe.
type probe struct {
	Surface  string `json:"surface"`
	Electric *struct {
		ProducedJ float64 `json:"produced_j"`
		ConsumedJ float64 `json:"consumed_j"`
	} `json:"electric"`
	Signals map[string]float64 `json:"signals"`
}

type eventEntry struct {
	Seq  float64 `json:"seq"`
	T    float64 `json:"t"`
	Kind string  `json:"kind"`
	Who  string  `json:"who"`
	Msg  string  `json:"msg"`
}

// Factorio's helpers.table_to_json serializes an empty Lua table as `{}`, so
// an empty events ring buffer arrives as an object rather than `[]`. Accept
// both so a quiet server doesn't fail the whole snapshot decode.
type eventList []eventEntry

func (e *eventList) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || b[0] == '{' {
		*e = eventList{}
		return nil
	}
	var arr []eventEntry
	if err := json.Unmarshal(b, &arr); err != nil {
		return err
	}
	*e = arr
	return nil
}

type snapshot struct {
	V                      int                `json:"v"`
	Tick                   float64            `json:"tick"`
	GameSpeed              float64            `json:"game_speed"`
	PlayersOnline          float64            `json:"players_online"`
	PlayersTotal           float64            `json:"players_total"`
	ResearchCompletedTotal float64            `json:"research_completed_total"`
	ResearchCurrent        string             `json:"research_current"`
	ResearchProgress       float64            `json:"research_progress"`
	EventCounts            map[string]float64 `json:"event_counts"`
	EventsRecent           eventList          `json:"events_recent"`
	Surfaces               map[string]surface `json:"surfaces"`
	Probes                 map[string]probe   `json:"probes"`
}

const snapshotCmd = `/silent-command rcon.print(remote.call("telemetry", "snapshot"))`

type Collector struct {
	rcon     *RCON
	cacheTTL time.Duration

	mu        sync.Mutex
	cached    *snapshot
	cachedAt  time.Time
	lastErr   error

	descs map[string]*prometheus.Desc
}

func NewCollector(r *RCON, cacheTTL time.Duration) *Collector {
	d := func(name, help string, labels ...string) *prometheus.Desc {
		return prometheus.NewDesc(name, help, labels, nil)
	}
	return &Collector{
		rcon:     r,
		cacheTTL: cacheTTL,
		descs: map[string]*prometheus.Desc{
			"up":                 d("factorio_up", "1 if the last RCON snapshot scrape succeeded, else 0"),
			"scrape_duration":    d("factorio_scrape_duration_seconds", "Duration of the RCON snapshot fetch"),
			"tick":               d("factorio_game_tick", "Current map tick"),
			"speed":              d("factorio_game_speed", "Game speed multiplier"),
			"players_online":     d("factorio_players_online", "Connected players"),
			"players_total":      d("factorio_players_total", "Players that have ever joined"),
			"research_total":     d("factorio_research_completed_total", "Technologies researched since map start"),
			"research_progress":  d("factorio_research_progress", "Progress of current research [0,1]"),
			"research_info":      d("factorio_research_current_info", "Current research (1, labelled by name)", "research"),
			"pollution":          d("factorio_surface_pollution", "Total pollution on the surface", "surface"),
			"evolution":          d("factorio_evolution_factor", "Enemy evolution factor on the surface", "surface"),
			"rockets":            d("factorio_rockets_launched_total", "Rockets launched from the surface", "surface"),
			"e_produced":         d("factorio_electric_energy_produced_joules_total", "Cumulative energy produced on the surface", "surface"),
			"e_consumed":         d("factorio_electric_energy_consumed_joules_total", "Cumulative energy consumed on the surface", "surface"),
			"e_networks":         d("factorio_electric_networks", "Distinct electric networks on the surface", "surface"),
			"acc_charge":         d("factorio_accumulator_charge_joules", "Accumulator stored energy on the surface", "surface"),
			"acc_capacity":       d("factorio_accumulator_capacity_joules", "Accumulator total capacity on the surface", "surface"),
			"item_produced":      d("factorio_item_produced_total", "Cumulative items produced", "surface", "item"),
			"item_consumed":      d("factorio_item_consumed_total", "Cumulative items consumed", "surface", "item"),
			"fluid_produced":     d("factorio_fluid_produced_total", "Cumulative fluid produced", "surface", "fluid"),
			"fluid_consumed":     d("factorio_fluid_consumed_total", "Cumulative fluid consumed", "surface", "fluid"),
			"logi_networks":      d("factorio_logistic_networks", "Logistic networks on the surface", "surface"),
			"logi_item":          d("factorio_logistic_item_count", "Items held in logistic networks", "surface", "item"),
			"robot_la":           d("factorio_logistic_robots_available", "Available logistic robots", "surface"),
			"robot_lt":           d("factorio_logistic_robots_total", "Total logistic robots", "surface"),
			"robot_ca":           d("factorio_construction_robots_available", "Available construction robots", "surface"),
			"robot_ct":           d("factorio_construction_robots_total", "Total construction robots", "surface"),
			"alerts":             d("factorio_active_alerts", "Active in-game alerts (max across players)", "surface", "type"),
			"events":             d("factorio_events_total", "Cumulative game events by kind", "kind"),
			"probe_info":         d("factorio_probe_info", "1 for each registered telemetry probe speaker", "probe", "surface"),
			"probe_e_produced":   d("factorio_probe_electric_produced_joules_total", "Cumulative energy produced on a probe speaker's electric network", "probe", "surface"),
			"probe_e_consumed":   d("factorio_probe_electric_consumed_joules_total", "Cumulative energy consumed on a probe speaker's electric network", "probe", "surface"),
			"probe_signal":       d("factorio_probe_signal", "Circuit-network signal wired into a probe speaker", "probe", "surface", "signal"),
		},
	}
}

func (c *Collector) Describe(ch chan<- *prometheus.Desc) {
	for _, dsc := range c.descs {
		ch <- dsc
	}
}

func (c *Collector) fetch() (*snapshot, time.Duration, error) {
	c.mu.Lock()
	if c.cached != nil && time.Since(c.cachedAt) < c.cacheTTL {
		s := c.cached
		c.mu.Unlock()
		return s, 0, nil
	}
	c.mu.Unlock()

	start := time.Now()
	raw, err := c.rcon.Exec(snapshotCmd)
	dur := time.Since(start)
	if err != nil {
		return nil, dur, err
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, dur, fmt.Errorf("empty RCON response (mod loaded?)")
	}
	var s snapshot
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		return nil, dur, fmt.Errorf("decode snapshot: %w (got %.120q)", err, raw)
	}

	c.mu.Lock()
	c.cached, c.cachedAt, c.lastErr = &s, time.Now(), nil
	c.mu.Unlock()
	return &s, dur, nil
}

func (c *Collector) Collect(ch chan<- prometheus.Metric) {
	g := func(key string, v float64, labels ...string) {
		ch <- prometheus.MustNewConstMetric(c.descs[key], prometheus.GaugeValue, v, labels...)
	}
	ct := func(key string, v float64, labels ...string) {
		ch <- prometheus.MustNewConstMetric(c.descs[key], prometheus.CounterValue, v, labels...)
	}

	s, dur, err := c.fetch()
	if err != nil {
		log.Printf("scrape error: %v", err)
		g("up", 0)
		if dur > 0 {
			g("scrape_duration", dur.Seconds())
		}
		return
	}

	g("up", 1)
	g("scrape_duration", dur.Seconds())
	g("tick", s.Tick)
	g("speed", s.GameSpeed)
	g("players_online", s.PlayersOnline)
	g("players_total", s.PlayersTotal)
	ct("research_total", s.ResearchCompletedTotal)
	g("research_progress", s.ResearchProgress)
	if s.ResearchCurrent != "" {
		g("research_info", 1, s.ResearchCurrent)
	}
	for kind, v := range s.EventCounts {
		ct("events", v, kind)
	}

	for name, sf := range s.Surfaces {
		g("pollution", sf.Pollution, name)
		g("evolution", sf.Evolution, name)
		ct("rockets", sf.RocketsLaunchedTotal, name)
		if sf.Electric != nil {
			ct("e_produced", sf.Electric.ProducedJ, name)
			ct("e_consumed", sf.Electric.ConsumedJ, name)
			g("e_networks", sf.Electric.Networks, name)
			g("acc_charge", sf.Electric.AccumulatorChargeJ, name)
			g("acc_capacity", sf.Electric.AccumulatorCapacityJ, name)
		}
		for item, v := range sf.Items.Produced {
			ct("item_produced", v, name, item)
		}
		for item, v := range sf.Items.Consumed {
			ct("item_consumed", v, name, item)
		}
		for fl, v := range sf.Fluids.Produced {
			ct("fluid_produced", v, name, fl)
		}
		for fl, v := range sf.Fluids.Consumed {
			ct("fluid_consumed", v, name, fl)
		}
		if sf.Logistics != nil {
			g("logi_networks", sf.Logistics.Networks, name)
			g("robot_la", sf.Logistics.Robots.LogisticAvailable, name)
			g("robot_lt", sf.Logistics.Robots.LogisticTotal, name)
			g("robot_ca", sf.Logistics.Robots.ConstructionAvailable, name)
			g("robot_ct", sf.Logistics.Robots.ConstructionTotal, name)
			for item, v := range sf.Logistics.Items {
				g("logi_item", v, name, item)
			}
		}
		for atype, v := range sf.Alerts {
			g("alerts", v, name, atype)
		}
	}

	for label, pr := range s.Probes {
		g("probe_info", 1, label, pr.Surface)
		if pr.Electric != nil {
			ct("probe_e_produced", pr.Electric.ProducedJ, label, pr.Surface)
			ct("probe_e_consumed", pr.Electric.ConsumedJ, label, pr.Surface)
		}
		for sig, v := range pr.Signals {
			g("probe_signal", v, label, pr.Surface, sig)
		}
	}
}

// Snapshot returns the most recent parsed snapshot (subject to the cache TTL).
func (c *Collector) Snapshot() (*snapshot, error) {
	s, _, err := c.fetch()
	return s, err
}
