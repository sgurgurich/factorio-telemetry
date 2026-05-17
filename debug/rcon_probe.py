import os, socket, struct, sys

HOST = os.environ.get("RCON_HOST", "factorio-default-rcon")
PORT = int(os.environ.get("RCON_PORT", "27015"))
PW = os.environ["rconpw"]


def pkt(pid, ptype, body):
    payload = struct.pack("<ii", pid, ptype) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError("connection closed")
        buf += c
    return buf


def read_pkt(s):
    raw_len = recv_exact(s, 4)
    size = struct.unpack("<i", raw_len)[0]
    body = recv_exact(s, size)
    pid, ptype = struct.unpack("<ii", body[:8])
    return pid, ptype, body[8:-2]


s = socket.create_connection((HOST, PORT), timeout=10)
s.settimeout(10)
print(f"connected to {HOST}:{PORT}, pw_len={len(PW)}", flush=True)

s.sendall(pkt(1, 3, PW))
print("sent AUTH (type 3, id 1)", flush=True)

try:
    for i in range(3):
        pid, ptype, b = read_pkt(s)
        print(f"  recv #{i}: id={pid} type={ptype} body={b!r}", flush=True)
        if ptype == 2:
            break
except Exception as e:
    print(f"  read error: {e!r}", flush=True)
    sys.exit(1)

s.sendall(pkt(10, 2, "/silent-command rcon.print('PONG')"))
s.sendall(pkt(11, 2, ""))
print("sent EXEC + sentinel", flush=True)
try:
    for i in range(5):
        pid, ptype, b = read_pkt(s)
        print(f"  exec recv #{i}: id={pid} type={ptype} body={b!r}", flush=True)
        if pid == 11:
            break
except Exception as e:
    print(f"  exec read error: {e!r}", flush=True)
print("done", flush=True)
