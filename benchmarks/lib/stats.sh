# =============================================================================
# lib/stats.sh
# Dispersion statistics for benchmark repetitions + result serialization.
#
# Source this from any runner:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   LIB_DIR="$SCRIPT_DIR/../lib"
#   source "$LIB_DIR/stats.sh"
#
# Why min and not avg:
#   For a throughput measurement the average integrates container scheduling
#   noise, page-cache warming and neighbour processes — every one of which can
#   only ever make a run SLOWER. The fastest observed run is therefore the
#   closest estimate of the tool's real cost, and it is the statistic the
#   comparison gate is built on. The average is kept for continuity with older
#   reports; the standard deviation is what tells you whether a 15 % delta is
#   a regression or noise.
#
# Standard deviation is the SAMPLE deviation (Bessel-corrected, n-1): with 3-5
# repetitions the uncorrected form understates the dispersion by ~20 %.
# With fewer than 2 valid runs it is reported as 0.
#
# Row format written to a runner's .tmp_results.csv (pipe-delimited, 8 fields):
#   bench_id|description|avg_ms|min_ms|stddev_ms|runs|avg_mem_mb|min_mem_mb
# Unavailable benchmarks carry a label in avg_ms and "N/A" everywhere else.
# =============================================================================

# ---------------------------------------------------------------------------
# stats_summarize <value...>
# Non-numeric entries (e.g. the "ERROR:0" marker runners push on failure) are
# ignored. Sets, in the caller's scope:
#   STATS_COUNT   number of valid values
#   STATS_AVG     integer mean
#   STATS_MIN     integer minimum
#   STATS_MAX     integer maximum
#   STATS_STDDEV  sample standard deviation, one decimal
# ---------------------------------------------------------------------------
stats_summarize() {
    STATS_COUNT=0
    STATS_AVG=0
    STATS_MIN=0
    STATS_MAX=0
    STATS_STDDEV=0

    [[ $# -eq 0 ]] && return 0

    local summary
    summary=$(printf '%s\n' "$@" | awk '
        /^-?[0-9]+$/ {
            v = $1 + 0
            n++
            sum += v
            sumsq += v * v
            if (n == 1 || v < min) min = v
            if (n == 1 || v > max) max = v
        }
        END {
            if (n == 0) { print "0 0 0 0 0"; exit }
            avg = int(sum / n)
            sd = 0
            if (n > 1) {
                var = (sumsq - (sum * sum) / n) / (n - 1)
                if (var > 0) sd = sqrt(var)
            }
            printf "%d %d %d %d %.1f\n", n, avg, min, max, sd
        }
    ')

    read -r STATS_COUNT STATS_AVG STATS_MIN STATS_MAX STATS_STDDEV <<< "$summary"
    return 0
}

# ---------------------------------------------------------------------------
# stats_record_result <results_csv> <bench_id> <description> <time...> -- <mem...>
# Summarizes both series and appends one row to the runner's results file.
# Also echoes a one-line human summary (min is the headline figure).
# ---------------------------------------------------------------------------
stats_record_result() {
    local results_csv="$1" bench_id="$2" description="$3"
    shift 3

    local times=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        times+=("$1"); shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local mems=()
    while [[ $# -gt 0 ]]; do
        mems+=("$1"); shift
    done

    stats_summarize ${times[@]+"${times[@]}"}
    local d_count="$STATS_COUNT" d_avg="$STATS_AVG" d_min="$STATS_MIN" d_sd="$STATS_STDDEV"

    stats_summarize ${mems[@]+"${mems[@]}"}
    local m_avg="$STATS_AVG" m_min="$STATS_MIN"

    echo "$bench_id|$description|$d_avg|$d_min|$d_sd|$d_count|$m_avg|$m_min" >> "$results_csv"

    STATS_LAST_AVG="$d_avg"
    STATS_LAST_MIN="$d_min"
    STATS_LAST_STDDEV="$d_sd"
    STATS_LAST_COUNT="$d_count"
    STATS_LAST_MEM_AVG="$m_avg"
    STATS_LAST_MEM_MIN="$m_min"

    echo "   min: ${d_min} ms · avg: ${d_avg} ms · sd: ${d_sd} ms · peak mem min/avg: +${m_min}/+${m_avg} MiB (${d_count} runs)"
}

# ---------------------------------------------------------------------------
# stats_record_unavailable <results_csv> <bench_id> <description> <label>
# Records a benchmark the tool cannot run ("Not supported", "Not implemented").
# ---------------------------------------------------------------------------
stats_record_unavailable() {
    local results_csv="$1" bench_id="$2" description="$3" label="${4:-Not supported}"
    echo "$bench_id|$description|$label|N/A|N/A|N/A|N/A|N/A" >> "$results_csv"
}

# ---------------------------------------------------------------------------
# stats_json_benchmarks <results_csv> [indent]
# Prints the comma-separated "benchmarks" object entries for a tool report.
# Numeric fields are emitted as JSON numbers; unavailable ones as null, with
# the label kept as a string in avg_duration_ms (the shape older readers
# already expect).
# ---------------------------------------------------------------------------
stats_json_benchmarks() {
    local results_csv="$1"
    local indent="${2:-            }"

    local first=true
    local bid bdesc bavg bmin bsd bruns bmem_avg bmem_min
    while IFS='|' read -r bid bdesc bavg bmin bsd bruns bmem_avg bmem_min; do
        [[ -z "$bid" ]] && continue
        if [[ "$first" != "true" ]]; then
            echo ","
        fi
        first=false
        printf '%s"%s": { "description": "%s", "avg_duration_ms": %s, "min_duration_ms": %s, "stddev_duration_ms": %s, "runs": %s, "avg_peak_mem_mb": %s, "min_peak_mem_mb": %s }' \
            "$indent" "$bid" "$bdesc" \
            "$(_stats_json_num "$bavg" quote_label)" \
            "$(_stats_json_num "$bmin")" \
            "$(_stats_json_num "$bsd")" \
            "$(_stats_json_num "$bruns")" \
            "$(_stats_json_num "$bmem_avg")" \
            "$(_stats_json_num "$bmem_min")"
    done < "$results_csv"
    echo ""
}

# Emit a JSON scalar: numbers verbatim, "N/A"/empty as null, anything else as
# null — unless "quote_label" is passed, which keeps a textual status
# ("Not supported") as a JSON string.
_stats_json_num() {
    local v="${1:-}"
    local mode="${2:-}"
    if [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$v"
    elif [[ -z "$v" || "$v" == "N/A" ]]; then
        printf 'null'
    elif [[ "$mode" == "quote_label" ]]; then
        printf '"%s"' "$v"
    else
        printf 'null'
    fi
}
