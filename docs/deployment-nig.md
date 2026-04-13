# Deployment on the NIG Supercomputer

This guide covers deploying sapporo-service on the DDBJ/NIG supercomputer using `podman-compose` and the Slurm REST API (`slurmrestd`). For the standard Docker-in-Docker deployment used by the public image, see [Installation](installation.md) and `compose.docker.yml`.

## Overview

```
Upstream Nginx (service-gateway-conf, managed separately)
    sapporo-dev.ddbj.nig.ac.jp     -> 172.19.15.12:1122  (a012)
    sapporo-staging.ddbj.nig.ac.jp -> 172.19.15.12:1121  (a012)
    sapporo.ddbj.nig.ac.jp         -> 172.19.15.11:1121  (a011)
            |
            v  HTTPS -> HTTP reverse proxy
Frontend node (a011 or a012, service account)
    podman-compose (rootless, userns=keep-id)
    +-- sapporo-service-<env>  (image: ghcr.io/sapporo-wes/sapporo-service)
          SAPPORO_RUN_SH=/app/sapporo_config/run.slurm.sh
            |
            | curl, X-SLURM-USER-TOKEN
            v
         slurmrestd  (a039:6820, API v0.0.39)
            |
            v
    Slurm compute node (partition=test)
        podman run --rm --userns=keep-id
            -v ${run_dir}:${run_dir}
            <engine container>
```

Key design points:

- Workflow engines run on Slurm compute nodes via `podman run`, not via Docker-in-Docker.
- The run directory is bind-mounted at the same host-absolute path on both the sapporo container and the compute node so that nested engine subcontainers (`cwltool` `DockerRequirement`, `nextflow` `process.container`, etc.) resolve paths identically.
- JWT authentication is handled by a shared Keycloak realm (`idp.ddbj.nig.ac.jp/realms/master`, client `sapporo`, public mode, `aud=account`).
- RO-Crate metadata is generated in the sapporo container after the Slurm job completes, because `sapporo-cli` is not installed on compute nodes.

## Environments

| Environment | Domain                           | Host | Port |
|-------------|----------------------------------|------|------|
| dev         | `sapporo-dev.ddbj.nig.ac.jp`     | a012 | 1122 |
| staging     | `sapporo-staging.ddbj.nig.ac.jp` | a012 | 1121 |
| prod        | `sapporo.ddbj.nig.ac.jp`         | a011 | 1121 |

