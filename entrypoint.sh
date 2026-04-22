#!/usr/bin/env bash
set -euo pipefail

GITHUB_TOKEN="${GITHUB_TOKEN:?ERROR: GITHUB_TOKEN environment variable is required}"
CONFIG_PATH="${RUNNERS_CONFIG:-/config/runners.json}"
CONFIG_POLL_INTERVAL="${CONFIG_POLL_INTERVAL:-30}"
LOG_DIR="${LOG_DIR:-/runners/_logs}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-52428800}"  # 50 MiB
LOG_KEEP="${LOG_KEEP:-3}"
GITHUB_API_RETRIES="${GITHUB_API_RETRIES:-5}"
BASE_DIR="/home/runner"
RUNNERS_DIR="/runners"

declare -A RUNNER_PIDS
declare -A RUNNER_HASHES
declare -A RUNNER_META     # name -> "scope|target"
SHUTTING_DOWN=0

# --- Manager logging (stdout only, concise) ---

_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
mlog()  { printf '[manager] %s %s\n'       "$(_ts)" "$*"; }
mwarn() { printf '[manager] %s WARN  %s\n' "$(_ts)" "$*" >&2; }
merr()  { printf '[manager] %s ERROR %s\n' "$(_ts)" "$*" >&2; }

runner_log_path() { printf '%s/%s.log' "$LOG_DIR" "$1"; }

rotate_log() {
    local f="$1" size i
    [ -f "$f" ] || return 0
    size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    [ "$size" -lt "$LOG_MAX_BYTES" ] && return 0
    for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
        [ -f "$f.$i" ] && mv -f "$f.$i" "$f.$((i + 1))"
    done
    mv -f "$f" "$f.1"
    : > "$f"
}

# Append to per-runner log with a header so boundaries are obvious.
runner_log() {
    local name="$1" header="$2"
    local f; f=$(runner_log_path "$name")
    rotate_log "$f"
    printf '\n=== %s %s ===\n' "$(_ts)" "$header" >> "$f"
}

# --- GitHub API ---

github_post() {
    local path="$1" attempt resp http_code
    for (( attempt = 1; attempt <= GITHUB_API_RETRIES; attempt++ )); do
        resp=$(curl -sS -o /tmp/ghresp.$$ -w '%{http_code}' -X POST \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -H "Content-Type: application/json" \
            -d '{}' \
            "https://api.github.com$path" 2>/dev/null) || resp="000"
        http_code="$resp"
        if [[ "$http_code" =~ ^2 ]]; then
            cat /tmp/ghresp.$$
            rm -f /tmp/ghresp.$$
            return 0
        fi
        mwarn "GitHub API $path returned HTTP $http_code (attempt $attempt/$GITHUB_API_RETRIES)"
        sleep $(( attempt * 2 ))
    done
    rm -f /tmp/ghresp.$$
    return 1
}

registration_token() {
    local scope="$1" target="$2" path
    case "$scope" in
        org)        path="/orgs/$target/actions/runners/registration-token" ;;
        repo)       path="/repos/$target/actions/runners/registration-token" ;;
        enterprise) path="/enterprises/$target/actions/runners/registration-token" ;;
        *)          merr "unknown scope '$scope'"; return 1 ;;
    esac
    github_post "$path" | jq -r '.token'
}

removal_token() {
    local scope="$1" target="$2" path
    case "$scope" in
        org)        path="/orgs/$target/actions/runners/remove-token" ;;
        repo)       path="/repos/$target/actions/runners/remove-token" ;;
        enterprise) path="/enterprises/$target/actions/runners/remove-token" ;;
        *)          merr "unknown scope '$scope'"; return 1 ;;
    esac
    github_post "$path" | jq -r '.token'
}

runner_url() {
    local scope="$1" target="$2"
    [ "$scope" = "enterprise" ] \
        && echo "https://github.com/enterprises/$target" \
        || echo "https://github.com/$target"
}

# --- Config reading (atomic-safe) ---

read_config_runners() {
    # Retries handle editor atomic-replace windows where the file is briefly
    # empty or partially written.
    local attempt out
    for attempt in 1 2 3; do
        if out=$(jq -c '.runners // []' "$CONFIG_PATH" 2>/dev/null) \
           && [ -n "$out" ] && [ "$out" != "null" ]; then
            printf '%s' "$out"
            return 0
        fi
        sleep 1
    done
    return 1
}

read_runner_row() {
    # Args: <json array of runners> <index>
    jq -r ".[$2] | [.name, .scope, .target, (.labels // [] | join(\",\"))] | join(\"\t\")" <<< "$1"
}

# --- Runner lifecycle ---

