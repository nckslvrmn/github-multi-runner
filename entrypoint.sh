#!/usr/bin/env bash
set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:?ERROR: GITHUB_TOKEN environment variable is required}"
CONFIG_PATH="${RUNNERS_CONFIG:-/config/runners.json}"
CONFIG_POLL_INTERVAL="${CONFIG_POLL_INTERVAL:-30}"
BASE_DIR="/home/runner"
RUNNERS_DIR="/runners"

declare -A RUNNER_PIDS
declare -A RUNNER_HASHES
declare -A RUNNER_META  # name -> "scope|target"

# --- GitHub API ---

github_post() {
    curl -sf -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d '{}' \
        "https://api.github.com$1"
}

registration_token() {
    local scope="$1" target="$2" path
    case "$scope" in
        org)        path="/orgs/$target/actions/runners/registration-token" ;;
        repo)       path="/repos/$target/actions/runners/registration-token" ;;
        enterprise) path="/enterprises/$target/actions/runners/registration-token" ;;
        *)          echo "ERROR: Unknown scope '$scope'" >&2; exit 1 ;;
    esac
    github_post "$path" | jq -r '.token'
}

removal_token() {
    local scope="$1" target="$2" path
    case "$scope" in
        org)        path="/orgs/$target/actions/runners/remove-token" ;;
        repo)       path="/repos/$target/actions/runners/remove-token" ;;
        enterprise) path="/enterprises/$target/actions/runners/remove-token" ;;
        *)          echo "ERROR: Unknown scope '$scope'" >&2; return 1 ;;
    esac
    github_post "$path" | jq -r '.token'
}

runner_url() {
    local scope="$1" target="$2"
    [ "$scope" = "enterprise" ] \
        && echo "https://github.com/enterprises/$target" \
        || echo "https://github.com/$target"
}

# --- Runner lifecycle ---

runner_hash() {
    echo "$1|$2|$3|$4" | sha256sum | cut -d' ' -f1
}

read_runner_row() {
    jq -r ".runners[$1] | [.name, .scope, .target, (.labels // [] | join(\",\"))] | join(\"\t\")" "$CONFIG_PATH"
}

setup_runner() {
    local name="$1" scope="$2" target="$3" labels="$4"
    local runner_dir="$RUNNERS_DIR/$name"

    # Deregister any previous registration before wiping the directory.
    # This clears the GitHub-side broker session so a restarted container
    # doesn't hit "session already exists" conflicts.
    if [ -f "$runner_dir/.runner" ]; then
        echo "[$name] Removing previous registration..."
        local remove_token
        if remove_token=$(removal_token "$scope" "$target" 2>/dev/null); then
            su -s /bin/bash runner -c "cd '$runner_dir' && ./config.sh remove --token '$remove_token'" 2>/dev/null || true
        else
            echo "[$name] Warning: could not get removal token, proceeding anyway." >&2
        fi
    fi

    echo "[$name] Preparing runner directory..."
    rm -rf "$runner_dir"
    cp -a "$BASE_DIR/." "$runner_dir"
    chown -R runner:runner "$runner_dir"

    echo "[$name] Fetching registration token..."
    local token url
    token=$(registration_token "$scope" "$target")
    url=$(runner_url "$scope" "$target")

    local config_cmd="$runner_dir/config.sh --url '$url' --token '$token' --name '$name' --unattended --replace"
    [ -n "$labels" ] && config_cmd="$config_cmd --labels '$labels'"

    echo "[$name] Registering ($scope: $target)..."
    su -s /bin/bash runner -c "$config_cmd"
    echo "[$name] Registered."
}

run_runner() {
    local name="$1" runner_dir="$RUNNERS_DIR/$1"
    local drain_file="/tmp/drain-$name"
    while [ ! -f "$drain_file" ]; do
        su -s /bin/bash runner -c "cd '$runner_dir' && ./run.sh" || true
        if [ ! -f "$drain_file" ]; then
            echo "[$name] Exited, restarting in 5s..." >&2
            sleep 5
        fi
    done
    rm -f "$drain_file"
    echo "[$name] Drained." >&2
}

start_runner() {
    local name="$1" scope="$2" target="$3" labels="$4"
    setup_runner "$name" "$scope" "$target" "$labels"
    run_runner "$name" &
    RUNNER_PIDS["$name"]=$!
    RUNNER_HASHES["$name"]=$(runner_hash "$name" "$scope" "$target" "$labels")
    RUNNER_META["$name"]="$scope|$target"
}

