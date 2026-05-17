"""Runs in an in-cluster pod. Publishes a factorio-telemetry release to
mods.factorio.com via the v2 API. API key comes from a secret env (never on
the shell / in logs); the zip is mounted at /mod.

Env:  APIKEY  (Mod Portal API key, 'Upload Mods' usage)
"""
import json
import os
import sys
import urllib.request

API = "https://mods.factorio.com/api/v2/mods/releases/init_upload"
KEY = os.environ["APIKEY"]
MOD = "factorio-telemetry"

zips = [f for f in os.listdir("/mod") if f.startswith("factorio-telemetry_")]
if not zips:
    print("no mod zip mounted at /mod", flush=True)
    sys.exit(1)
zip_path = os.path.join("/mod", zips[0])
print(f"publishing {zips[0]}", flush=True)


def post_multipart(url, fields, files, headers=None):
    boundary = "----factorioTelemetryBoundary"
    body = b""
    for k, v in fields.items():
        body += (f"--{boundary}\r\n"
                 f'Content-Disposition: form-data; name="{k}"\r\n\r\n'
                 f"{v}\r\n").encode()
    for k, (fn, data) in files.items():
        body += (f"--{boundary}\r\n"
                 f'Content-Disposition: form-data; name="{k}"; filename="{fn}"\r\n'
                 f"Content-Type: application/zip\r\n\r\n").encode()
        body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    h = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=body, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


# Step 1: init_upload
code, resp = post_multipart(API, {"mod": MOD}, {},
                            {"Authorization": f"Bearer {KEY}"})
print(f"init_upload HTTP {code}: {resp}", flush=True)
if code != 200:
    sys.exit(1)
upload_url = json.loads(resp)["upload_url"]

# Step 2: upload the zip to the (pre-signed) URL
with open(zip_path, "rb") as f:
    data = f.read()
code, resp = post_multipart(upload_url, {}, {"file": (zips[0], data)})
print(f"upload HTTP {code}: {resp}", flush=True)

# Idempotent: re-publishing an already-published version is a no-op success,
# so a re-run of the deploy flow doesn't fail.
if code == 200 or "already exists" in resp:
    sys.exit(0)
sys.exit(1)