runner_hash() { echo "$1|$2|$3|$4" | sha256sum | cut -d' ' -f1; }

setup_runner() {
    local name="$1" scope="$2" target="$3" labels="$4"
    local runner_dir="$RUNNERS_DIR/$name"
    local log_file; log_file=$(runner_log_path "$name")
    local want_hash; want_hash=$(runner_hash "$name" "$scope" "$target" "$labels")

    # Preserve existing registration when config is unchanged. Makes container
    # restarts (with a persisted /runners volume) and unrelated config edits
    # non-disruptive — no deregister/re-register thrash.
    if [ -f "$runner_dir/.runner" ] \
       && [ -f "$runner_dir/.config-hash" ] \
       && [ "$(cat "$runner_dir/.config-hash" 2>/dev/null)" = "$want_hash" ]; then
        mlog "[$name] existing registration matches config, reusing"
        return 0
    fi

    runner_log "$name" "setup begin ($scope:$target)"

    # Subshell so an internal failure only aborts setup, not the whole script.
    (
        set -e
        if [ -f "$runner_dir/.runner" ]; then
            echo "removing previous registration..."
            rt=$(removal_token "$scope" "$target" 2>/dev/null) || rt=""
            if [ -n "$rt" ]; then
                su -s /bin/bash runner -c "cd '$runner_dir' && ./config.sh remove --token '$rt'" || true
            else
                echo "WARN: could not get removal token, proceeding anyway."
            fi
        fi

        echo "preparing runner directory..."
        rm -rf "$runner_dir"
        cp -a "$BASE_DIR/." "$runner_dir"
        chown -R runner:runner "$runner_dir"

        echo "fetching registration token..."
        token=$(registration_token "$scope" "$target") \
            || { echo "ERROR: registration token fetch failed"; exit 1; }
        url=$(runner_url "$scope" "$target")

        config_cmd="$runner_dir/config.sh --url '$url' --token '$token' --name '$name' --unattended --replace"
        [ -n "$labels" ] && config_cmd="$config_cmd --labels '$labels'"

        echo "registering..."
        su -s /bin/bash runner -c "$config_cmd"
        echo "registered."
    ) >> "$log_file" 2>&1 || return 1

    echo "$want_hash" > "$runner_dir/.config-hash"
    mlog "[$name] registered ($scope:$target)"
}

run_runner() {
    local name="$1" runner_dir="$RUNNERS_DIR/$1"
    local drain_file="/tmp/drain-$name"
    local log_file; log_file=$(runner_log_path "$name")
    local fails=0

    while [ ! -f "$drain_file" ]; do
        runner_log "$name" "run.sh start"
        if su -s /bin/bash runner -c "cd '$runner_dir' && ./run.sh" >> "$log_file" 2>&1; then
            fails=0
        else
            fails=$(( fails + 1 ))
        fi
        printf '=== %s run.sh exited (fails=%d) ===\n' "$(_ts)" "$fails" >> "$log_file"

        [ -f "$drain_file" ] && break

        local delay
        if (( fails < 6 )); then delay=$(( fails * 5 + 5 )); else delay=30; fi
        mwarn "[$name] run.sh exited (fails=$fails); restarting in ${delay}s (log: $log_file)"
        sleep "$delay"
    done

    rm -f "$drain_file"
    mlog "[$name] drained"
}

start_runner() {
    local name="$1" scope="$2" target="$3" labels="$4"
    if ! setup_runner "$name" "$scope" "$target" "$labels"; then
        merr "[$name] setup failed"
        return 1
    fi
    run_runner "$name" &
    RUNNER_PIDS["$name"]=$!
    RUNNER_HASHES["$name"]=$(runner_hash "$name" "$scope" "$target" "$labels")
    RUNNER_META["$name"]="$scope|$target"
    mlog "[$name] started (pid=${RUNNER_PIDS[$name]})"
}

stop_runner() {
    local name="$1" pid="${RUNNER_PIDS[$1]:-}"
    [ -n "$pid" ] || return 0

    local scope target
    IFS='|' read -r scope target <<< "${RUNNER_META[$name]:-|}"
    local runner_dir="$RUNNERS_DIR/$name"
    local log_file; log_file=$(runner_log_path "$name")

    # Prevent the restart loop from re-launching once run.sh exits.
    touch "/tmp/drain-$name"

    mlog "[$name] deregistering (waiting for any in-flight job to finish)"
    runner_log "$name" "deregister begin"
    local rt
    if [ -n "$scope" ] && rt=$(removal_token "$scope" "$target" 2>/dev/null); then
        su -s /bin/bash runner -c "cd '$runner_dir' && ./config.sh remove --token '$rt'" >> "$log_file" 2>&1 || true
    else
        mwarn "[$name] removal token unavailable, sending SIGTERM to runner"
        kill "$pid" 2>/dev/null || true
    fi

    wait "$pid" 2>/dev/null || true
    rm -f "$runner_dir/.config-hash"
    unset "RUNNER_PIDS[$name]" "RUNNER_HASHES[$name]" "RUNNER_META[$name]"
    mlog "[$name] stopped"
}

