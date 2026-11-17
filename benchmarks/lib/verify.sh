# =============================================================================
# verify.sh - per-scenario target verification, shared by every 03-*.sh
#
# verify_target <tool> <bench_id> compares the target written by a scenario with
# its source, inside benchmark-test (verify_data.py exits 1 on FAIL or ERROR).
#
# A failure is recorded in $VERIFY_FAILURES_FILE and printed, but never stops the
# series: a mismatch must not cost the scenarios that follow it. benchmarks.sh
# reads that file after the report exists and exits 1, so a run with a failed
# verification never ends on a success banner. The function always returns 0, so
# the caller's `set -e` cannot abort the series either.
# =============================================================================

: "${VERIFY_FAILURES_FILE:=${ARTIFACTS_DIR:-.}/.verify_failures}"

verify_target() {
    local tool="$1" bench_id="$2" rc=0
    container_exec benchmark-test /opt/venv/pandas/bin/python3 /bench/scripts/verify_data.py \
        "$tool" "$bench_id" "$BENCHMARK_ROWS" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo -e "${RED}VERIFY FAILED: ${tool} ${bench_id} (exit ${rc})${NC}"
        echo "${tool} ${bench_id} exit=${rc}" >> "$VERIFY_FAILURES_FILE"
    fi
    return 0
}
