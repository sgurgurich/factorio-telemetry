package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// Minimal RCON client for Factorio's RCON.
//
// Packet wire format: int32 length | int32 id | int32 type | body\0 | \0
// Types: 3 = AUTH, 2 = EXECCOMMAND / AUTH_RESPONSE, 0 = RESPONSE_VALUE.
//
// Factorio differs from Valve Source RCON in two ways that matter here:
//   - it returns a command's full output in a single RESPONSE_VALUE packet
//     (it does not fragment responses), and
//   - it does NOT reply to an empty command.
// So the standard Valve "send an empty sentinel and read until it echoes"
// multi-packet technique hangs against Factorio. We instead send the command
// and read the single response packet that carries the matching request id.

const (
	rconTypeResponse = 0
	rconTypeCommand  = 2
	rconTypeAuth     = 3

	rconIDCommand = 1
	rconAuthFail  = -1

	rconMaxPacket = 4 * 1024 * 1024
)

type RCON struct {
	addr     string
	password string
	timeout  time.Duration

	mu   sync.Mutex
	conn net.Conn
	br   *bufio.Reader
}

func NewRCON(addr, password string, timeout time.Duration) *RCON {
	return &RCON{addr: addr, password: password, timeout: timeout}
}

func (r *RCON) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.dropConn()
}

func (r *RCON) dropConn() {
	if r.conn != nil {
		_ = r.conn.Close()
		r.conn = nil
		r.br = nil
	}
}

func (r *RCON) connect() error {
	conn, err := net.DialTimeout("tcp", r.addr, r.timeout)
	if err != nil {
		return fmt.Errorf("dial rcon: %w", err)
	}
	r.conn = conn
	r.br = bufio.NewReaderSize(conn, 64*1024)

	if err := r.writePacket(rconIDCommand, rconTypeAuth, r.password); err != nil {
		r.dropConn()
		return fmt.Errorf("send auth: %w", err)
	}
	// On success the server sends an (often empty) RESPONSE_VALUE followed by an
	// AUTH_RESPONSE (type 2). A failed auth yields id == -1.
	for {
		id, typ, _, err := r.readPacket()
		if err != nil {
			r.dropConn()
			return fmt.Errorf("read auth response: %w", err)
		}
		if typ == rconTypeCommand {
			if id == rconAuthFail {
				r.dropConn()
				return errors.New("rcon auth failed: bad password")
			}
			return nil
		}
	}
}

func (r *RCON) writePacket(id, typ int32, body string) error {
	payload := make([]byte, 0, len(body)+10)
	var hdr [8]byte
	binary.LittleEndian.PutUint32(hdr[0:4], uint32(id))
	binary.LittleEndian.PutUint32(hdr[4:8], uint32(typ))
	payload = append(payload, hdr[:]...)
	payload = append(payload, body...)
	payload = append(payload, 0, 0)

	var lenBuf [4]byte
	binary.LittleEndian.PutUint32(lenBuf[:], uint32(len(payload)))

	_ = r.conn.SetWriteDeadline(time.Now().Add(r.timeout))
	if _, err := r.conn.Write(lenBuf[:]); err != nil {
		return err
	}
	_, err := r.conn.Write(payload)
	return err
}

func (r *RCON) readPacket() (id, typ int32, body string, err error) {
	_ = r.conn.SetReadDeadline(time.Now().Add(r.timeout))

	var lenBuf [4]byte
	if _, err = io.ReadFull(r.br, lenBuf[:]); err != nil {
		return
	}
	size := binary.LittleEndian.Uint32(lenBuf[:])
	if size < 10 || size > rconMaxPacket {
		err = fmt.Errorf("rcon: bad packet size %d", size)
		return
	}
	buf := make([]byte, size)
	if _, err = io.ReadFull(r.br, buf); err != nil {
		return
	}
	id = int32(binary.LittleEndian.Uint32(buf[0:4]))
	typ = int32(binary.LittleEndian.Uint32(buf[4:8]))
	// body is buf[8:size-2] (two trailing nulls)
	body = string(buf[8 : size-2])
	return
}

// Exec runs a command and returns its full (de-fragmented) response body.
func (r *RCON) Exec(cmd string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	out, err := r.execLocked(cmd)
	if err == nil {
		return out, nil
	}
	// One transparent reconnect+retry: the persistent socket may have been
	// closed by a server restart between scrapes.
	r.dropConn()
	if cerr := r.connect(); cerr != nil {
		return "", cerr
	}
	return r.execLocked(cmd)
}

func (r *RCON) execLocked(cmd string) (string, error) {
	if r.conn == nil {
		if err := r.connect(); err != nil {
			return "", err
		}
	}
	if err := r.writePacket(rconIDCommand, rconTypeCommand, cmd); err != nil {
		return "", err
	}
	// Factorio sends exactly one RESPONSE_VALUE packet carrying the request id.
	for {
		id, typ, body, err := r.readPacket()
		if err != nil {
			return "", err
		}
		if typ == rconTypeResponse && id == rconIDCommand {
			return body, nil
		}
	}
}
