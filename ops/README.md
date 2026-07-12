# ops/ — provisioning a Medaka build box

Scripts for standing up a cloud box to run `make medaka` + the gate suite off a
local laptop (e.g. to escape a host DLP/endpoint scanner — see `docker/README.md`
for the same motivation, and note that on a real Linux box the whole
Docker-in-VM dance is unnecessary: no scanner, so the write storm runs directly
on the box's SSD).

## Why a sniper

Hetzner's **June 15 2026 price adjustment** raised the CPX (shared x86) and CCX
(dedicated x86) lines +144–176%, while the **cost-optimized CX (x86) and CAX
(ARM) lines rose only ~33–38%**. So the value box is now **CX53** (16 vCPU /
32 GB / 320 GB, ~€29.49/mo) — but during the 2026 AI-datacenter supply crunch,
everything larger than CX23 flickers in and out of stock across the EU DCs.
`snipe_hetzner.py` watches for a restock and grabs one automatically.

The compiler's checked-in seed (`compiler/seed/emitter.ll.gz`) carries no target
triple, so the same seed cold-bootstraps to **x86 or ARM** — the arch choice is
purely price/availability. CX53 (x86) is the current pick; `--types cax41`
snipes the ARM box instead with the identical `cloud-init.yaml`.

## Files

| File | Role |
|------|------|
| `snipe_hetzner.py` | Polls the Hetzner Cloud API for a target server type across preferred locations; creates ONE server (with `cloud-init.yaml` as user-data) on first restock, then exits. Stdlib-only. |
| `cloud-init.yaml` | First-boot provisioning: the `docker/Dockerfile` toolchain + Node 24. Drops `/root/bootstrap.sh`. No secrets — the private clone rides your forwarded SSH agent. |

## Runbook

One-time (Hetzner console): create a **Read & Write** API token; upload your
laptop SSH public key and note its name.

```sh
export HCLOUD_TOKEN=xxxxxxxx
export HCLOUD_SSH_KEY="my-laptop"     # name of the key in the project
# export HCLOUD_IMAGE=debian-13       # optional; default debian-12
ssh-add -l                             # confirm your GitHub key is in the agent

python3 ops/snipe_hetzner.py --dry-run          # safe: reports availability, creates nothing
python3 ops/snipe_hetzner.py --cloud-init ops/cloud-init.yaml   # arm it; leave running (tmux/nohup)
```

When it fires (prints the IP):

```sh
ssh -A root@<ip> 'cloud-init status --wait'    # let first-boot apt/node finish
ssh -A root@<ip>                                # -A forwards your agent for the private clone
./bootstrap.sh                                  # clone -> make medaka (cold seed) -> hook -> gates -> PASS/FAIL
```

### Notes
- Creates exactly one server (real ~€29.49/mo cost) then exits — no fleet.
- Default target order is `cx53,cx43`; append `,cx23` only as a last-resort
  beachhead (too small for the full parallel gate suite).
- Poll interval defaults to 45s (Hetzner limit is 3600 req/hr).
