#!/usr/bin/env bash
# =============================================================================
# 05-compare-baseline.sh - macro performance gate
#
# Compares the report produced by 04-report.sh against a versioned baseline and
# renders a verdict — or refuses to.
#
# --------------------------------------------------------------------------
# Why this refuses instead of warning
# --------------------------------------------------------------------------
# A baseline records the machine it was measured on. Comparing durations across
# two different machines does not give a weaker verdict, it gives a misleading
# one: most of the gap between the two numbers is then the hardware. So when the
# host fingerprints differ this script exits 2 and prints no verdict at all,
# unless --allow-foreign-host is passed, in which case the threshold is clamped
# to no tighter than FOREIGN_HOST_MIN_THRESHOLD % — wide enough that only a
# factor-scale change survives the hardware difference.
#
# This is the macro stage of the three-tier gate. It stays local, on the
# reference machine, with the same status as validate_vitals.sh in dtpipe: the
# suite needs Oracle and SQL Server in containers, which free CI runners cannot
# host, and a shared runner's 20-50 % duration variance would make a 15 % gate
# produce random red rather than signal. The micro stage that does run in CI
# lives in the dtpipe repo (tests/scripts/micro_perf_gate.sh) and applies the
# same fingerprint rule at a deliberately wide threshold.
#
# --------------------------------------------------------------------------
# Statistic
# --------------------------------------------------------------------------
# The comparison is on min_duration_ms, not the average: noise on a shared
# machine is one-sided — it can only make a run slower — so the fastest run is
# the closest estimate of the tool's own cost. See lib/stats.sh.
#
# --------------------------------------------------------------------------
# Host dependencies: none beyond bash and a container runtime
# --------------------------------------------------------------------------
# jq runs inside benchmark-test, exactly as 04-report.sh does it, so the host
# needs no jq (and no python). Consequence: benchmark-test must be running.
# Right after ./benchmarks.sh it is.
#
# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
#   ./05-compare-baseline.sh --update
#       Record the current report as baselines/macro_perf.json.
#
#   ./05-compare-baseline.sh
#       Compare against it. Refuses on a machine mismatch.
#
#   ./05-compare-baseline.sh --allow-foreign-host
#       Compare anyway, at a clamped (wide) threshold.
#
# Options:
#   --threshold PCT        Regression tolerance in percent   (default: 15)
#   --tool NAME            Tool to gate on                   (default: dtpipe)
#   --baseline FILE        Baseline path
#   --report FILE          Report to compare (default: the last one generated)
#   --allow-foreign-host   Compare across machines, clamped threshold
#   --update               Record the current report as the baseline
#
# Exit codes: 0 pass · 1 regression · 2 refused to render a verdict · 3 setup error
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
ARTIFACTS_DIR="$SCRIPT_DIR/../artifacts"
BASELINE_DIR="$SCRIPT_DIR/../baselines"

source "$LIB_DIR/container-runtime.sh"
init_container_runtime || exit 3

REPORT_FILE="$ARTIFACTS_DIR/reports/benchmark_report.json"
BASELINE_FILE="$BASELINE_DIR/macro_perf.json"
THRESHOLD=15
TOOL="dtpipe"
ALLOW_FOREIGN_HOST=false
UPDATE=false

# Below this, a cross-machine verdict describes the hardware, not the change.
FOREIGN_HOST_MIN_THRESHOLD=50

EXIT_PASS=0
EXIT_REGRESSION=1
EXIT_REFUSED=2
EXIT_ERROR=3

if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; CYAN=''; NC=''
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --threshold)          THRESHOLD="$2"; shift 2 ;;
        --tool)               TOOL="$2"; shift 2 ;;
        --baseline)           BASELINE_FILE="$2"; shift 2 ;;
        --report)             REPORT_FILE="$2"; shift 2 ;;
        --allow-foreign-host) ALLOW_FOREIGN_HOST=true; shift ;;
        --update)             UPDATE=true; shift ;;
        -h|--help)            sed -n '2,62p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit $EXIT_ERROR ;;
    esac
done

# =============================================================================
# jq proxy — same mechanism as 04-report.sh: jq lives in benchmark-test, never
# on the host. Files are passed on stdin so no path translation is needed and
# a baseline stored outside the mounted artifacts tree still works.
# =============================================================================
container_is_running "benchmark-test" || {
    echo -e "${RED}Container 'benchmark-test' is not running.${NC}" >&2
    echo -e "${RED}This script runs jq inside it so the host needs none.${NC}" >&2
    echo -e "${RED}Start it with: ./benchmarks.sh --skip-infra --tool dtpipe --scope B01${NC}" >&2
    exit $EXIT_ERROR
}

