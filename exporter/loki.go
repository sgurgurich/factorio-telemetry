package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"time"
)

// LokiPusher polls the cached snapshot and ships newly-seen game events
// (chat, deaths, alerts-as-events, etc.) to Loki's push API. Dedupe is by the
// mod's monotonic, save-persistent event seq, so the ring buffer shifting and
// exporter/server restarts don't cause loss or duplicates (a fresh process
// skips the existing backlog rather than re-pushing it).
type LokiPusher struct {
	url      string // base, e.g. http://loki.monitoring.svc:3100
	col      *Collector
	interval time.Duration
	client   *http.Client

	lastSeq float64
	primed  bool
}

func NewLokiPusher(url string, col *Collector, interval time.Duration) *LokiPusher {
	return &LokiPusher{
		url:      url,
		col:      col,
		interval: interval,
		client:   &http.Client{Timeout: 10 * time.Second},
	}
}

type lokiStream struct {
	Stream map[string]string `json:"stream"`
	Values [][2]string       `json:"values"`
}

type lokiPush struct {
	Streams []lokiStream `json:"streams"`
}

func (p *LokiPusher) Run(ctx context.Context) {
	t := time.NewTicker(p.interval)
	defer t.Stop()
	log.Printf("loki pusher enabled -> %s (every %s)", p.url, p.interval)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := p.tick(); err != nil {
				log.Printf("loki push: %v", err)
			}
		}
	}
}

func (p *LokiPusher) tick() error {
	snap, err := p.col.Snapshot()
	if err != nil {
		return err
	}
	maxSeq := p.lastSeq
	for _, e := range snap.EventsRecent {
		if e.Seq > maxSeq {
			maxSeq = e.Seq
		}
	}
	// First successful poll: adopt the current high-water mark without pushing
	// the pre-existing backlog.
	if !p.primed {
		p.lastSeq = maxSeq
		p.primed = true
		return nil
	}

	type tv struct {
		ts   time.Time
		line string
	}
	byKind := map[string][]tv{}
	now := time.Now()
	speed := snap.GameSpeed
	if speed <= 0 {
		speed = 1
	}
	var newMax float64 = p.lastSeq
	for _, e := range snap.EventsRecent {
		if e.Seq <= p.lastSeq {
			continue
		}
		if e.Seq > newMax {
			newMax = e.Seq
		}
		secAgo := (snap.Tick - e.T) / (60.0 * speed)
		ts := now.Add(-time.Duration(secAgo * float64(time.Second)))
		if ts.After(now) {
			ts = now
		}
		if min := now.Add(-2 * time.Hour); ts.Before(min) {
			ts = min
		}
		line := fmt.Sprintf("seq=%d kind=%s who=%q msg=%q",
			int64(e.Seq), e.Kind, e.Who, e.Msg)
		byKind[e.Kind] = append(byKind[e.Kind], tv{ts, line})
	}
	if len(byKind) == 0 {
		return nil
	}

	push := lokiPush{}
	for kind, items := range byKind {
		sort.Slice(items, func(i, j int) bool { return items[i].ts.Before(items[j].ts) })
		vals := make([][2]string, 0, len(items))
		for _, it := range items {
			vals = append(vals, [2]string{
				fmt.Sprintf("%d", it.ts.UnixNano()), it.line,
			})
		}
		push.Streams = append(push.Streams, lokiStream{
			Stream: map[string]string{"job": "factorio-telemetry", "kind": kind},
			Values: vals,
		})
	}

	body, err := json.Marshal(push)
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost,
		p.url+"/loki/api/v1/push", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("loki status %d: %s", resp.StatusCode, msg)
	}
	p.lastSeq = newMax
	return nil
}
