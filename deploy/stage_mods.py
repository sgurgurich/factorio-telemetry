"""Runs in an in-cluster helper pod that mounts the Factorio data PVC and has
the mod-portal credentials via secret env. Stages mods, removes
MaxRateCalculator, and rewrites mod-list.json. Portal creds never leave the
cluster."""
import hashlib
import json
import os
import shutil
import sys
import urllib.request

MODS = "/factorio/mods"
U = os.environ["PORTAL_USERNAME"].strip()
T = os.environ["PORTAL_TOKEN"].strip()
# mods.factorio.com returns 403 for urllib's default User-Agent.
UA = "Mozilla/5.0 (factorio-telemetry mod stager)"

# (portal download path, destination filename, expected sha1)
DOWNLOADS = [
    ("/download/flib/690aa58f2da58c0b75aadd06", "flib_0.16.5.zip",
     "be7ce1b5c9477ad3161df120a379aec091b86f77"),
    ("/download/RateCalculator/696d65295c86e177a42ba14c", "RateCalculator_3.3.8.zip",
     "9fb4592b2f05b3dc3110e51fc04df4ce053a39e3"),
    ("/download/RocketCargoInsertion/69ddc493e984fe92edcd0963", "RocketCargoInsertion_1.1.1.zip",
     "30a743bc37714fcc1a1b9565bd36c2fac4078034"),
]
ENABLE = ["factorio-telemetry", "flib", "RateCalculator", "RocketCargoInsertion"]
REMOVE_PREFIX = "MaxRateCalculator"


def finalize(path):
    os.chown(path, 845, 845)
    os.chmod(path, 0o664)


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# 1. telemetry mod (from configmap mount) — remove any prior version first so
# Factorio does not see two copies of the same mod.
src = next(f for f in os.listdir("/modsrc") if f.startswith("factorio-telemetry_"))
for fn in os.listdir(MODS):
    if fn.startswith("factorio-telemetry_"):
        os.remove(os.path.join(MODS, fn))
        print(f"RM  {fn}", flush=True)
dst = os.path.join(MODS, src)
shutil.copyfile(os.path.join("/modsrc", src), dst)
finalize(dst)
print(f"OK  {dst}", flush=True)

# 2. portal downloads, sha1-verified (skip if already present and correct)
for path, fname, want in DOWNLOADS:
    dst = os.path.join(MODS, fname)
    if os.path.exists(dst) and sha1(dst) == want:
        print(f"OK  {dst} (already present)", flush=True)
        continue
    tmp = dst + ".part"
    url = f"https://mods.factorio.com{path}?username={U}&token={T}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    got = sha1(tmp)
    if got != want:
        os.remove(tmp)
        print(f"FAIL sha1 {fname}: got {got} want {want}", flush=True)
        sys.exit(1)
    os.replace(tmp, dst)
    finalize(dst)
    print(f"OK  {dst} sha1={got}", flush=True)

# 3. remove MaxRateCalculator
for fn in os.listdir(MODS):
    if fn.startswith(REMOVE_PREFIX):
        os.remove(os.path.join(MODS, fn))
        print(f"RM  {fn}", flush=True)

# 4. rewrite mod-list.json
mlp = os.path.join(MODS, "mod-list.json")
with open(mlp) as f:
    ml = json.load(f)
mods = ml.get("mods", [])
index = {m["name"]: m for m in mods}
for name in ENABLE:
    if name in index:
        index[name]["enabled"] = True
    else:
        m = {"name": name, "enabled": True}
        mods.append(m)
        index[name] = m
mods = [m for m in mods if m["name"] != "MaxRateCalculator"]
ml["mods"] = mods
with open(mlp, "w") as f:
    json.dump(ml, f, indent=2)
finalize(mlp)
print("mod-list:", ",".join(m["name"] for m in mods), flush=True)
print("DONE", flush=True)