# --- Docker socket ---

fix_docker_socket() {
    local sock="/var/run/docker.sock"
    if [ ! -S "$sock" ]; then
        mwarn "Docker socket not found — Docker will not work in workflows"
        return
    fi
    local gid
    gid=$(stat -c '%g' "$sock")
    groupadd -f -g "$gid" docker-host
    usermod -aG docker-host runner
    mlog "docker socket GID $gid granted to runner user"
}

# --- Reconciler ---

reconcile() {
    local runners_json count i row name scope target labels hash seen=""
    runners_json=$(read_config_runners) || { mwarn "config unreadable, skipping reconcile"; return; }
    count=$(jq 'length' <<< "$runners_json")

    for (( i = 0; i < count; i++ )); do
        row=$(read_runner_row "$runners_json" "$i")
        IFS=$'\t' read -r name scope target labels <<< "$row"
        [ -z "$name" ] && { mwarn "skipping unnamed runner at index $i"; continue; }
        hash=$(runner_hash "$name" "$scope" "$target" "$labels")
        seen="$seen $name "

        if [ -z "${RUNNER_PIDS[$name]:-}" ]; then
            mlog "[reconcile] new runner '$name'"
            start_runner "$name" "$scope" "$target" "$labels" \
                || merr "[reconcile] failed to start '$name' (will retry next cycle)"
        elif [ "${RUNNER_HASHES[$name]:-}" != "$hash" ]; then
            mlog "[reconcile] config changed for '$name'"
            stop_runner "$name"
            start_runner "$name" "$scope" "$target" "$labels" \
                || merr "[reconcile] failed to restart '$name' (will retry next cycle)"
        elif ! kill -0 "${RUNNER_PIDS[$name]}" 2>/dev/null && [ ! -f "/tmp/drain-$name" ]; then
            # Runner subshell died unexpectedly.
            mwarn "[reconcile] '$name' subshell died; respawning"
            unset "RUNNER_PIDS[$name]" "RUNNER_HASHES[$name]" "RUNNER_META[$name]"
            start_runner "$name" "$scope" "$target" "$labels" \
                || merr "[reconcile] failed to respawn '$name'"
        fi
    done

    for name in "${!RUNNER_PIDS[@]}"; do
        if [[ "$seen" != *" $name "* ]]; then
            mlog "[reconcile] '$name' removed from config"
            stop_runner "$name"
        fi
    done
}

# --- Main ---

[ -f "$CONFIG_PATH" ] || { merr "config not found at $CONFIG_PATH"; exit 1; }
mkdir -p "$RUNNERS_DIR" "$LOG_DIR"

initial_runners=$(read_config_runners) || { merr "initial config unreadable"; exit 1; }
initial_count=$(jq 'length' <<< "$initial_runners")
[ "$initial_count" -gt 0 ] || { merr "no runners defined in config"; exit 1; }

fix_docker_socket

mlog "starting $initial_count runner(s); per-runner logs in $LOG_DIR"
for (( i = 0; i < initial_count; i++ )); do
    row=$(read_runner_row "$initial_runners" "$i")
    IFS=$'\t' read -r name scope target labels <<< "$row"
    start_runner "$name" "$scope" "$target" "$labels" \
        || merr "[$name] initial start failed (will retry on next reconcile)"
done
mlog "polling config every ${CONFIG_POLL_INTERVAL}s"

cleanup() {
    [ "$SHUTTING_DOWN" -eq 1 ] && return
    SHUTTING_DOWN=1
    mlog "shutdown requested; draining all runners concurrently"
    local name
    for name in "${!RUNNER_PIDS[@]}"; do
        stop_runner "$name" &
    done
    wait
    mlog "shutdown complete"
    exit 0
}
trap cleanup SIGTERM SIGINT

# Signal-interruptible poll: backgrounded sleep + wait lets the trap fire
# immediately rather than after the full poll interval.
while [ "$SHUTTING_DOWN" -eq 0 ]; do
    sleep "$CONFIG_POLL_INTERVAL" &
    wait $! 2>/dev/null || true
    [ "$SHUTTING_DOWN" -eq 1 ] && break
    reconcile
done
