#!/usr/bin/env python3
"""FlexCache configuration through the ONTAP REST API.

Runs ON THE ORIGIN EC2 CLIENT (sent there by stacks/04-flexcache with SSM Run
Command). From there the FSx for ONTAP Origin management IP is local and the
Cache one is reached over the VPC peering.

    python3 flexcache.py create <config-base64>
    python3 flexcache.py delete <config-base64>

create (idempotent - every step checks what already exists):
  1. cluster peer   Origin <-> Cache, over the intercluster LIFs, with a one-time
                    passphrase generated here (it never leaves this machine)
  2. SVM peer       svm-cache <-> svm-origin, application "flexcache"
  3. FlexCache      vol_cache on svm-cache, origin = vol_origin on svm-origin,
                    mounted at the junction path
delete: the same in reverse (FlexCache, SVM peer, cluster peer).

The fsxadmin password is read here from Secrets Manager with the instance role
(through the VPC endpoint), so it never appears in the SSM command.
Standard library only (Python 3 ships with Amazon Linux 2023).
"""

import base64
import json
import secrets
import ssl
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request

PEER_TIMEOUT = 600  # seconds to wait for the cluster / SVM peer to become available
JOB_TIMEOUT = 1800  # seconds to wait for an ONTAP job (FlexCache create/delete)


def log(msg):
    print(f"[flexcache] {msg}", flush=True)


class OntapError(Exception):
    pass


class Ontap:
    """Minimal ONTAP REST client (FSx for ONTAP uses a self-signed certificate)."""

    def __init__(self, label, host, user, password):
        self.label, self.host = label, host
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Accept": "application/json",
                        "Content-Type": "application/json"}
        self.ctx = ssl._create_unverified_context()

    def call(self, method, path, body=None, ok_missing=False):
        url = f"https://{self.host}/api{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers=self.headers)
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, context=self.ctx, timeout=120) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                text = e.read().decode(errors="replace")
                if e.code == 404 and ok_missing:
                    return None
                raise OntapError(f"{self.label}: {method} {path} -> HTTP {e.code}: {text}") from None
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt == 4:
                    raise OntapError(f"{self.label}: cannot reach {self.host}: {e}") from None
                log(f"{self.label}: {self.host} not reachable ({e}), retrying...")
                time.sleep(10)

    def get(self, path, ok_missing=False):
        return self.call("GET", path, ok_missing=ok_missing)

    def records(self, path):
        return (self.get(path) or {}).get("records", [])

    def wait_job(self, resp, what):
        """POST/PATCH/DELETE may answer 202 with a job: wait for it to finish."""
        job = (resp or {}).get("job")
        if not job:
            return
        deadline = time.time() + JOB_TIMEOUT
        while time.time() < deadline:
            j = self.get(f"/cluster/jobs/{job['uuid']}?fields=state,message,error")
            state = j.get("state")
            if state == "success":
                return
            if state == "failure":
                raise OntapError(f"{self.label}: {what} failed: {j.get('message') or j.get('error')}")
            time.sleep(5)
        raise OntapError(f"{self.label}: {what} still running after {JOB_TIMEOUT}s")


def read_secret(arn, region):
    for attempt in range(12):  # the Secrets Manager endpoint may still be coming up
        r = subprocess.run(["aws", "secretsmanager", "get-secret-value", "--secret-id", arn,
                            "--region", region, "--query", "SecretString", "--output", "text"],
                           capture_output=True, text=True)
        if r.returncode == 0:
            s = json.loads(r.stdout)
            return s["username"], s["password"]
        log(f"reading the fsxadmin secret failed ({r.stderr.strip()}), retrying...")
        time.sleep(15)
    raise OntapError("cannot read the fsxadmin secret from Secrets Manager")


def wait_until(check, what, timeout=PEER_TIMEOUT):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if check():
            return
        time.sleep(10)
    raise OntapError(f"timed out waiting for {what}")


