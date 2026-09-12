#!/usr/bin/env bash
# =============================================================================
# 03-dtpipe.sh - dtpipe benchmark (executions INSIDE benchmark-test container)
# Runs the same pipelines as Meltano and Sling for comparison
#
# IMPORTANT: Everything runs inside the container, nothing on the host
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/../artifacts"
CONFIG_DIR="$SCRIPT_DIR/../config"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source the container runtime detection module (docker / podman)
source "$LIB_DIR/container-runtime.sh"
init_container_runtime || exit 1
source "$LIB_DIR/mem-watcher.sh"
source "$LIB_DIR/stats.sh"

# Default values
BENCHMARK_ROWS=1000000
BENCHMARK_REPETITIONS=3
BENCHMARK_SCOPE="all"           # all, B01-B12

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Load environment configuration (for DB connection strings)
if [[ -f "$CONFIG_DIR/benchmark.env" ]]; then
    source "$CONFIG_DIR/benchmark.env" 2>/dev/null || true
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
              --rows)
             BENCHMARK_ROWS="$2"
             shift 2
                ;;
            --repetitions)
             BENCHMARK_REPETITIONS="$2"
             shift 2
                ;;
            --scope)
             BENCHMARK_SCOPE="$2"
             shift 2
                ;;
            *)
             echo -e "${RED}Unknown option: $1${NC}"
             exit 1
                ;;
    esac
done

# Calculate rows suffix (e.g. 2m or 5m)
if [[ "$BENCHMARK_ROWS" -eq 5000000 ]]; then
    SUFFIX="5m"
elif [[ "$BENCHMARK_ROWS" -eq 2000000 ]]; then
    SUFFIX="2m"
else
      # Fallback to raw row count if not 2M or 5M
    if (( BENCHMARK_ROWS % 1000000 == 0 )); then
        SUFFIX="$(( BENCHMARK_ROWS / 1000000 ))m"
    else
        SUFFIX="${BENCHMARK_ROWS}"
    fi
fi
SUFFIX_UPPER=$(echo "$SUFFIX" | tr '[:lower:]' '[:upper:]')


# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/dtpipe"
RESULTS_CSV="$ARTIFACTS_DIR/dtpipe/.tmp_results.csv"
> "$RESULTS_CSV"            # Clear previous results

# Temp dir for runner scripts
RUNNER_TMP=$(mktemp -d)
trap "rm -rf $RUNNER_TMP" EXIT

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  dtpipe benchmark (benchmark-test container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure dtpipe (.NET tool) is JIT-compiled before the first timed run
echo -e "${YELLOW}Warming up dtpipe...${NC}"
container_exec benchmark-test dtpipe --version > /dev/null 2>&1 || true

# =============================================================================
# Benchmark function: Execute a dtpipe pipeline N times and record timings
# Writes a runner script into the container to avoid shell quoting issues
# =============================================================================
# Is this benchmark in scope? Accepts "all", the family keywords "transfer"
# (B01-B15) and "transform" (B16-B19), or a comma-separated list of ids.
_in_scope() {
    local bench_id="$1"
    case "$BENCHMARK_SCOPE" in
        all)       return 0 ;;
        transfer)  [[ "$bench_id" < "B16" ]] && return 0; return 1 ;;
        transform) [[ "$bench_id" > "B15" ]] && return 0; return 1 ;;
    esac
    local entry
    IFS=',' read -ra _scope_entries <<< "$BENCHMARK_SCOPE"
    for entry in "${_scope_entries[@]}"; do
        [[ "$entry" == "$bench_id" ]] && return 0
    done
    return 1
}

