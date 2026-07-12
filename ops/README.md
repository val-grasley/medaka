# ops/ — provisioning a Medaka build box

Scripts for standing up a box to run `make medaka` + the gate suite off a local
laptop (e.g. to escape a host DLP/endpoint scanner — see `docker/README.md` for
the same motivation; note that on a real Linux box the whole Docker-in-VM dance
is unnecessary: no scanner, so the write storm runs directly on the box's SSD).

The compiler's checked-in seed (`compiler/seed/emitter.ll.gz`) carries **no
target triple**, so the same seed cold-bootstraps to **x86 or ARM** — the arch
choice is purely price/availability, never a code constraint.

## Options considered (2026 supply crunch)

The AI-datacenter buildout is squeezing both cloud capacity and RAM/SSD prices
(DRAM ~2× YoY, no relief expected before 2027–28). Snapshot of what we weighed:

- **Netcup RS 4000 G12** ⭐ *(chosen)* — 12 **dedicated** EPYC 9645 cores /
  32 GB DDR5 ECC / 1 TB NVMe, ~€40/mo incl VAT, in stock. Dedicated cores (no
  noisy-neighbor steal) + NVMe suit the write-heavy parallel gate suite. Manual
  provisioning: install Debian in the SCP panel, then run `provision.sh`.
- **Hetzner Cloud CX53** — 16 shared vCPU / 32 GB / 320 GB, ~€29.49/mo, but
  stock *flickers* across EU DCs. Grab-on-restock via `snipe_hetzner.py`
  (fallback). Note Hetzner's June 2026 hike spared CX/CAX but raised CPX/CCX
  +144–176%, so avoid CPX/CCX.
- **Local used box** (parked fallback) — a used Ryzen desktop (cheap DDR4, low
  idle power) is the best-value "own the metal" play; the memory crunch rewards
  buying used *with RAM already installed*. Xeon workstations give max cores but
  ~€15–18/mo in idle power.

## Files

| File | Role |
|------|------|
| `provision.sh` | **Primary.** Self-contained: copy to any fresh Debian/Ubuntu box and run — toolchain + Node 24, private clone (forwarded ssh-agent), cold-bootstrap `make medaka`, hook, gates, PASS/FAIL banner. Works on Netcup, a local box, Hetzner CX, anything. |
| `snipe_hetzner.py` | *Hetzner fallback.* Polls the Cloud API for a server type across locations; creates one server (with `cloud-init.yaml`) on restock, then exits. Stdlib-only. |
| `cloud-init.yaml` | *Hetzner fallback.* First-boot user-data the sniper injects (same toolchain; drops `/root/bootstrap.sh`). No secrets. |

## Primary runbook — Netcup (or any box)

1. Provision the server (Netcup: install **Debian 12** via the SCP control panel).
2. From your laptop:

```sh
scp ops/provision.sh root@<ip>:      # one file; it clones the rest
ssh -A root@<ip>                      # -A forwards your ssh-agent for the private clone
ssh-add -l                            # (confirm your GitHub key is loaded first)
./provision.sh                        # deps -> make medaka (cold seed) -> hook -> gates -> PASS/FAIL
```

`provision.sh` ends with a `BUILD / SMOKE / GATES` banner. Re-runnable.

## Fallback runbook — Hetzner sniper

One-time (Hetzner console): create a **Read & Write** API token; upload your
laptop SSH public key and note its name.

```sh
export HCLOUD_TOKEN=xxxxxxxx
export HCLOUD_SSH_KEY="my-laptop"     # name of the key in the project
python3 ops/snipe_hetzner.py --dry-run                          # report availability, create nothing
python3 ops/snipe_hetzner.py --cloud-init ops/cloud-init.yaml   # arm it; leave running (tmux/nohup)
# on fire: ssh -A root@<ip> 'cloud-init status --wait'; ssh -A root@<ip>; ./bootstrap.sh
```

Notes: creates exactly one server then exits (no fleet); default target order
`cx53,cx43` (append `,cx23` only as a too-small last resort); 45s poll interval.