# --- cluster peer ------------------------------------------------------------------

def cluster_peer(o, c, o_name, c_name, cfg):
    def peer_on(side, remote_name):
        recs = side.records(f"/cluster/peers?name={remote_name}&fields=name,status")
        return recs[0] if recs else None

    po, pc = peer_on(o, c_name), peer_on(c, o_name)
    if po and pc:
        log(f"cluster peer {o_name} <-> {c_name} already exists")
    else:
        # Half a peer (e.g. from an interrupted run) can't be completed without its
        # passphrase, so remove it and create both sides fresh.
        for side, rec in ((o, po), (c, pc)):
            if rec:
                log(f"{side.label}: removing incomplete cluster peer {rec['name']}")
                side.call("DELETE", f"/cluster/peers/{rec['uuid']}")
        passphrase = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24))
        log(f"creating cluster peer on the Origin -> Cache intercluster {cfg['cache']['intercluster_ips']}")
        o.call("POST", "/cluster/peers", {"remote": {"ip_addresses": cfg["cache"]["intercluster_ips"]},
                                          "authentication": {"passphrase": passphrase}})
        log(f"creating cluster peer on the Cache -> Origin intercluster {cfg['origin']['intercluster_ips']}")
        c.call("POST", "/cluster/peers", {"remote": {"ip_addresses": cfg["origin"]["intercluster_ips"]},
                                          "authentication": {"passphrase": passphrase}})

    def available():
        a, b = peer_on(o, c_name), peer_on(c, o_name)
        states = [((x or {}).get("status") or {}).get("state") for x in (a, b)]
        log(f"cluster peer state: origin={states[0]} cache={states[1]}")
        return states == ["available", "available"]
    wait_until(available, "the cluster peer to become available")


# --- SVM peer ------------------------------------------------------------------------

def svm_peer(o, c, o_cluster, cfg):
    o_svm, c_svm = cfg["origin"]["svm_name"], cfg["cache"]["svm_name"]

    def on_cache():
        r = c.records(f"/svm/peers?svm.name={c_svm}&peer.svm.name={o_svm}&fields=state,applications")
        return r[0] if r else None

    def on_origin():
        r = o.records(f"/svm/peers?svm.name={o_svm}&peer.svm.name={c_svm}&fields=state,applications")
        return r[0] if r else None

    if not on_cache():
        log(f"creating SVM peer {c_svm} -> {o_svm} (application flexcache)")
        c.call("POST", "/svm/peers", {"svm": {"name": c_svm},
                                      "peer": {"svm": {"name": o_svm}, "cluster": {"name": o_cluster}},
                                      "applications": ["flexcache"]})
    else:
        log(f"SVM peer {c_svm} -> {o_svm} already exists")

    def peered():
        rc, ro = on_cache(), on_origin()
        if ro and ro.get("state") == "pending":
            log(f"accepting SVM peer on the Origin ({o_svm})")
            o.call("PATCH", f"/svm/peers/{ro['uuid']}", {"state": "peered"})
        state = (rc or {}).get("state")
        log(f"SVM peer state: {state}")
        return state == "peered"
    wait_until(peered, "the SVM peer to become peered")

    rec = on_cache()
    if "flexcache" not in (rec.get("applications") or []):
        log("adding the flexcache application to the SVM peer")
        c.call("PATCH", f"/svm/peers/{rec['uuid']}",
               {"applications": sorted(set((rec.get("applications") or []) + ["flexcache"]))})


# --- FlexCache volume -------------------------------------------------------------------

def find_flexcache(c, cfg):
    fc = cfg["flexcache"]
    r = c.records(f"/storage/flexcache/flexcaches?name={fc['name']}&svm.name={cfg['cache']['svm_name']}")
    return r[0] if r else None