# jq_file <json-file> <jq-args...>
jq_file() {
    local file="$1"; shift
    "$CONTAINER_CMD" exec -i benchmark-test jq "$@" < "$file"
}

[ -f "$REPORT_FILE" ] || {
    echo -e "${RED}Report not found: $REPORT_FILE${NC}" >&2
    echo -e "${RED}Run ./benchmarks.sh first.${NC}" >&2
    exit $EXIT_ERROR
}

# Machine fingerprint, straight out of the report's own host block.
FINGERPRINT_FILTER='.configuration.host
    | "\(.os // "?")/\(.arch // "?")/\(.cpu // "?")/\(.cpu_cores // "?")c"'

echo ""
echo -e "${CYAN}================================================${NC}"
echo -e "${CYAN}  Macro performance gate${NC}"
echo -e "${CYAN}================================================${NC}"
echo -e "  Report:   $REPORT_FILE"
echo -e "  Baseline: $BASELINE_FILE"
echo -e "  Tool:     $TOOL"
echo ""

if [ "$UPDATE" = true ]; then
    mkdir -p "$BASELINE_DIR"
    cp "$REPORT_FILE" "$BASELINE_FILE"
    echo -e "${GREEN}Baseline written: $BASELINE_FILE${NC}"
    echo -e "  Fingerprint: $(jq_file "$BASELINE_FILE" -r "$FINGERPRINT_FILTER")"
    echo -e "  ${YELLOW}Only strictly comparable on the machine above.${NC}"
    exit $EXIT_PASS
fi

[ -f "$BASELINE_FILE" ] || {
    echo -e "${YELLOW}No baseline at $BASELINE_FILE.${NC}"
    echo -e "${YELLOW}Record one with: $0 --update${NC}"
    exit $EXIT_REFUSED
}

# =============================================================================
# The fingerprint rule
# =============================================================================
BASE_FP="$(jq_file "$BASELINE_FILE" -r "$FINGERPRINT_FILTER")"
CUR_FP="$(jq_file "$REPORT_FILE"   -r "$FINGERPRINT_FILTER")"

EFFECTIVE_THRESHOLD="$THRESHOLD"
CROSS_MACHINE=false

if [ "$BASE_FP" != "$CUR_FP" ]; then
    CROSS_MACHINE=true
    echo -e "${YELLOW}Machine fingerprint differs from the baseline:${NC}"
    echo -e "  baseline: ${BASE_FP}"
    echo -e "  current:  ${CUR_FP}"

    if [ "$ALLOW_FOREIGN_HOST" != true ]; then
        echo ""
        echo -e "${RED}REFUSED — no verdict rendered.${NC}"
        echo -e "${RED}Comparing durations measured on different hardware does not give a${NC}"
        echo -e "${RED}weaker verdict, it gives a misleading one: most of the gap between${NC}"
        echo -e "${RED}the two numbers would be the machine, not the code.${NC}"
        echo ""
        echo -e "  Either record a baseline here  : $0 --update"
        echo -e "  or accept a factor-scale check : $0 --allow-foreign-host"
        exit $EXIT_REFUSED
    fi

    if [ "$EFFECTIVE_THRESHOLD" -lt "$FOREIGN_HOST_MIN_THRESHOLD" ]; then
        echo -e "${YELLOW}Threshold ${EFFECTIVE_THRESHOLD}% clamped to ${FOREIGN_HOST_MIN_THRESHOLD}%: below that, a${NC}"
        echo -e "${YELLOW}cross-machine verdict describes the hardware, not the change.${NC}"
        EFFECTIVE_THRESHOLD="$FOREIGN_HOST_MIN_THRESHOLD"
    fi
    echo -e "${YELLOW}Proceeding cross-machine at ${EFFECTIVE_THRESHOLD}% — detects a factor, not a +15%.${NC}"
    echo ""
fi

