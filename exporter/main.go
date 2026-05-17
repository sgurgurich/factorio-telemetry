package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	var (
		rconAddr = env("RCON_ADDR", "factorio-default-rcon:27015")
		rconPass = os.Getenv("RCON_PASSWORD")
		listen   = env("LISTEN_ADDR", ":9145")
		cacheTTL = env("CACHE_TTL", "3s")
		rconTO   = env("RCON_TIMEOUT", "8s")
	)
	if rconPass == "" {
		log.Fatal("RCON_PASSWORD is required")
	}
	cttl, err := time.ParseDuration(cacheTTL)
	if err != nil {
		log.Fatalf("invalid CACHE_TTL: %v", err)
	}
	rto, err := time.ParseDuration(rconTO)
	if err != nil {
		log.Fatalf("invalid RCON_TIMEOUT: %v", err)
	}

	rcon := NewRCON(rconAddr, rconPass, rto)
	defer rcon.Close()

	collector := NewCollector(rcon, cttl)
	reg := prometheus.NewRegistry()
	reg.MustRegister(collector)

	// Optional: push game events to Loki (disabled if LOKI_URL is unset).
	if lokiURL := os.Getenv("LOKI_URL"); lokiURL != "" {
		li, err := time.ParseDuration(env("LOKI_INTERVAL", "7s"))
		if err != nil {
			log.Fatalf("invalid LOKI_INTERVAL: %v", err)
		}
		go NewLokiPusher(lokiURL, collector, li).Run(context.Background())
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	// Recent chat/death/alert/etc. events as JSON. Useful without a log stack:
	//   curl .../events            -> all buffered events
	//   curl .../events?kind=chat  -> only that kind
	mux.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		snap, err := collector.Snapshot()
		w.Header().Set("Content-Type", "application/json")
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		out := snap.EventsRecent
		if kind := r.URL.Query().Get("kind"); kind != "" {
			filtered := make(eventList, 0, len(out))
			for _, e := range out {
				if e.Kind == kind {
					filtered = append(filtered, e)
				}
			}
			out = filtered
		}
		if out == nil {
			out = eventList{}
		}
		_ = json.NewEncoder(w).Encode(out)
	})

	srv := &http.Server{
		Addr:              listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("factorio-telemetry-exporter listening on %s, rcon=%s", listen, rconAddr)
	log.Fatal(srv.ListenAndServe())
}