# run_pipeline [--no-verify] <bench_id> <description> <dtpipe args...>
#   --no-verify : the pipeline has no inspectable target (null: sink), so the
#                 source/target integrity check does not apply.
run_pipeline() {
    local verify=true
    if [[ "${1:-}" == "--no-verify" ]]; then
        verify=false
        shift
    fi

    local bench_id="$1"
    local description="$2"
    shift 2

       # Check if this benchmark should run based on scope
    if ! _in_scope "$bench_id"; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id (dtpipe): $description ---${NC}"

       # Write a runner script to a temp file on the host
    local runner_script="$RUNNER_TMP/${bench_id}.sh"
    cat > "$runner_script" << 'SCRIPT_HEADER'
#!/bin/bash
set +e
SCRIPT_HEADER

       # Append the actual dtpipe command (with all args properly quoted via heredoc)
    echo 'START=$(date +%s%N)' >> "$runner_script"
    printf 'dtpipe' >> "$runner_script"
    for arg in "$@"; do
        printf ' %q' "$arg" >> "$runner_script"
    done
    cat >> "$runner_script" << 'SCRIPT_FOOTER'
  > /tmp/dtpipe_out.txt 2>&1
EXIT_CODE=$?
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [[ $EXIT_CODE -eq 0 ]]; then
    echo "OK:$ELAPSED_MS"
else
    echo "FAIL:$EXIT_CODE:$ELAPSED_MS"
    tail -5 /tmp/dtpipe_out.txt | while read -r line; do echo "ERR:$line"; done
fi
rm -f /tmp/dtpipe_out.txt
SCRIPT_FOOTER

    chmod +x "$runner_script"

        # Copy the script into the container
    container_cp "$runner_script" benchmark-test:/tmp/bench_runner.sh || {
        echo -e " ${RED}FAILED (script copy impossible)${NC}"
        return
     }

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        mem_watcher_start benchmark-test
            # Execute the runner script inside the container
        local output
        output=$(container_exec benchmark-test bash /tmp/bench_runner.sh 2>&1) || true
        local peak_mem
        peak_mem=$(mem_watcher_stop)

           # Parse result
        local status_line
        status_line=$(echo "$output" | grep -E "^(OK|FAIL):" | head -1)

        if echo "$status_line" | grep -q "^OK:"; then
            local elapsed_ms
            elapsed_ms=$(echo "$status_line" | cut -d: -f2)
            echo -e " ${GREEN}OK (${elapsed_ms} ms, +${peak_mem} MiB)${NC}"
            run_times+=("$elapsed_ms")
            run_mem_peaks+=("$peak_mem")
        else
            local exit_code elapsed_ms err_msg
            exit_code=$(echo "$status_line" | cut -d: -f2 || echo "?")
            elapsed_ms=$(echo "$status_line" | cut -d: -f3 || echo "?")
            err_msg=$(echo "$output" | grep "^ERR:" | head -1 | sed 's/^ERR://')
            echo -e " ${RED}FAILED (exit=${exit_code}, ${elapsed_ms} ms)${NC}"
            if [[ -n "$err_msg" ]]; then
                echo -e "          $err_msg"
            fi
            run_times+=("ERROR:0")
        fi
    done

    # Dispersion over the repetitions — min, avg and sample stddev (lib/stats.sh).
    # min is the reference statistic for throughput: container scheduling noise
    # can only ever make a run slower, never faster.
    stats_record_result "$RESULTS_CSV" "$bench_id" "$description" \
        ${run_times[@]+"${run_times[@]}"} -- ${run_mem_peaks[@]+"${run_mem_peaks[@]}"}

         # Verify target data matches source (run inside benchmark-test container)
    if [[ "$verify" == "true" ]] && [[ "$STATS_LAST_COUNT" -gt 0 ]]; then
        container_exec benchmark-test /opt/venv/pandas/bin/python3 /bench/scripts/verify_data.py "dtpipe" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# =============================================================================
# B01: Parquet → PostgreSQL
# Target table prefixed with dtpipe_
# =============================================================================
run_pipeline "B01" "Parquet → PostgreSQL" \
      --input "/bench/artifacts/source_data_${SUFFIX}.parquet" \
      --output "pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=$DB_POSTGRES_USER;Password=$DB_POSTGRES_PASSWORD" \
      --table "dtpipe_bench_pg" \
      --strategy Recreate \
      --pre-exec "DROP TABLE IF EXISTS dtpipe_bench_pg CASCADE" \
      --no-schema-validation

# =============================================================================
# B02: PostgreSQL → Parquet
# Source table in PostgreSQL (benchmark_source_${SUFFIX} created by 01-init-data.sh)
# Target file prefixed with dtpipe_
# =============================================================================
run_pipeline "B02" "PostgreSQL → Parquet" \
      --input "pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=$DB_POSTGRES_USER;Password=$DB_POSTGRES_PASSWORD" \
      --query "SELECT * FROM benchmark_source_${SUFFIX}" \
      --output "/bench/artifacts/dtpipe_bench_pg_to_pq.parquet" \
      --no-schema-validation

# =============================================================================
# B03: CSV → SQL Server
# Target table prefixed with dtpipe_
# =============================================================================
run_pipeline "B03" "CSV → SQL Server" \
      --input "/bench/artifacts/source_data_${SUFFIX}.csv" \
      --output "mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=$DB_MSSQL_USER;Password=$DB_MSSQL_PASSWORD;Encrypt=False" \
      --table "dtpipe_bench_mssql" \
      --strategy Recreate \
      --pre-exec "IF OBJECT_ID('dtpipe_bench_mssql', 'U') IS NOT NULL DROP TABLE dtpipe_bench_mssql" \
      --no-schema-validation

# =============================================================================
# B04: SQL Server → CSV
# Source table in SQL Server (benchmark_source_${SUFFIX} created by 01-init-data.sh)
# Target file prefixed with dtpipe_
# =============================================================================
run_pipeline "B04" "SQL Server → CSV" \
      --input "mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=$DB_MSSQL_USER;Password=$DB_MSSQL_PASSWORD;Encrypt=False" \
      --query "SELECT * FROM benchmark_source_${SUFFIX}" \
      --output "/bench/artifacts/dtpipe_bench_mssql_to_csv.csv" \
      --no-schema-validation

# =============================================================================
# B05: Parquet → Oracle
# Target table prefixed with dtpipe_
# =============================================================================
run_pipeline "B05" "Parquet → Oracle" \
      --input "/bench/artifacts/source_data_${SUFFIX}.parquet" \
      --output "ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=$DB_ORACLE_USER;Password=$DB_ORACLE_PASSWORD" \
      --table "DTPIPE_BENCH_ORACLE" \
      --strategy Recreate \
      --pre-exec "BEGIN EXECUTE IMMEDIATE 'DROP TABLE DTPIPE_BENCH_ORACLE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;" \
      --no-schema-validation \
      --insert-mode Bulk

# =============================================================================
# B06: Oracle → Parquet
# Source table in Oracle (benchmark_source_${SUFFIX_UPPER} created by 01-init-data.sh)
# Target file prefixed with dtpipe_
# =============================================================================
run_pipeline "B06" "Oracle → Parquet" \
      --input "ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=$DB_ORACLE_USER;Password=$DB_ORACLE_PASSWORD" \
      --ora-fetch-size 10485760 \
      --query "SELECT * FROM BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
      --output "/bench/artifacts/dtpipe_bench_oracle_to_pq.parquet" \
      --no-schema-validation

# =============================================================================
# B07: CSV → PostgreSQL
# =============================================================================
run_pipeline "B07" "CSV → PostgreSQL" \
      --input "/bench/artifacts/source_data_${SUFFIX}.csv" \
      --output "pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=$DB_POSTGRES_USER;Password=$DB_POSTGRES_PASSWORD" \
      --table "dtpipe_bench_pg_csv" \
      --strategy Recreate \
      --pre-exec "DROP TABLE IF EXISTS dtpipe_bench_pg_csv CASCADE" \
      --no-schema-validation

# =============================================================================
# B08: PostgreSQL → CSV
# =============================================================================
run_pipeline "B08" "PostgreSQL → CSV" \
      --input "pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=$DB_POSTGRES_USER;Password=$DB_POSTGRES_PASSWORD" \
      --query "SELECT * FROM benchmark_source_${SUFFIX}" \
      --output "/bench/artifacts/dtpipe_bench_pg_to_csv.csv" \
      --no-schema-validation

# =============================================================================
# B09: Parquet → SQL Server
# =============================================================================
run_pipeline "B09" "Parquet → SQL Server" \
      --input "/bench/artifacts/source_data_${SUFFIX}.parquet" \
      --output "mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=$DB_MSSQL_USER;Password=$DB_MSSQL_PASSWORD;Encrypt=False" \
      --table "dtpipe_bench_mssql_pq" \
      --strategy Recreate \
      --pre-exec "IF OBJECT_ID('dtpipe_bench_mssql_pq', 'U') IS NOT NULL DROP TABLE dtpipe_bench_mssql_pq" \
      --no-schema-validation

# =============================================================================
# B10: SQL Server → Parquet
# =============================================================================
run_pipeline "B10" "SQL Server → Parquet" \
      --input "mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=$DB_MSSQL_USER;Password=$DB_MSSQL_PASSWORD;Encrypt=False" \
      --query "SELECT * FROM benchmark_source_${SUFFIX}" \
      --output "/bench/artifacts/dtpipe_bench_mssql_to_pq.parquet" \
      --no-schema-validation

# =============================================================================
# B11: CSV → Oracle
# =============================================================================
run_pipeline "B11" "CSV → Oracle" \
      --input "/bench/artifacts/source_data_${SUFFIX}.csv" \
      --output "ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=$DB_ORACLE_USER;Password=$DB_ORACLE_PASSWORD" \
      --table "DTPIPE_BENCH_ORACLE_CSV" \
      --strategy Recreate \
      --pre-exec "BEGIN EXECUTE IMMEDIATE 'DROP TABLE DTPIPE_BENCH_ORACLE_CSV'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;" \
      --no-schema-validation \
      --insert-mode Bulk

# =============================================================================
# B12: Oracle → CSV
# =============================================================================
run_pipeline "B12" "Oracle → CSV" \
      --input "ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=$DB_ORACLE_USER;Password=$DB_ORACLE_PASSWORD" \
      --ora-fetch-size 10485760 \
      --query "SELECT * FROM BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
      --output "/bench/artifacts/dtpipe_bench_oracle_to_csv.csv" \
      --no-schema-validation

DB_POSTGRES_READER_UPPER=$(echo "${DB_POSTGRES_READER_USER:-bench_reader}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_USER_UPPER=$(echo "${DB_ORACLE_USER:-testuser}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_READER_UPPER=$(echo "${DB_ORACLE_READER_USER:-bench_reader}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_WRITER_UPPER=$(echo "${DB_ORACLE_WRITER_USER:-bench_writer}" | tr '[:lower:]' '[:upper:]')

# =============================================================================
# B13: PostgreSQL → PostgreSQL (bench_reader → bench_writer schema)
# =============================================================================
run_pipeline "B13" "PostgreSQL → PostgreSQL" \
      --input "pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=${DB_POSTGRES_READER_USER:-bench_reader};Password=${DB_POSTGRES_READER_PASSWORD:-password}" \
      --query "SELECT * FROM benchmark_source_${SUFFIX}" \
      --output "pg:Host=$DB_POSTGRES_HOST;Port=$DB_POSTGRES_PORT;Database=$DB_POSTGRES_DB;Username=${DB_POSTGRES_WRITER_USER:-bench_writer};Password=${DB_POSTGRES_WRITER_PASSWORD:-password}" \
      --table "${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.dtpipe_bench_pg2pg" \
      --strategy Recreate \
      --pre-exec "DROP TABLE IF EXISTS ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.dtpipe_bench_pg2pg CASCADE" \
      --no-schema-validation

# =============================================================================
# B14: SQL Server → SQL Server (sa reader → bench_writer schema)
# =============================================================================
run_pipeline "B14" "SQL Server → SQL Server" \
      --input "mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=${DB_MSSQL_READER_USER:-bench_reader};Password=${DB_MSSQL_READER_PASSWORD:-BenchReader1!};Encrypt=False" \
      --query "SELECT * FROM benchmark_source_${SUFFIX}" \
      --output "mssql:Server=$DB_MSSQL_HOST,$DB_MSSQL_PORT;Database=$DB_MSSQL_DB;User Id=${DB_MSSQL_WRITER_USER:-bench_writer};Password=${DB_MSSQL_WRITER_PASSWORD:-BenchWriter1!};Encrypt=False" \
      --table "${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.dtpipe_bench_mssql2mssql" \
      --strategy Recreate \
      --pre-exec "IF OBJECT_ID('${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.dtpipe_bench_mssql2mssql', 'U') IS NOT NULL DROP TABLE ${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.dtpipe_bench_mssql2mssql" \
      --no-schema-validation

# =============================================================================
# B15: Oracle → Oracle (bench_reader → bench_writer schema)
# =============================================================================
run_pipeline "B15" "Oracle → Oracle" \
      --input "ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=${DB_ORACLE_READER_USER:-bench_reader};Password=${DB_ORACLE_READER_PASSWORD:-password}" \
      --ora-fetch-size 10485760 \
      --query "SELECT * FROM ${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
      --output "ora:Data Source=$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE;User Id=${DB_ORACLE_WRITER_USER:-bench_writer};Password=${DB_ORACLE_WRITER_PASSWORD:-password}" \
      --table "DTPIPE_BENCH_ORA2ORA" \
      --strategy Recreate \
      --pre-exec "BEGIN EXECUTE IMMEDIATE 'DROP TABLE DTPIPE_BENCH_ORA2ORA'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;" \
      --no-schema-validation \
      --insert-mode Bulk


# =============================================================================
# Transformation family — B16 to B19 · dtpipe only, no competitor
#
# Purpose: measure what a transformer costs, not what a target costs. Every
# scenario reads the same Parquet source and writes to "null:", so the sink is
# a no-op and the delta between two scenarios is transformation work alone.
# There is no competitor column here on purpose: the question is internal
# regression and one design decision (should --compute be vectorized?), not
# how dtpipe places against sling.
#
# The four scenarios are built to subtract from each other:
#
#   B16  control, no transformer      → read + row materialization + null sink
#   B17  columnar chain               → B16 + fake + filter + mask   (all Arrow)
#   B18  row chain                    → B16 + compute                (row mode)
#   B19  mixed chain                  → B17's three columnar transformers with
#                                       B18's compute inserted between filter
#                                       and mask, forcing a columnar → row →
#                                       columnar round trip mid-pipeline
#
# Which yields:
#   B17 - B16                       = cost of the columnar transformers
#   B18 - B16                       = cost of the compute (JS) in row mode
#   (B19 - B17) - (B18 - B16)       = cost of the extra row/columnar bridge,
#                                     the figure that decides the vectorized
#                                     compute bet
#
# The control is what makes the other three subtract from something. Without
# B16 the three remaining numbers are only totals.
#
# Invariants that keep the four comparable:
#   - identical source and identical sink;
#   - "country != ZZZ" is a simple filter (columnar fast path) that keeps every
#     row, so all four scenarios carry the same row count end to end;
#   - the compute in B18 and B19 is byte-identical and reads the untouched
#     email column (it runs before --mask in B19);
#   - no scenario adds or drops a column, so the schema is constant.
#
# No --no-schema-validation here, unlike B01-B15: the null: writer has no schema
# to validate and takes no options at all, so dtpipe refuses the flag rather than
# accept one that binds nothing. It never bound anything here — removing it does
# not move a measurement.
# =============================================================================

DTPIPE_TRANSFORM_SOURCE="/bench/artifacts/source_data_${SUFFIX}.parquet"

# B16: control — no transformer
run_pipeline --no-verify "B16" "Parquet → null (control, no transformer)" \
      --input "$DTPIPE_TRANSFORM_SOURCE" \
      --output "null:"

# B17: columnar chain — fake + filter + mask, all on the Arrow fast path
run_pipeline --no-verify "B17" "Parquet → null (columnar chain: fake+filter+mask)" \
      --input "$DTPIPE_TRANSFORM_SOURCE" \
      --fake "name:name.fullName" \
      --filter "country != ZZZ" \
      --mask "email" \
      --output "null:"

# B18: row chain — compute alone, the whole stream runs in row mode
run_pipeline --no-verify "B18" "Parquet → null (row chain: compute)" \
      --input "$DTPIPE_TRANSFORM_SOURCE" \
      --compute "email:row.email.toLowerCase()" \
      --output "null:"

# B19: mixed chain — same transformers as B17 and B18, arranged so the pipeline
# is forced back and forth across the row/columnar boundary
run_pipeline --no-verify "B19" "Parquet → null (mixed chain: forces row↔columnar bridge)" \
      --input "$DTPIPE_TRANSFORM_SOURCE" \
      --fake "name:name.fullName" \
      --filter "country != ZZZ" \
      --compute "email:row.email.toLowerCase()" \
      --mask "email" \
      --output "null:"


# =============================================================================
# Generate JSON report for dtpipe
# =============================================================================
echo ""
echo -e "${YELLOW}Generating JSON report...${NC}"

{
    echo "{"
    echo "        \"tool\": \"dtpipe\","
    echo "        \"benchmark_rows\": $BENCHMARK_ROWS,"
    echo "        \"repetitions\": $BENCHMARK_REPETITIONS,"
    echo "        \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "        \"benchmarks\": {"

    stats_json_benchmarks "$RESULTS_CSV" "            "
    echo "        }"
    echo "}"
} > "$ARTIFACTS_DIR/dtpipe/dtpipe_report.json"

echo -e "${GREEN}dtpipe report saved: $ARTIFACTS_DIR/dtpipe/dtpipe_report.json${NC}"