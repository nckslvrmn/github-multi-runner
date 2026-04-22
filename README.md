# github-multi-runner

Runs multiple GitHub Actions self-hosted runners from a single container, configured via a JSON file. No custom Docker image — just an entrypoint script mounted into the official `ghcr.io/actions/actions-runner` image.

The config file is watched at runtime: new runners are launched automatically, changed runners are restarted, unchanged runners are left alone, and removed runners are gracefully drained. Each runner writes its own log file, and the container's stdout carries only the manager's summary events.

## Prerequisites

- Docker and Docker Compose on the host
- A GitHub personal access token (PAT) with runner registration permissions (see below)

## PAT scopes

**Classic PAT:**
- `repo` — required for repository-scoped runners
- `manage_runners:org` — required for organization-scoped runners
- `manage_runners:enterprise` — required for enterprise-scoped runners

**Fine-grained PAT:**
- Repository runners: "Administration" permission (read/write) on each target repo
- Organization runners: "Self-hosted runners" permission (read/write) on the target org

A single PAT can cover multiple scopes. Store it as `GITHUB_TOKEN` in your environment.

## Configuration

Copy `runners.example.json` to `runners.json` and define your runners:

```json
{
  "runners": [
    { "name": "my-org", "scope": "org", "target": "my-github-org" },
    { "name": "my-repo", "scope": "repo", "target": "myuser/my-repo" }
  ]
}
```

### Fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Unique name for this runner, shown in GitHub Actions UI |
| `scope` | Yes | `org`, `repo`, or `enterprise` |
| `target` | Yes | Org name, `owner/repo`, or enterprise slug depending on scope |
| `labels` | No | Array of labels. Defaults to the runner's built-in defaults |

## Deployment

Copy `docker-compose.example.yml` to `docker-compose.yml` and adjust as needed:

```yaml
services:
  github-runner:
    image: ghcr.io/actions/actions-runner:2.332.0
    user: root
    entrypoint: ["/bin/bash", "/config/entrypoint.sh"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./entrypoint.sh:/config/entrypoint.sh:ro
      - ./runners.json:/config/runners.json:ro
      - ./state:/runners
      - ./logs:/runners/_logs
    environment:
      - GITHUB_TOKEN=${GITHUB_TOKEN}
    stop_grace_period: 5m
    restart: unless-stopped
```

Then run:

```sh
GITHUB_TOKEN=your_pat docker compose up -d
```

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `GITHUB_TOKEN` | Yes | — | PAT used to generate runner registration tokens |
| `RUNNERS_CONFIG` | No | `/config/runners.json` | Path to the runners config file inside the container |
| `CONFIG_POLL_INTERVAL` | No | `30` | Seconds between config file checks for live updates |
| `LOG_DIR` | No | `/runners/_logs` | Directory for per-runner log files |
| `LOG_MAX_BYTES` | No | `52428800` | Size threshold (bytes) at which a runner log is rotated |
| `LOG_KEEP` | No | `3` | Number of rotated log files to keep per runner |
| `GITHUB_API_RETRIES` | No | `5` | Max attempts (with backoff) for token fetches against the GitHub API |

## Logging

Stdout carries only manager-level events (one line per start/stop/reconcile). Each runner's full output — `config.sh`, `run.sh`, and deregistration — goes to `${LOG_DIR}/<name>.log`, which rotates at `LOG_MAX_BYTES` (keeping `LOG_KEEP` older files as `<name>.log.1`, `.2`, …).

With the example `docker-compose.yml` binding `./logs:/runners/_logs`, you can tail logs from the host:

```sh
tail -F logs/my-org.log
```

## Live config updates

The entrypoint polls `runners.json` every `CONFIG_POLL_INTERVAL` seconds. Changes take effect automatically:

- **New runner added** → registered and started
- **Runner config changed** (any field) → gracefully stopped, re-registered, restarted
- **Runner removed** → gracefully stopped
- **Unrelated runners** are left untouched — editing one entry never bounces the others
- **Crashed runner** (subshell died outside of a drain) is detected on the next reconcile and respawned

Editor atomic-saves are tolerated: if `runners.json` is briefly empty or malformed during a write, the poll skips that cycle and retries.

## Registration persistence

With `/runners` bind-mounted (as in the example compose), each runner's registration is kept across container restarts. On boot, the entrypoint compares the on-disk config hash to the desired one and only re-registers when something actually changed. Without the bind mount, runners re-register on every start (the original behavior).

## Graceful shutdown

When a runner is stopped (due to a config change, removal, or container shutdown), the entrypoint:

1. Touches a drain file so the restart loop won't re-launch the runner
2. Fetches a removal token from the GitHub API and calls `config.sh remove` to deregister the runner — GitHub stops sending it new jobs
3. Waits for `run.sh` to exit naturally after the current job completes

If the removal token cannot be fetched (after `GITHUB_API_RETRIES` attempts with backoff), it falls back to SIGTERM. On container shutdown (`docker stop`), all runners drain concurrently before the process exits — set `stop_grace_period` in the compose file high enough to accommodate your longest job.

## Docker socket access

The container detects the GID of `/var/run/docker.sock` at startup and grants the runner user access automatically. No manual group configuration is needed on the host.

## Updating the runner version

Change the image tag in `docker-compose.yml`:

```yaml
image: ghcr.io/actions/actions-runner:2.332.0
```

Check the [actions/runner releases](https://github.com/actions/runner/releases) page for the latest version.

## Adding or removing runners

Edit `runners.json`. Running containers will pick up the change within `CONFIG_POLL_INTERVAL` seconds. To apply immediately, restart the container.

## Notes

- Each runner handles one job at a time. For concurrency on a given repo or org, add multiple entries to `runners.json`.
- Workflows in **public repositories** that target a self-hosted runner are a security risk — anyone can open a pull request and run code on your host. Use [environment protection rules](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) to require approval before jobs run.
