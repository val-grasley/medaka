#!/usr/bin/env python3
"""
snipe_hetzner.py — grab a flickering Hetzner Cloud server the instant it restocks.

Polls the Hetzner Cloud API for per-datacenter availability of a target server
type (default: cx53, falling back to cx43) across preferred EU locations, and
POSTs a create request the moment one appears — injecting cloud-init user-data
so the box provisions itself. Creates EXACTLY ONE server, then exits.

Stdlib only (urllib + json). No pip install.

Usage:
    export HCLOUD_TOKEN=xxxxxxxx           # Hetzner Cloud API token (read+write)
    export HCLOUD_SSH_KEY="my-laptop"      # name of an SSH key already in the project
    python3 snipe_hetzner.py                       # snipe cx53 -> cx43, fsn1/nbg1/hel1
    python3 snipe_hetzner.py --dry-run            # poll + report, never create
    python3 snipe_hetzner.py --types cx53 \
        --locations fsn1,hel1 --interval 45 \
        --cloud-init cloud-init.yaml --name medaka-box

Notes:
  * Poll interval defaults to 45s (Hetzner limit is 3600 req/hr; each poll = 1 req).
  * On a create race ("resource_unavailable"), it logs and keeps polling.
  * Prints the new server's public IPv4 on success.
"""
import argparse, json, os, sys, time, urllib.request, urllib.error

API = "https://api.hetzner.cloud/v1"


def req(path, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(API + path, data=data, method=method)
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode())
        except Exception:
            return e.code, {"error": {"code": "http_%d" % e.code, "message": str(e)}}


def resolve_type_id(name, token):
    st, body = req("/server_types?name=" + name, token)
    types = body.get("server_types", []) if st == 200 else []
    return types[0]["id"] if types else None


def find_available_dc(type_id, wanted_locs, token):
    """Return (datacenter_name, location_name) where type_id is available, or None."""
    st, body = req("/datacenters", token)
    if st != 200:
        print("  ! /datacenters -> %s %s" % (st, body.get("error")), file=sys.stderr)
        return None
    # Preserve the caller's location priority order.
    by_loc = {}
    for dc in body.get("datacenters", []):
        loc = dc.get("location", {}).get("name")
        avail = dc.get("server_types", {}).get("available", [])
        if type_id in avail:
            by_loc.setdefault(loc, dc["name"])
    for loc in wanted_locs:
        if loc in by_loc:
            return by_loc[loc], loc
    return None


def create(name, type_name, datacenter, ssh_key, user_data, token):
    payload = {
        "name": name,
        "server_type": type_name,
        "datacenter": datacenter,
        "image": os.environ.get("HCLOUD_IMAGE", "debian-12"),
        "start_after_create": True,
    }
    if ssh_key:
        payload["ssh_keys"] = [ssh_key]
    if user_data:
        payload["user_data"] = user_data
    return req("/servers", token, method="POST", body=payload)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--types", default="cx53,cx43",
                    help="comma-sep server types in priority order (default cx53,cx43)")
    ap.add_argument("--locations", default="fsn1,nbg1,hel1",
                    help="comma-sep location priority (default fsn1,nbg1,hel1)")
    ap.add_argument("--name", default="medaka-box", help="new server name")
    ap.add_argument("--interval", type=int, default=45, help="poll seconds (default 45)")
    ap.add_argument("--cloud-init", default="cloud-init.yaml",
                    help="path to cloud-init user-data (optional)")
    ap.add_argument("--dry-run", action="store_true", help="report availability, never create")
    args = ap.parse_args()

    token = os.environ.get("HCLOUD_TOKEN")
    if not token:
        sys.exit("HCLOUD_TOKEN is not set.")
    ssh_key = os.environ.get("HCLOUD_SSH_KEY")
    if not ssh_key and not args.dry_run:
        print("WARNING: HCLOUD_SSH_KEY unset — you'll get an emailed root password "
              "instead of key auth.", file=sys.stderr)

    user_data = None
    if args.cloud_init and os.path.exists(args.cloud_init):
        user_data = open(args.cloud_init).read()
        if len(user_data.encode()) > 32768:
            sys.exit("cloud-init exceeds Hetzner's 32KB user_data limit.")
    elif args.cloud_init:
        print("note: %s not found; creating without cloud-init." % args.cloud_init,
              file=sys.stderr)

    types = [t.strip() for t in args.types.split(",") if t.strip()]
    locs = [l.strip() for l in args.locations.split(",") if l.strip()]
    type_ids = {t: resolve_type_id(t, token) for t in types}
    for t, tid in type_ids.items():
        if tid is None:
            sys.exit("Unknown server type: %s" % t)

    print("Sniping %s across %s every %ss%s ..."
          % (types, locs, args.interval, "  [DRY RUN]" if args.dry_run else ""))
    tick = 0
    while True:
        tick += 1
        for t in types:
            hit = find_available_dc(type_ids[t], locs, token)
            if hit:
                dc, loc = hit
                print("[poll %d] %s AVAILABLE in %s (%s)" % (tick, t, loc, dc))
                if args.dry_run:
                    return
                st, body = create(args.name, t, dc, ssh_key, user_data, token)
                if st in (200, 201):
                    srv = body["server"]
                    ip = srv.get("public_net", {}).get("ipv4", {}).get("ip", "?")
                    print("\n=== CREATED %s (%s) in %s ===" % (t, args.name, dc))
                    print("Public IPv4: %s" % ip)
                    print("Next: ssh -A root@%s   then   ./bootstrap.sh" % ip)
                    return
                code = body.get("error", {}).get("code", "?")
                print("  create failed (%s / %s) — racing, keep polling" % (st, code),
                      file=sys.stderr)
        sys.stdout.write("[poll %d] none available; sleeping %ss\r" % (tick, args.interval))
        sys.stdout.flush()
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
