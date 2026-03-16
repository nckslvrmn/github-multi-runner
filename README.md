# github-multi-runner

Runs multiple GitHub Actions self-hosted runners from a single container, configured via a JSON file. No custom Docker image — just an entrypoint script mounted into the official `ghcr.io/actions/actions-runner` image.

Runners are re-registered on each startup. The config file is watched at runtime: new runners are launched automatically, changed runners are restarted, and removed runners are stopped.

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
    environment:
      - GITHUB_TOKEN=${GITHUB_TOKEN}
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

## Live config updates

The entrypoint polls `runners.json` every `CONFIG_POLL_INTERVAL` seconds. Changes take effect automatically:

- **New runner added** → registered and started
- **Runner config changed** (any field) → gracefully stopped, re-registered, restarted
- **Runner removed** → gracefully stopped

## Graceful shutdown

When a runner is stopped (due to a config change, removal, or container shutdown), the entrypoint:

1. Touches a drain file so the restart loop won't re-launch the runner
2. Fetches a removal token from the GitHub API and calls `config.sh remove` to deregister the runner — GitHub stops sending it new jobs
3. Waits for `run.sh` to exit naturally after the current job completes

If the removal token cannot be fetched, it falls back to SIGTERM. On container shutdown (`docker stop`), all runners drain concurrently before the process exits.

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
