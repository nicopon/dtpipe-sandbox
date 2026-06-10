# =============================================================================
# lib/mem-watcher.sh
# Memory peak-delta watcher using docker stats
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
# Accuracy note: docker stats samples every ~1 s, so measurements are only
# meaningful for transfers that take at least a few seconds. For sub-second
# runs the reported delta will often be 0 MiB.
# =============================================================================

_MEM_WATCHER_PID=""
_MEM_WATCHER_FILE=""
_MEM_WATCHER_BASELINE=0

# Read current memory usage (MiB) for a container — single sample, no stream.
_mem_sample_mib() {
    local container="$1"
    local raw
    raw=$("$CONTAINER_CMD" stats --no-stream --format "{{.MemUsage}}" "$container" 2>/dev/null || echo "")
    # MemUsage format: "123.4MiB / 7.8GiB" — extract the first number and unit
    if [[ -z "$raw" ]]; then
        echo "0"
        return
    fi
    local value unit
    value=$(echo "$raw" | awk '{print $1}' | sed 's/[^0-9.]//g')
    unit=$(echo "$raw"  | awk '{print $1}' | sed 's/[0-9.]//g')
    case "$unit" in
        GiB) echo "$value" | awk '{printf "%d", $1 * 1024}' ;;
        MiB) echo "$value" | awk '{printf "%d", $1}'        ;;
        kB|KiB) echo "$value" | awk '{printf "%d", $1 / 1024}' ;;
        B)   echo "0" ;;
        *)   echo "$value" | awk '{printf "%d", $1}' ;;
    esac
}

# Background polling loop — writes the running peak delta to a tmp file.
_mem_watcher_loop() {
    local container="$1"
    local out_file="$2"
    local baseline="$3"
    local peak=0
    while true; do
        local current
        current=$(_mem_sample_mib "$container")
        local delta=$(( current - baseline ))
        if (( delta > peak )); then
            peak=$delta
        fi
        echo "$peak" > "$out_file"
        sleep 1
    done
}

mem_watcher_start() {
    local container="$1"
    _MEM_WATCHER_FILE=$(mktemp /tmp/mem_watcher_XXXXXX)
    echo "0" > "$_MEM_WATCHER_FILE"

    # Warm up docker stats (first call is slow) and capture baseline
    _mem_sample_mib "$container" > /dev/null 2>&1 || true
    _MEM_WATCHER_BASELINE=$(_mem_sample_mib "$container")

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
    # Clamp to 0 (negative delta = noise)
    if (( peak < 0 )); then peak=0; fi
    echo "$peak"
}
