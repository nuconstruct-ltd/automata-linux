# Toolkit — CVM Deployment CLI

## Project overview

Native Rust CLI (`toolkit`) for deploying Confidential VMs (TDX/SEV-SNP) to GCP. Single binary, single YAML config file. No gcloud/gsutil CLI needed — uses native GCP SDK + REST API.

## Build & run

```bash
cargo build -p toolkit --release
./target/release/toolkit deploy --config workload-stage/cvm-stage.yaml
```

## Key directories

- `crates/toolkit/src/` — Rust CLI source (commands, cloud/gcp SDK, disk ops, agent client, workload templates)
- `crates/toolkit/src/templates/` — Embedded templates (docker-compose.yml, configs, scripts) — compiled into binary via `include_str!`
- `disktools/` — Docker image for disk operations (mount, partition expand, workload inject, token gen)
- `controller/` — Network isolation controller (Rust, separate container)
- `operator/` — SSH operator container
- `workload-stage/` — Staging deployment config + secrets (gitignored)
- `scripts/` — Legacy bash scripts (reference only, not used by toolkit)

## Config structure

`cvm.yaml` has per-service env grouping:
```yaml
env:
  tool_node: { NETWORK, RELAY_SECRET_KEY, ... }
  lighthouse: { CHECKPOINT_SYNC_URL, ... }
  logging: { LOKI_HOST, LOKI_USER, LOKI_PASSWORD }
  metrics: { METRICS_HOST, METRICS_USER, METRICS_PASSWORD }
  caddy: { CADDY_RPC_DOMAIN, ... }
  operator: { SSH_PUBLIC_KEY }
```
All sections flattened into single `.env` at deploy time.

`operator_ports` — custom ports added to controller's docker-compose port mappings (operator uses `network_mode: "service:controller"`).

## Template substitution

Two layers:
- `{{VAR}}` — resolved at Rust template write time (image names, operator ports)
- `${VAR}` — resolved by podman-compose at runtime from `.env`

Image names MUST use `{{}}` (hardcoded in compose) because CVM agent passes `${VAR}` literally to `podman pull`.

## GCP SDK

- Compute: `google-cloud-compute-v1` crate with feature gates per resource type
- Storage: `gcp_auth` + `reqwest` REST API (simpler than the storage crate)
- Auth: Application Default Credentials (`gcloud auth application-default login`)
- Must install rustls crypto provider before TLS operations

## Disk operations

`disktools/disk-ops.sh` runs in Docker (`--privileged`). Uses `pigz` for parallel compression and raw disk cache at `/cache`.

Primary command: `prepare-disk` (single mount cycle for workload + token).

## Testing

- Deploy: `toolkit deploy --config workload-stage/cvm-stage.yaml`
- Verify: `toolkit measurements --config workload-stage/cvm-stage.yaml`
- Update: `toolkit update --config workload-stage/cvm-stage.yaml`
- Logs: `toolkit logs --config workload-stage/cvm-stage.yaml`
- Destroy: `toolkit destroy --config workload-stage/cvm-stage.yaml`

## Important constraints

- PCR23 is NOT affected by `.env` changes — only by docker-compose.yml content and container image digests
- TDX regions: asia-southeast1, europe-west4, us-central1 only
- c3-standard-* requires pd-ssd and maintenance-policy=TERMINATE
- Cloud metadata (169.254.169.254) unreachable from TDX VMs — use secrets/identity.env
- `losetup -fP` doesn't create partition nodes in Docker — use `kpartx`
