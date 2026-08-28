#!/usr/bin/env bash
# =============================================================================
# 03-ingestr.sh - Ingestr benchmark (executions INSIDE benchmark-test container)
# Runs the same pipelines as other tools for comparison
# =============================================================================
set -euo pipefail

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
BENCHMARK_ROWS=250000
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
    # Fallback if other row counts are requested
    if (( BENCHMARK_ROWS % 1000000 == 0 )); then
        SUFFIX="$(( BENCHMARK_ROWS / 1000000 ))m"
    else
        SUFFIX="${BENCHMARK_ROWS}"
    fi
fi
SUFFIX_UPPER=$(echo "$SUFFIX" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_USER_UPPER=$(echo "${DB_ORACLE_USER:-testuser}" | tr '[:lower:]' '[:upper:]')


# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/ingestr"
RESULTS_CSV="$ARTIFACTS_DIR/ingestr/.tmp_results.csv"
> "$RESULTS_CSV"        # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  ingestr benchmark (benchmark-test container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure ingestr binary is loaded before the first timed run
echo -e "${YELLOW}Warming up ingestr...${NC}"
container_exec benchmark-test ingestr --version > /dev/null 2>&1 || true

# =============================================================================
# Benchmark function: Execute an ingestr pipeline N times and record timings
# =============================================================================
run_pipeline() {
    local bench_id="$1"
    local description="$2"
    local src_uri="$3"
    local src_table="$4"
    local dest_uri="$5"
    local dest_table="$6"
    local extra_flags="${7:-}"

    # Check if this benchmark should run based on scope
    if [[ "$BENCHMARK_SCOPE" != "all" ]] && [[ "$BENCHMARK_SCOPE" != "$bench_id" ]]; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    # Check if this benchmark is supported
    if [[ "$src_uri" == "NOT_SUPPORTED" ]]; then
        echo -e "${YELLOW}$bench_id: $description [NOT SUPPORTED by ingestr]${NC}"
        stats_record_unavailable "$RESULTS_CSV" "$bench_id" "$description" "Not supported"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id (ingestr): $description ---${NC}"

    # Build the ingestr command
    local ingestr_cmd="ingestr ingest --source-uri '$src_uri' --source-table '$src_table' --dest-uri '$dest_uri' --dest-table '$dest_table' --yes --progress log --full-refresh --schema-naming direct $extra_flags"

    # Write runner script to a temp file and copy it into the container (avoids quoting issues)
    local runner_script
    runner_script=$(mktemp)
    cat > "$runner_script" << 'RUNNER_HEADER'
#!/bin/bash
set +e
START=$(date +%s%N)
RUNNER_HEADER
    echo "$ingestr_cmd > /tmp/out.txt 2>&1; EC=\$?" >> "$runner_script"
    cat >> "$runner_script" << 'RUNNER_FOOTER'
END=$(date +%s%N)
echo "ELAPSED_MS:$(( (END-START)/1000000 )):$EC"
cat /tmp/out.txt; rm -f /tmp/out.txt
RUNNER_FOOTER
    container_cp "$runner_script" benchmark-test:/tmp/bench_runner.sh
    rm -f "$runner_script"

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        mem_watcher_start benchmark-test
        local output
        output=$(container_exec benchmark-test bash /tmp/bench_runner.sh 2>&1) || true
        local peak_mem
        peak_mem=$(mem_watcher_stop)

        local status_line ms ec
        status_line=$(echo "$output" | grep "^ELAPSED_MS:" | head -1)
        ms=$(echo "$status_line" | cut -d: -f2)
        ec=$(echo "$status_line" | cut -d: -f3)

        if [[ -n "$ms" && "${ec:-1}" == "0" ]]; then
            echo -e " ${GREEN}OK (${ms} ms, +${peak_mem} MiB)${NC}"
            run_times+=("$ms")
            run_mem_peaks+=("$peak_mem")
        else
            echo -e " ${RED}FAILED${NC}"
            echo "$output" | grep -v "^ELAPSED_MS:" || true
            run_times+=("ERROR:0")
        fi
    done

    # Dispersion over the repetitions — min, avg and sample stddev (lib/stats.sh).
    # min is the reference statistic for throughput: container scheduling noise
    # can only ever make a run slower, never faster.
    stats_record_result "$RESULTS_CSV" "$bench_id" "$description" \
        ${run_times[@]+"${run_times[@]}"} -- ${run_mem_peaks[@]+"${run_mem_peaks[@]}"}

           # Verify target data matches source (run inside benchmark-test container)
    if [[ "$STATS_LAST_COUNT" -gt 0 ]]; then
        container_exec benchmark-test /opt/venv/pandas/bin/python3 /bench/scripts/verify_data.py "ingestr" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# Connection URIs from env vars
POSTGRES_URI="postgresql://$DB_POSTGRES_USER:$DB_POSTGRES_PASSWORD@$DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DB"
MSSQL_URI="mssql://$DB_MSSQL_USER:$DB_MSSQL_PASSWORD@$DB_MSSQL_HOST:$DB_MSSQL_PORT/$DB_MSSQL_DB?encrypt=disable"
ORACLE_URI="oracle://$DB_ORACLE_USER:$DB_ORACLE_PASSWORD@$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE"

# Local file URIs
PARQUET_SRC_URI="parquet:///bench/artifacts/source_data_${SUFFIX}.parquet"
CSV_SRC_URI="csv:///bench/artifacts/source_data_${SUFFIX}.csv"

# =============================================================================
# Run Benchmarks
# =============================================================================

# B01: Parquet → PostgreSQL
run_pipeline "B01" "Parquet → PostgreSQL" \
    "$PARQUET_SRC_URI" "source_data_${SUFFIX}" \
    "$POSTGRES_URI" "ingestr_bench_pg" \
    "--columns id:binary"

# B02: PostgreSQL → Parquet
run_pipeline "B02" "PostgreSQL → Parquet" \
    "$POSTGRES_URI" "public.benchmark_source_${SUFFIX}" \
    "parquet:///bench/artifacts/ingestr_bench_pg_to_pq.parquet" "ingestr_bench_pg_to_pq"

# B03: CSV → SQL Server
run_pipeline "B03" "CSV → SQL Server" \
    "$CSV_SRC_URI" "source_data_${SUFFIX}" \
    "$MSSQL_URI" "ingestr_bench_mssql"

# B04: SQL Server → CSV
run_pipeline "B04" "SQL Server → CSV" \
    "$MSSQL_URI" "dbo.benchmark_source_${SUFFIX}" \
    "csv:///bench/artifacts/ingestr_bench_mssql_to_csv.csv" "ingestr_bench_mssql_to_csv"

# B05: Parquet → Oracle (Not supported as destination)
run_pipeline "B05" "Parquet → Oracle" \
    "NOT_SUPPORTED" "" "" ""

# B06: Oracle → Parquet
run_pipeline "B06" "Oracle → Parquet" \
    "$ORACLE_URI" "${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
    "parquet:///bench/artifacts/ingestr_bench_oracle_to_pq.parquet" "ingestr_bench_oracle_to_pq"

# B07: CSV → PostgreSQL
run_pipeline "B07" "CSV → PostgreSQL" \
    "$CSV_SRC_URI" "source_data_${SUFFIX}" \
    "$POSTGRES_URI" "ingestr_bench_pg_csv"

# B08: PostgreSQL → CSV
run_pipeline "B08" "PostgreSQL → CSV" \
    "$POSTGRES_URI" "public.benchmark_source_${SUFFIX}" \
    "csv:///bench/artifacts/ingestr_bench_pg_to_csv.csv" "ingestr_bench_pg_to_csv"

# B09: Parquet → SQL Server
run_pipeline "B09" "Parquet → SQL Server" \
    "$PARQUET_SRC_URI" "source_data_${SUFFIX}" \
    "$MSSQL_URI" "ingestr_bench_mssql_pq" \
    "--columns id:binary"

# B10: SQL Server → Parquet
run_pipeline "B10" "SQL Server → Parquet" \
    "$MSSQL_URI" "dbo.benchmark_source_${SUFFIX}" \
    "parquet:///bench/artifacts/ingestr_bench_mssql_to_pq.parquet" "ingestr_bench_mssql_to_pq"

# B11: CSV → Oracle (Not supported as destination)
run_pipeline "B11" "CSV → Oracle" \
    "NOT_SUPPORTED" "" "" ""

# B12: Oracle → CSV
run_pipeline "B12" "Oracle → CSV" \
    "$ORACLE_URI" "${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
    "csv:///bench/artifacts/ingestr_bench_oracle_to_csv.csv" "ingestr_bench_oracle_to_csv" \
    "--columns ID:uuid"

# --- B13/B14/B15: Intra-DB benchmarks ---
POSTGRES_READER_URI="postgresql://${DB_POSTGRES_READER_USER:-bench_reader}:${DB_POSTGRES_READER_PASSWORD:-password}@$DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DB"
POSTGRES_WRITER_URI="postgresql://${DB_POSTGRES_WRITER_USER:-bench_writer}:${DB_POSTGRES_WRITER_PASSWORD:-password}@$DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DB"
MSSQL_READER_URI="mssql://${DB_MSSQL_READER_USER:-bench_reader}:${DB_MSSQL_READER_PASSWORD:-BenchReader1!}@$DB_MSSQL_HOST:$DB_MSSQL_PORT/$DB_MSSQL_DB?encrypt=disable"
MSSQL_WRITER_URI="mssql://${DB_MSSQL_WRITER_USER:-bench_writer}:${DB_MSSQL_WRITER_PASSWORD:-BenchWriter1!}@$DB_MSSQL_HOST:$DB_MSSQL_PORT/$DB_MSSQL_DB?encrypt=disable"

# B13: PostgreSQL → PostgreSQL
run_pipeline "B13" "PostgreSQL → PostgreSQL" \
    "$POSTGRES_READER_URI" "public.benchmark_source_${SUFFIX}" \
    "$POSTGRES_WRITER_URI" "${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.ingestr_bench_pg2pg" \
    "--columns id:text"

# B14: SQL Server → SQL Server
run_pipeline "B14" "SQL Server → SQL Server" \
    "$MSSQL_READER_URI" "dbo.benchmark_source_${SUFFIX}" \
    "$MSSQL_WRITER_URI" "${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.ingestr_bench_mssql2mssql"

# B15: Oracle → Oracle (Not supported: Oracle is not a supported destination in ingestr)
run_pipeline "B15" "Oracle → Oracle" \
    "NOT_SUPPORTED" "" "" ""


# =============================================================================
# Generate JSON report for ingestr
# =============================================================================
echo ""
echo -e "${YELLOW}Generating JSON report...${NC}"

{
    echo "{"
    echo '    "tool": "ingestr",'
    echo "    \"benchmark_rows\": $BENCHMARK_ROWS,"
    echo "    \"repetitions\": $BENCHMARK_REPETITIONS,"
    echo "    \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo '    "benchmarks": {'

    stats_json_benchmarks "$RESULTS_CSV" "      "
    echo '    }'
    echo "}"
} > "$ARTIFACTS_DIR/ingestr/ingestr_report.json"

echo -e "${GREEN}ingestr report saved: $ARTIFACTS_DIR/ingestr/ingestr_report.json${NC}"
