#!/usr/bin/env bash
# Checks that dev_runner, the dev server (with a grandchild) and the app all exit when
# dev_runner's parent or the --watch-pid process (`zig`) gets SIGTERM or SIGKILL.
# Runs headlessly without GUI/desktop. Silent on success.

set -euo pipefail

DEV_RUNNER_BIN="${1:-$(dirname "$0")/../zig-out/bin/dev_runner}"
if [[ ! -x "$DEV_RUNNER_BIN" ]]; then
    echo "test-dev-cleanup: error: dev_runner binary not found or not executable at '$DEV_RUNNER_BIN'" >&2
    exit 1
fi

SLEEP_BIN="$(which sleep)"
if [[ ! -x "$SLEEP_BIN" ]]; then
    echo "test-dev-cleanup: error: sleep binary not found" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d /tmp/oriel-devcleanup-test.XXXXXX)"
mkdir -p "$TMP_DIR/src"

PIDS_TO_CLEANUP=()

cleanup() {
    # Ensure no processes are left behind even if the test fails
    # (dev server and app lead their own process groups: kill the groups too).
    # (`${a[@]+...}`: bash 3.2, macOS's, treats an empty array as unset.)
    for pid in ${PIDS_TO_CLEANUP[@]+"${PIDS_TO_CLEANUP[@]}"}; do
        kill -9 -- "-$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
    done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run_case() {
    local signal="$1" # SIGTERM or SIGKILL
    local mode="$2"   # parent or grandparent
    local run_dir="$TMP_DIR/$signal-$mode"
    mkdir -p "$run_dir/src"

    # Stand-ins for `zig` and the build runner: `zig build dev` runs
    # dev_runner from the build runner, a child of `zig`, and a signal sent
    # only to `zig` never reaches the build runner. In "parent" mode the
    # killed process is dev_runner's direct parent (PR_SET_PDEATHSIG); in
    # "grandparent" mode it is the process passed as --watch-pid (pidfd).
    local launch='"$DEV_RUNNER_BIN" ${WATCH_PID:+--watch-pid=$WATCH_PID} \
            --project-dir="$RUN_DIR" --watch-dir="$RUN_DIR/src" --frontend-dir="$RUN_DIR" \
            --dev-cmd sh -c "sleep 300 & sleep 300" --dev-cmd-end \
            --app-bin="$SLEEP_BIN" --app-args 300 --app-args-end \
            > "$RUN_DIR/runner.log" 2>&1 &
        echo $! > "$RUN_DIR/dev_runner.pid"
        wait'
    if [[ "$mode" == "parent" ]]; then
        DEV_RUNNER_BIN="$DEV_RUNNER_BIN" RUN_DIR="$run_dir" SLEEP_BIN="$SLEEP_BIN" \
            bash -c "$launch" &
    else
        DEV_RUNNER_BIN="$DEV_RUNNER_BIN" RUN_DIR="$run_dir" SLEEP_BIN="$SLEEP_BIN" LAUNCH="$launch" \
            bash -c 'WATCH_PID=$$ bash -c "$LAUNCH" & wait' &
    fi
    local parent_pid=$!
    PIDS_TO_CLEANUP+=("$parent_pid")

    # Wait up to 5 seconds for dev_runner and its children to appear
    local dev_runner_pid=""
    local dev_server_pid=""
    local grandchild_pid=""
    local app_pid=""
    local dev_server_pgid=""
    local app_pgid=""

    local deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        if [[ -z "$dev_runner_pid" ]] && [[ -f "$run_dir/dev_runner.pid" ]]; then
            local candidate
            candidate="$(cat "$run_dir/dev_runner.pid" 2>/dev/null || true)"
            if [[ -n "$candidate" ]] && kill -0 "$candidate" 2>/dev/null; then
                dev_runner_pid="$candidate"
                PIDS_TO_CLEANUP+=("$dev_runner_pid")
            fi
        fi

        if [[ -n "$dev_runner_pid" ]]; then
            # Find children of dev_runner
            local runner_children
            runner_children=($(pgrep -P "$dev_runner_pid" || true))
            for c in ${runner_children[@]+"${runner_children[@]}"}; do
                PIDS_TO_CLEANUP+=("$c")
                local comm
                comm="$(ps -o comm= -p "$c" 2>/dev/null || true)"
                if [[ "$comm" == *"sh"* ]]; then
                    dev_server_pid="$c"
                elif [[ "$comm" == *"sleep"* ]]; then
                    app_pid="$c"
                fi
            done

            # Find grandchild of dev_server
            if [[ -n "$dev_server_pid" ]]; then
                local dev_children
                dev_children=($(pgrep -P "$dev_server_pid" || true))
                if [[ -n "${dev_children[0]:-}" ]]; then
                    grandchild_pid="${dev_children[0]}"
                    PIDS_TO_CLEANUP+=("$grandchild_pid")
                fi
            fi
        fi

        if [[ -n "$dev_runner_pid" && -n "$dev_server_pid" && -n "$grandchild_pid" && -n "$app_pid" ]]; then
            break
        fi
        sleep 0.05
    done

    if [[ -z "$dev_runner_pid" || -z "$dev_server_pid" || -z "$grandchild_pid" || -z "$app_pid" ]]; then
        echo "test-dev-cleanup: error: failed to discover all child processes within 5s" >&2
        echo "Discovered: dev_runner=$dev_runner_pid, dev_server=$dev_server_pid, grandchild=$grandchild_pid, app=$app_pid" >&2
        if [[ -f "$run_dir/runner.log" ]]; then
            cat "$run_dir/runner.log" >&2
        fi
        exit 1
    fi

    # Read PGIDs
    dev_server_pgid="$(ps -o pgid= -p "$dev_server_pid" 2>/dev/null | tr -d ' ' || true)"
    app_pgid="$(ps -o pgid= -p "$app_pid" 2>/dev/null | tr -d ' ' || true)"

    # Verify that dev_server is in its own process group
    if [[ -n "$dev_server_pgid" ]]; then
        if [[ "$dev_server_pgid" -ne "$dev_server_pid" ]]; then
            echo "test-dev-cleanup: error: dev_server PGID ($dev_server_pgid) != dev_server PID ($dev_server_pid)" >&2
            exit 1
        fi
    fi

    # Verify that grandchild is in dev_server's process group
    local gc_pgid
    gc_pgid="$(ps -o pgid= -p "$grandchild_pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$gc_pgid" -ne "$dev_server_pgid" ]]; then
        echo "test-dev-cleanup: error: grandchild PGID ($gc_pgid) != dev_server PGID ($dev_server_pgid)" >&2
        exit 1
    fi

    # Now send the target signal to the intermediate parent process ONLY
    if [[ "$signal" == "SIGTERM" ]]; then
        kill -TERM "$parent_pid"
    elif [[ "$signal" == "SIGKILL" ]]; then
        kill -KILL "$parent_pid"
    else
        echo "test-dev-cleanup: unknown signal $signal" >&2
        exit 1
    fi
    wait "$parent_pid" 2>/dev/null || true

    # Wait up to 5 seconds for all processes and process groups to disappear
    local end_time=$((SECONDS + 5))
    while (( SECONDS < end_time )); do
        local any_alive=0

        # Check PIDs
        for pid in "$parent_pid" "$dev_runner_pid" "$dev_server_pid" "$grandchild_pid" "$app_pid"; do
            if kill -0 "$pid" 2>/dev/null || [[ -d "/proc/$pid" ]]; then
                any_alive=1
                break
            fi
        done

        # Check process groups
        if [[ $any_alive -eq 0 && -n "$dev_server_pgid" ]]; then
            if kill -0 "-$dev_server_pgid" 2>/dev/null; then
                any_alive=1
            fi
        fi
        if [[ $any_alive -eq 0 && -n "$app_pgid" ]]; then
            if kill -0 "-$app_pgid" 2>/dev/null; then
                any_alive=1
            fi
        fi

        if [[ $any_alive -eq 0 ]]; then
            # All gone!
            wait "$parent_pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.05
    done

    echo "test-dev-cleanup: error: processes failed to exit after $signal within 5s" >&2
    echo "Parent $parent_pid: $(kill -0 "$parent_pid" 2>/dev/null && echo alive || echo dead)" >&2
    echo "dev_runner $dev_runner_pid: $(kill -0 "$dev_runner_pid" 2>/dev/null && echo alive || echo dead)" >&2
    echo "dev_server $dev_server_pid: $(kill -0 "$dev_server_pid" 2>/dev/null && echo alive || echo dead)" >&2
    echo "grandchild $grandchild_pid: $(kill -0 "$grandchild_pid" 2>/dev/null && echo alive || echo dead)" >&2
    echo "app $app_pid: $(kill -0 "$app_pid" 2>/dev/null && echo alive || echo dead)" >&2
    if [[ -n "$dev_server_pgid" ]]; then
        echo "dev_server PGID $dev_server_pgid: $(kill -0 "-$dev_server_pgid" 2>/dev/null && echo alive || echo dead)" >&2
    fi
    if [[ -n "$app_pgid" ]]; then
        echo "app PGID $app_pgid: $(kill -0 "-$app_pgid" 2>/dev/null && echo alive || echo dead)" >&2
    fi
    exit 1
}

# Run both SIGTERM and SIGKILL test cases
for mode in parent grandparent; do
    run_case SIGTERM "$mode"
    run_case SIGKILL "$mode"
done