# =============================================================================
# Extract "<id>\t<min_ms>\t<stddev_ms>\t<description>" for the gated tool.
# Reports predating the dispersion work carry only avg_duration_ms; fall back to
# it so an old baseline still compares instead of silently matching nothing.
# =============================================================================
SERIES_FILTER='
    .benchmarks
    | to_entries[]
    | . as $e
    | ($e.value.tools[$tool] // empty) as $t
    | (($t.min_duration_ms // $t.avg_duration_ms) // empty) as $v
    | select(($v | type) == "number" and $v > 0)
    | [$e.key, ($v | tostring), (($t.stddev_duration_ms // "") | tostring), ($e.value.description // "")]
    | @tsv'

BASE_TSV="$(mktemp)"
CUR_TSV="$(mktemp)"
trap 'rm -f "$BASE_TSV" "$CUR_TSV"' EXIT

jq_file "$BASELINE_FILE" -r --arg tool "$TOOL" "$SERIES_FILTER" | sort > "$BASE_TSV"
jq_file "$REPORT_FILE"   -r --arg tool "$TOOL" "$SERIES_FILTER" | sort > "$CUR_TSV"

if [ ! -s "$BASE_TSV" ]; then
    echo -e "${RED}Baseline holds no usable figure for '$TOOL'.${NC}" >&2
    exit $EXIT_REFUSED
fi

# =============================================================================
# Verdict
# =============================================================================
set +e
awk -F'\t' \
    -v threshold="$EFFECTIVE_THRESHOLD" \
    -v cross="$CROSS_MACHINE" \
    '
    NR == FNR {
        base_ms[$1] = $2 + 0
        desc[$1] = $4
        base_ids[++base_n] = $1
        next
    }
    {
        cur_ms[$1] = $2 + 0
        cur_sd[$1] = ($3 == "" ? -1 : $3 + 0)
        if (!($1 in base_ms)) added = added (added == "" ? "" : ", ") $1
    }
    END {
        printf "%-5s %-32s %10s %10s %8s\n", "ID", "Scenario", "baseline", "current", "delta"
        printf "%s\n", "----------------------------------------------------------------------"

        # Rank by delta, worst first (insertion sort — a handful of rows).
        n = 0
        for (i = 1; i <= base_n; i++) {
            id = base_ids[i]
            if (!(id in cur_ms)) { missing = missing (missing == "" ? "" : ", ") id; continue }
            d = (cur_ms[id] - base_ms[id]) / base_ms[id] * 100.0
            j = n
            while (j > 0 && deltas[j] < d) { ids[j+1] = ids[j]; deltas[j+1] = deltas[j]; j-- }
            ids[j+1] = id; deltas[j+1] = d; n++
        }

        regressions = 0
        noisy = 0
        for (i = 1; i <= n; i++) {
            id = ids[i]; d = deltas[i]
            flag = ""
            if (d > threshold) {
                regressions++
                flag = "  REGRESSION"
                # A delta the run own dispersion can explain is noise, not a finding.
                if (cur_sd[id] >= 0 && (cur_ms[id] - base_ms[id]) < 2 * cur_sd[id]) {
                    flag = flag " (within 2 sd)"
                    noisy++
                }
            } else if (d < -threshold) {
                flag = "  faster"
            }
            printf "%-5s %-32.32s %7d ms %7d ms %+7.1f%%%s\n", id, desc[id], base_ms[id], cur_ms[id], d, flag
        }

        printf "\n"
        printf "Statistic: min of the repetitions · Threshold: %d%%%s\n", threshold, (cross == "true" ? " (cross-machine)" : "")
        if (missing != "") printf "In baseline but absent from the report: %s\n", missing
        if (added != "")   printf "New since the baseline:                %s\n", added

        printf "\n"
        if (regressions > 0) {
            printf "FAIL - %d scenario(s) slower than the baseline by more than %d%%.\n", regressions, threshold
            if (noisy > 0) {
                printf "       %d of them sit within twice their own standard deviation,\n", noisy
                printf "       so re-run before treating those as a finding.\n"
            }
            exit 1
        }
        printf "PASS - no scenario exceeds the threshold.\n"
        exit 0
    }
    ' "$BASE_TSV" "$CUR_TSV"
STATUS=$?
set -e

case $STATUS in
    0) echo -e "${GREEN}Macro performance gate: PASS${NC}" ;;
    1) echo -e "${RED}Macro performance gate: FAIL${NC}" ;;
    *) echo -e "${YELLOW}Macro performance gate: could not complete${NC}" ;;
esac
exit $STATUS