def flexcache(c, cfg):
    fc = cfg["flexcache"]
    if find_flexcache(c, cfg):
        log(f"FlexCache {fc['name']} already exists")
        return
    log(f"creating FlexCache {fc['name']} ({fc['size_gib']} GiB) on {cfg['cache']['svm_name']}, "
        f"origin {cfg['origin']['volume_name']} on {cfg['origin']['svm_name']}, path {fc['junction_path']}")
    resp = c.call("POST", "/storage/flexcache/flexcaches?return_timeout=120", {
        "name": fc["name"],
        "svm": {"name": cfg["cache"]["svm_name"]},
        "origins": [{"volume": {"name": cfg["origin"]["volume_name"]},
                     "svm": {"name": cfg["origin"]["svm_name"]}}],
        "size": int(fc["size_gib"]) * 1024 ** 3,
        "path": fc["junction_path"],
        "aggregates": [{"name": a} for a in fc["aggregates"]],
    })
    c.wait_job(resp, f"FlexCache {fc['name']} create")
    log(f"FlexCache {fc['name']} created and mounted at {fc['junction_path']}")


# --- actions ---------------------------------------------------------------------------------

def connect(cfg):
    user, password = read_secret(cfg["secret_arn"], cfg["secret_region"])
    o = Ontap("Origin", cfg["origin"]["management_ip"], user, password)
    c = Ontap("Cache", cfg["cache"]["management_ip"], user, password)
    o_name = o.get("/cluster?fields=name,version")["name"]
    c_name = c.get("/cluster?fields=name,version")["name"]
    log(f"Origin cluster {o_name} ({cfg['origin']['management_ip']}), "
        f"Cache cluster {c_name} ({cfg['cache']['management_ip']})")
    return o, c, o_name, c_name


def create(cfg):
    o, c, o_name, c_name = connect(cfg)
    cluster_peer(o, c, o_name, c_name, cfg)
    svm_peer(o, c, o_name, cfg)
    flexcache(c, cfg)
    log("done: cluster peer, SVM peer and FlexCache are in place")


def delete(cfg):
    o, c, o_name, c_name = connect(cfg)
    fc = find_flexcache(c, cfg)
    if fc:
        uuid = fc["uuid"]
        log(f"unmounting and taking FlexCache {cfg['flexcache']['name']} offline")
        c.wait_job(c.call("PATCH", f"/storage/volumes/{uuid}", {"nas": {"path": ""}}), "unmount")
        c.wait_job(c.call("PATCH", f"/storage/volumes/{uuid}", {"state": "offline"}), "offline")
        log(f"deleting FlexCache {cfg['flexcache']['name']}")
        c.wait_job(c.call("DELETE", f"/storage/flexcache/flexcaches/{uuid}"), "FlexCache delete")
    else:
        log("no FlexCache to delete")

    o_svm, c_svm = cfg["origin"]["svm_name"], cfg["cache"]["svm_name"]
    for side, svm, peer in ((c, c_svm, o_svm), (o, o_svm, c_svm)):
        for rec in side.records(f"/svm/peers?svm.name={svm}&peer.svm.name={peer}"):
            log(f"{side.label}: deleting SVM peer {svm} -> {peer}")
            side.wait_job(side.call("DELETE", f"/svm/peers/{rec['uuid']}", ok_missing=True), "SVM peer delete")

    for side, remote in ((c, o_name), (o, c_name)):
        for rec in side.records(f"/cluster/peers?name={remote}"):
            log(f"{side.label}: deleting cluster peer {remote}")
            side.call("DELETE", f"/cluster/peers/{rec['uuid']}", ok_missing=True)
    log("done: FlexCache, SVM peer and cluster peer removed")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("create", "delete"):
        print(__doc__)
        sys.exit(2)
    cfg = json.loads(base64.b64decode(sys.argv[2]))
    try:
        (create if sys.argv[1] == "create" else delete)(cfg)
    except OntapError as e:
        log(f"ERROR: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