`dev` and `staging` share host `a012`. Clone the repository into separate directories to avoid `.env` collisions (see [Day-to-Day Operations](#day-to-day-operations)).

## Prerequisites

- A NIG supercomputer account with home directory on the shared Lustre filesystem. This is required so Slurm compute nodes can read `${run_dir}` at the same absolute path as the sapporo container.
- `podman >= 4.9` and `podman-compose >= 1.0`.
- Subuid/subgid allocations for the service account (already configured for `sapporo-admin` on a011/a012).
- Network access to `slurmrestd` at `a039:6820` from the frontend node.
- A `sapporo` client registered in the Keycloak realm `https://idp.ddbj.nig.ac.jp/realms/master` (public client, default `aud=account`).

## Initial Setup

On the frontend node (a011 or a012, as the service account):

### 1. Clone

```bash
git clone https://github.com/sapporo-wes/sapporo-service.git
cd sapporo-service
```

### 2. Select environment

```bash
cp env.dev .env        # dev,      a012:1122
cp env.staging .env    # staging,  a012:1121
cp env.prod .env       # prod,     a011:1121
```

Edit `.env` to adjust `SLURM_CPUS_PER_TASK`, `SLURM_MEMORY_PER_CPU`, or `SAPPORO_EXTRA_PODMAN_ARGS` if needed.

### 3. Generate the Slurm connection file

```bash
bash scripts/update_slurm_env.sh
```

This resolves the slurmrestd IP, obtains a JWT via `scontrol token lifespan=604800`, and writes `sapporo_config/slurm.env` (git-ignored; contains short-lived secrets).

### 4. Pull workflow engine images to all compute nodes (first run only)

```bash
bash scripts/pull_wf_images.sh
```

The script enumerates Slurm nodes with `sinfo -N` and invokes `ssh <node> podman pull <image>` in parallel. Per-node logs land in `logs/pull-wf-images-*.log`.

### 5. Create the run directory and start the service

```bash
mkdir -p "runs-$(grep '^SAPPORO_ENV=' .env | cut -d= -f2)"
podman-compose up -d
```

### 6. Verify

```bash
bash scripts/healthcheck.sh
```

The healthcheck verifies the container state, `/service-info` response, slurmrestd reachability, and the Keycloak OIDC discovery endpoint.

## Day-to-Day Operations

### JWT rotation (required)

The Slurm JWT has `lifespan=604800s` (7 days). Register a crontab entry on the frontend node to refresh it daily:

```cron
# Refresh Slurm JWT daily at 03:00
0 3 * * * cd /home/sapporo-admin/sapporo-<env> && bash scripts/update_slurm_env.sh >> logs/slurm-token-update.log 2>&1
```

`run.slurm.sh` re-sources `sapporo_config/slurm.env` on every job submission, so there is no need to restart the sapporo container after a refresh.

### Logs

```bash
podman-compose logs -f --tail=100 sapporo
```

Per-run artifacts are under `runs-<env>/xx/<run_id>/`:

- `state.txt` — current run state
- `stdout.log`, `stderr.log` — engine output captured by the Slurm job
- `slurm.jobid` — Slurm job id assigned by `slurmrestd`
- `slurm.sh` — the generated Slurm job script
- `ro-crate-metadata.json` — RO-Crate metadata (written in the sapporo container after completion)

### Upgrading the image

```bash
# 1. Edit .env: SAPPORO_VERSION=2.x.x
podman-compose pull
podman-compose up -d
```

### Submitting a workflow under authentication

The Keycloak client uses `public` mode, so sapporo's own `/token` endpoint is disabled. Obtain a token directly from Keycloak:

```bash
TOKEN=$(curl -s -X POST \
  "https://idp.ddbj.nig.ac.jp/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=sapporo" \
  -d "username=<your_user>" \
  -d "password=<your_password>" \
  | jq -r .access_token)

curl -H "Authorization: Bearer ${TOKEN}" http://localhost:1122/runs
```

`scripts/smoketest.sh` reads the token from `SAPPORO_TEST_TOKEN`:

```bash
export SAPPORO_TEST_TOKEN="${TOKEN}"
bash scripts/smoketest.sh
```

### Running dev and staging on the same host (a012)

Clone the repository into two separate working directories so each has its own `.env`:

```
~/sapporo-dev/
    .env            # from env.dev
    runs-dev/
    sapporo_config/slurm.env   # generated
~/sapporo-staging/
    .env            # from env.staging
    runs-staging/
    sapporo_config/slurm.env   # generated
```

The `container_name`, network name, and `SAPPORO_PORT` are already parameterised by `SAPPORO_ENV`, so the two stacks coexist without collision. Keeping them in separate directories prevents accidental mix-ups in `.env`.

## Customisation

### Additional volume mounts for workflows

To expose a read-only reference directory to every workflow engine container, set `SAPPORO_EXTRA_PODMAN_ARGS` in `.env`:

```bash
SAPPORO_EXTRA_PODMAN_ARGS="-v /lustre9/open/shared/references:/lustre9/open/shared/references:ro"
```

`run.slurm.sh` appends this to every `podman run` invocation on the compute node, across all supported engines. For backwards compatibility the variable also reads `SAPPORO_EXTRA_DOCKER_ARGS` if `SAPPORO_EXTRA_PODMAN_ARGS` is unset.

### Adjusting Slurm resources

Edit `.env` and re-run `scripts/update_slurm_env.sh`:

```bash
SLURM_PARTITION=test
SLURM_CPUS_PER_TASK=8
SLURM_MEMORY_PER_CPU=8192
```

`run.slurm.sh` re-reads `sapporo_config/slurm.env` on the next job submission.

## Troubleshooting

| Symptom | Investigation |
|---|---|
| Container fails to start | `podman-compose logs sapporo` |
| `401 Unauthorized` | Decode the JWT and confirm `aud=account`; check `sapporo_config/auth_config.json` |
| `POST /runs` returns 500 | `podman-compose exec sapporo cat /app/sapporo_config/slurm.env` (missing or expired JWT?) |
| State stuck in `RUNNING` | `cat runs-<env>/xx/<run_id>/slurm.jobid`; query slurmrestd directly for the job state |
| `EXECUTOR_ERROR` | `cat runs-<env>/xx/<run_id>/stderr.log` |
| Outputs list empty | Inspect the worker-side `generate_outputs_list` in the generated `slurm.sh`; check `runs-<env>/xx/<run_id>/outputs/` |
| RO-Crate has `{"@error": "..."}` | Run `sapporo-cli generate-ro-crate runs-<env>/xx/<run_id>` manually and inspect stderr |
| Compute node reports image not found | `bash scripts/pull_wf_images.sh --node <node>` |
| dev and staging collide on `a012` | Use separate checkout directories; never share a single `.env` |

## Reference

- `compose.yml` — NIG `podman-compose` definition (this deployment)
- `compose.docker.yml` — legacy Docker-in-Docker definition
- `env.dev` / `env.staging` / `env.prod` — environment-specific values
- `sapporo_config/run.slurm.sh` — Slurm REST API + podman engine runners
- `sapporo_config/auth_config.json` — Keycloak external mode configuration
- `scripts/update_slurm_env.sh` — JWT refresh and `slurm.env` generation
- `scripts/pull_wf_images.sh` — multi-node image pull
- `scripts/healthcheck.sh` — container/API/slurmrestd/Keycloak probes
- `scripts/smoketest.sh` — trivial snakemake end-to-end test
- Related: [`ddbj/dfast`](https://github.com/ddbj/dfast) uses the same slurm+podman pattern as a reference implementation
