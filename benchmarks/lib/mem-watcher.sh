# =============================================================================
# lib/mem-watcher.sh
# Memory peak-delta watcher using /sys/fs/cgroup/memory.current
#
# Usage:
#   source "$REPO_ROOT/lib/mem-watcher.sh"
#
#   mem_watcher_start <container_name>   # capture baseline, start background poll
#   mem_watcher_stop                     # stop poll, return peak delta in MiB
#
# The returned value is the maximum memory increase (MiB) observed during the
# transfer, relative to the container's memory usage at the moment of start.
#
# Implementation: reads /sys/fs/cgroup/memory.current via `docker exec` at
# ~100 ms intervals. This is ~25x faster than `docker stats --no-stream`
# (which blocks ~1 s per call waiting for a daemon refresh cycle), making
# it accurate for transfers as short as a few hundred milliseconds.
# The cgroup reports the full container memory (all child processes included).
# =============================================================================

_MEM_WATCHER_PID=""
_MEM_WATCHER_FILE=""
_MEM_WATCHER_BASELINE=0

# Read current memory usage (bytes) for a container via cgroup.
_mem_sample_bytes() {
    local container="$1"
    local val
    val=$("$CONTAINER_CMD" exec "$container" cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "")
    if [[ -z "$val" ]] || ! [[ "$val" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$val"
    fi
}

# Background polling loop — writes the running peak delta (MiB) to a tmp file.
_mem_watcher_loop() {
    local container="$1"
    local out_file="$2"
    local baseline="$3"
    local peak=0
    while true; do
        local current
        current=$(_mem_sample_bytes "$container")
        local delta=$(( (current - baseline) / 1048576 ))
        if (( delta > peak )); then
            peak=$delta
            echo "$peak" > "$out_file"
        fi
        sleep 0.1
    done
}

mem_watcher_start() {
    local container="$1"
    _MEM_WATCHER_FILE=$(mktemp /tmp/mem_watcher_XXXXXX)
    echo "0" > "$_MEM_WATCHER_FILE"

    _MEM_WATCHER_BASELINE=$(_mem_sample_bytes "$container")

    _mem_watcher_loop "$container" "$_MEM_WATCHER_FILE" "$_MEM_WATCHER_BASELINE" &
    _MEM_WATCHER_PID=$!
}

# Stop the watcher and echo the peak delta in MiB.
mem_watcher_stop() {
    if [[ -n "$_MEM_WATCHER_PID" ]]; then
        kill "$_MEM_WATCHER_PID" 2>/dev/null || true
        wait "$_MEM_WATCHER_PID" 2>/dev/null || true
        _MEM_WATCHER_PID=""
    fi
    local peak=0
    if [[ -f "$_MEM_WATCHER_FILE" ]]; then
        peak=$(cat "$_MEM_WATCHER_FILE" 2>/dev/null || echo "0")
        rm -f "$_MEM_WATCHER_FILE"
        _MEM_WATCHER_FILE=""
    fi
    if (( peak < 0 )); then peak=0; fi
    echo "$peak"
}