stop_runner() {
    local name="$1" pid="${RUNNER_PIDS[$1]:-}"
    [ -n "$pid" ] || return

    local scope target
    scope=$(cut -d'|' -f1 <<< "${RUNNER_META[$name]}")
    target=$(cut -d'|' -f2 <<< "${RUNNER_META[$name]}")
    local runner_dir="$RUNNERS_DIR/$name"

    # Signal the restart loop not to re-launch after the current run.sh exits
    touch "/tmp/drain-$name"

    # Deregister from GitHub — runner will finish its current job then exit cleanly
    echo "[$name] Deregistering (waiting for current job to finish)..."
    local token
    if token=$(removal_token "$scope" "$target" 2>/dev/null); then
        su -s /bin/bash runner -c "cd '$runner_dir' && ./config.sh remove --token '$token'" 2>/dev/null || true
    else
        echo "[$name] Warning: could not get removal token, falling back to SIGTERM." >&2
        kill "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || true
    unset "RUNNER_PIDS[$name]" "RUNNER_HASHES[$name]" "RUNNER_META[$name]"
}

# --- Docker socket ---

fix_docker_socket() {
    local sock="/var/run/docker.sock"
    if [ ! -S "$sock" ]; then
        echo "Warning: Docker socket not found — Docker will not work in workflows." >&2
        return
    fi
    local gid
    gid=$(stat -c '%g' "$sock")
    groupadd -f -g "$gid" docker-host
    usermod -aG docker-host runner
    echo "Docker socket GID $gid assigned to runner user."
}

# --- Config watcher ---

watch_config() {
    while true; do
        sleep "$CONFIG_POLL_INTERVAL"

        local count
        count=$(jq '.runners | length' "$CONFIG_PATH" 2>/dev/null) || continue

        local current_names="" i row name scope target labels hash
        for i in $(seq 0 $((count - 1))); do
            row=$(read_runner_row "$i")
            name=$(cut -f1 <<< "$row")
            scope=$(cut -f2 <<< "$row")
            target=$(cut -f3 <<< "$row")
            labels=$(cut -f4 <<< "$row")
            hash=$(runner_hash "$name" "$scope" "$target" "$labels")
            current_names="$current_names $name "

            if [ -z "${RUNNER_PIDS[$name]:-}" ]; then
                echo "[watch] New runner '$name' detected, starting..."
                start_runner "$name" "$scope" "$target" "$labels" \
                    || echo "[watch] ERROR: failed to start '$name', will retry next cycle." >&2
            elif [ "${RUNNER_HASHES[$name]:-}" != "$hash" ]; then
                echo "[watch] Config changed for '$name', restarting..."
                stop_runner "$name"
                start_runner "$name" "$scope" "$target" "$labels" \
                    || echo "[watch] ERROR: failed to restart '$name', will retry next cycle." >&2
            fi
        done

        for name in "${!RUNNER_PIDS[@]}"; do
            if [[ "$current_names" != *" $name "* ]]; then
                echo "[watch] Runner '$name' removed from config, stopping..."
                stop_runner "$name"
            fi
        done
    done
}

# --- Main ---

[ -f "$CONFIG_PATH" ] || { echo "ERROR: Config not found at $CONFIG_PATH" >&2; exit 1; }
runner_count=$(jq '.runners | length' "$CONFIG_PATH")
[ "$runner_count" -gt 0 ] || { echo "ERROR: No runners defined in config" >&2; exit 1; }

fix_docker_socket
mkdir -p "$RUNNERS_DIR"

for i in $(seq 0 $((runner_count - 1))); do
    row=$(read_runner_row "$i")
    name=$(cut -f1 <<< "$row")
    scope=$(cut -f2 <<< "$row")
    target=$(cut -f3 <<< "$row")
    labels=$(cut -f4 <<< "$row")
    start_runner "$name" "$scope" "$target" "$labels"
done

echo "Started $runner_count runner(s). Watching config every ${CONFIG_POLL_INTERVAL}s..."
watch_config &
WATCHER_PID=$!

cleanup() {
    echo "Shutting down..."
    kill "$WATCHER_PID" 2>/dev/null || true
    for name in "${!RUNNER_PIDS[@]}"; do
        stop_runner "$name"
    done
    exit 0
}
trap cleanup SIGTERM SIGINT

wait
