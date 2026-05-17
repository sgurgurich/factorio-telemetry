import os, socket, struct, sys

HOST = os.environ.get("RCON_HOST", "factorio-default-rcon")
PORT = int(os.environ.get("RCON_PORT", "27015"))
PW = os.environ["rconpw"]
CMD = os.environ["CMD"]


def pkt(pid, ptype, body):
    p = struct.pack("<ii", pid, ptype) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(p)) + p


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise EOFError("connection closed")
        buf += c
    return buf


def read_pkt(s):
    size = struct.unpack("<i", recv_exact(s, 4))[0]
    body = recv_exact(s, size)
    pid, ptype = struct.unpack("<ii", body[:8])
    return pid, ptype, body[8:-2]


s = socket.create_connection((HOST, PORT), timeout=15)
s.settimeout(15)
s.sendall(pkt(1, 3, PW))
while True:
    pid, ptype, _ = read_pkt(s)
    if ptype == 2:
        if pid == -1:
            print("AUTH FAILED", flush=True)
            sys.exit(1)
        break
s.sendall(pkt(10, 2, CMD))
while True:
    pid, ptype, b = read_pkt(s)
    if ptype == 0 and pid == 10:
        print(b.decode(errors="replace"), flush=True)
        break
