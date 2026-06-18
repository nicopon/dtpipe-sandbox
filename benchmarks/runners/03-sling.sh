#!/usr/bin/env bash
# =============================================================================
# 03-sling.sh - Sling benchmark (executions INSIDE benchmark-test container)
# Uses the sling CLI directly for fair comparison with other tools.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/../artifacts"
CONFIG_DIR="$SCRIPT_DIR/../config"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/container-runtime.sh"
init_container_runtime || exit 1
source "$LIB_DIR/mem-watcher.sh"

# Default values
BENCHMARK_ROWS=250000
BENCHMARK_REPETITIONS=3
BENCHMARK_SCOPE="all"         # all, B01-B12

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
        --rows)        BENCHMARK_ROWS="$2";        shift 2 ;;
        --repetitions) BENCHMARK_REPETITIONS="$2"; shift 2 ;;
        --scope)       BENCHMARK_SCOPE="$2";       shift 2 ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# Calculate rows suffix (e.g. 2m or 5m)
if [[ "$BENCHMARK_ROWS" -eq 5000000 ]]; then
    SUFFIX="5m"
elif [[ "$BENCHMARK_ROWS" -eq 2000000 ]]; then
    SUFFIX="2m"
else
    if (( BENCHMARK_ROWS % 1000000 == 0 )); then
        SUFFIX="$(( BENCHMARK_ROWS / 1000000 ))m"
    else
        SUFFIX="${BENCHMARK_ROWS}"
    fi
fi
SUFFIX_UPPER=$(echo "$SUFFIX" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_USER_UPPER=$(echo "${DB_ORACLE_USER:-testuser}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_WRITER_UPPER=$(echo "${DB_ORACLE_WRITER_USER:-bench_writer}" | tr '[:lower:]' '[:upper:]')

# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/sling"
RESULTS_CSV="$ARTIFACTS_DIR/sling/.tmp_results.csv"
> "$RESULTS_CSV"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  sling benchmark (benchmark-test container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure sling binary is loaded before the first timed run
echo -e "${YELLOW}Warming up sling...${NC}"
container_exec benchmark-test sling --version > /dev/null 2>&1 || true

# =============================================================================
# Benchmark function: Execute a sling CLI pipeline N times and record timings
# Args:
#   bench_id     - benchmark ID (e.g. B01)
#   description  - human-readable description
#   src_conn     - source connection URI (file:// or db://)
#   src_stream   - source table/query (empty for file sources)
#   tgt_conn     - target connection URI (empty for file targets)
#   tgt_object   - target table name or file:// URI
#   extra_flags  - optional extra sling flags
# =============================================================================
run_pipeline() {
    local bench_id="$1"
    local description="$2"
    local src_conn="$3"
    local src_stream="$4"
    local tgt_conn="$5"
    local tgt_object="$6"
    local extra_flags="${7:-}"

    if [[ "$BENCHMARK_SCOPE" != "all" ]] && [[ "$BENCHMARK_SCOPE" != "$bench_id" ]]; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id (sling): $description ---${NC}"

    # Build sling CLI command
    local sling_cmd="sling run --src-conn '${src_conn}'"
    [[ -n "$src_stream"  ]] && sling_cmd="${sling_cmd} --src-stream '${src_stream}'"
    [[ -n "$tgt_conn"    ]] && sling_cmd="${sling_cmd} --tgt-conn '${tgt_conn}'"
    sling_cmd="${sling_cmd} --tgt-object '${tgt_object}' --mode full-refresh"
    [[ -n "$extra_flags" ]] && sling_cmd="${sling_cmd} ${extra_flags}"

    # Write runner script to a temp file and copy it into the container (avoids quoting issues)
    local runner_script
    runner_script=$(mktemp)
    cat > "$runner_script" << 'RUNNER_HEADER'
#!/bin/bash
set +e
START=$(date +%s%N)
RUNNER_HEADER
    echo "${sling_cmd} > /tmp/out.txt 2>&1; EC=\$?" >> "$runner_script"
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

    # Calculate average (excluding ERROR runs)
    local sum=0
    local count=0
    for t in "${run_times[@]}"; do
        if [[ "$t" != ERROR:* ]]; then
            sum=$((sum + t))
            count=$((count + 1))
        fi
    done
    local avg=0
    [[ $count -gt 0 ]] && avg=$((sum / count))

    local mem_sum=0
    local mem_count=0
    for m in "${run_mem_peaks[@]+"${run_mem_peaks[@]}"}"; do
        mem_sum=$((mem_sum + m))
        mem_count=$((mem_count + 1))
    done
    local avg_mem=0
    [[ $mem_count -gt 0 ]] && avg_mem=$((mem_sum / mem_count))

    echo -e "   Average: ${avg} ms, peak memory delta: +${avg_mem} MiB ($count runs)"
    echo "$bench_id|$description|$avg|$avg_mem" >> "$RESULTS_CSV"

    if [[ "$avg" -ne 0 ]]; then
        container_exec benchmark-test /opt/venv/pandas/bin/python3 /bench/scripts/verify_data.py "sling" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# =============================================================================
# Connection URIs (built from benchmark.env variables)
# =============================================================================
POSTGRES_URI="postgresql://$DB_POSTGRES_USER:$DB_POSTGRES_PASSWORD@$DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DB?sslmode=disable"
MSSQL_URI="sqlserver://$DB_MSSQL_USER:$DB_MSSQL_PASSWORD@$DB_MSSQL_HOST:$DB_MSSQL_PORT?database=$DB_MSSQL_DB&encrypt=disable&TrustServerCertificate=true"
ORACLE_URI="oracle://$DB_ORACLE_USER:$DB_ORACLE_PASSWORD@$DB_ORACLE_HOST:$DB_ORACLE_PORT?service_name=$DB_ORACLE_SERVICE&PREFETCH_ROWS=50000"

PARQUET_SRC="file:///bench/artifacts/source_data_${SUFFIX}.parquet"
CSV_SRC="file:///bench/artifacts/source_data_${SUFFIX}.csv"

# =============================================================================
# Run Benchmarks
# =============================================================================

# B01: Parquet → PostgreSQL
run_pipeline "B01" "Parquet → PostgreSQL" \
    "$PARQUET_SRC" "" \
    "$POSTGRES_URI" "public.sling_bench_pg"

# B02: PostgreSQL → Parquet
run_pipeline "B02" "PostgreSQL → Parquet" \
    "$POSTGRES_URI" "public.benchmark_source_${SUFFIX}" \
    "" "file:///bench/artifacts/sling_bench_pg_to_pq.parquet"

# B03: CSV → SQL Server
run_pipeline "B03" "CSV → SQL Server" \
    "$CSV_SRC" "" \
    "$MSSQL_URI" "dbo.sling_bench_mssql"

# B04: SQL Server → CSV
run_pipeline "B04" "SQL Server → CSV" \
    "$MSSQL_URI" "dbo.benchmark_source_${SUFFIX}" \
    "" "file:///bench/artifacts/sling_bench_mssql_to_csv.csv"

# B05: Parquet → Oracle
run_pipeline "B05" "Parquet → Oracle" \
    "$PARQUET_SRC" "" \
    "$ORACLE_URI" "${DB_ORACLE_USER_UPPER}.SLING_BENCH_ORACLE"

# B06: Oracle → Parquet (RAWTOHEX wraps the RAW(16) UUID column for parquet compatibility)
run_pipeline "B06" "Oracle → Parquet" \
    "$ORACLE_URI" "SELECT RAWTOHEX(id) as id, name, email, amount, country FROM ${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
    "" "file:///bench/artifacts/sling_bench_oracle_to_pq.parquet"

# B07: CSV → PostgreSQL
run_pipeline "B07" "CSV → PostgreSQL" \
    "$CSV_SRC" "" \
    "$POSTGRES_URI" "public.sling_bench_pg_csv"

# B08: PostgreSQL → CSV
run_pipeline "B08" "PostgreSQL → CSV" \
    "$POSTGRES_URI" "public.benchmark_source_${SUFFIX}" \
    "" "file:///bench/artifacts/sling_bench_pg_to_csv.csv"

# B09: Parquet → SQL Server
run_pipeline "B09" "Parquet → SQL Server" \
    "$PARQUET_SRC" "" \
    "$MSSQL_URI" "dbo.sling_bench_mssql_pq"

# B10: SQL Server → Parquet
run_pipeline "B10" "SQL Server → Parquet" \
    "$MSSQL_URI" "dbo.benchmark_source_${SUFFIX}" \
    "" "file:///bench/artifacts/sling_bench_mssql_to_pq.parquet"

# B11: CSV → Oracle
run_pipeline "B11" "CSV → Oracle" \
    "$CSV_SRC" "" \
    "$ORACLE_URI" "${DB_ORACLE_USER_UPPER}.SLING_BENCH_ORACLE_CSV"

# B12: Oracle → CSV
run_pipeline "B12" "Oracle → CSV" \
    "$ORACLE_URI" "SELECT RAWTOHEX(id) as id, name, email, amount, country FROM ${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
    "" "file:///bench/artifacts/sling_bench_oracle_to_csv.csv"

# --- B13/B14/B15: Intra-DB benchmarks ---
POSTGRES_READER_URI="postgresql://${DB_POSTGRES_READER_USER:-bench_reader}:${DB_POSTGRES_READER_PASSWORD:-password}@$DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DB?sslmode=disable"
POSTGRES_WRITER_URI="postgresql://${DB_POSTGRES_WRITER_USER:-bench_writer}:${DB_POSTGRES_WRITER_PASSWORD:-password}@$DB_POSTGRES_HOST:$DB_POSTGRES_PORT/$DB_POSTGRES_DB?sslmode=disable"
MSSQL_READER_URI="sqlserver://${DB_MSSQL_READER_USER:-bench_reader}:${DB_MSSQL_READER_PASSWORD:-BenchReader1!}@$DB_MSSQL_HOST:$DB_MSSQL_PORT?database=$DB_MSSQL_DB&encrypt=disable&TrustServerCertificate=true"
MSSQL_WRITER_URI="sqlserver://${DB_MSSQL_WRITER_USER:-bench_writer}:${DB_MSSQL_WRITER_PASSWORD:-BenchWriter1!}@$DB_MSSQL_HOST:$DB_MSSQL_PORT?database=$DB_MSSQL_DB&encrypt=disable&TrustServerCertificate=true"
ORACLE_READER_URI="oracle://${DB_ORACLE_READER_USER:-bench_reader}:${DB_ORACLE_READER_PASSWORD:-password}@$DB_ORACLE_HOST:$DB_ORACLE_PORT?service_name=$DB_ORACLE_SERVICE&PREFETCH_ROWS=50000"
ORACLE_WRITER_URI="oracle://${DB_ORACLE_WRITER_USER:-bench_writer}:${DB_ORACLE_WRITER_PASSWORD:-password}@$DB_ORACLE_HOST:$DB_ORACLE_PORT?service_name=$DB_ORACLE_SERVICE&PREFETCH_ROWS=50000"

# B13: PostgreSQL → PostgreSQL
run_pipeline "B13" "PostgreSQL → PostgreSQL" \
    "$POSTGRES_READER_URI" "public.benchmark_source_${SUFFIX}" \
    "$POSTGRES_WRITER_URI" "${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.sling_bench_pg2pg"

# B14: SQL Server → SQL Server
run_pipeline "B14" "SQL Server → SQL Server" \
    "$MSSQL_READER_URI" "dbo.benchmark_source_${SUFFIX}" \
    "$MSSQL_WRITER_URI" "${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.sling_bench_mssql2mssql"

# B15: Oracle → Oracle (RAWTOHEX for RAW(16) UUID column)
run_pipeline "B15" "Oracle → Oracle" \
    "$ORACLE_READER_URI" "SELECT RAWTOHEX(id) as id, name, email, amount, country FROM ${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
    "$ORACLE_WRITER_URI" "${DB_ORACLE_WRITER_UPPER}.SLING_BENCH_ORA2ORA"

# =============================================================================
# Generate JSON report for sling
# =============================================================================
echo ""
echo -e "${YELLOW}Generating JSON report...${NC}"

{
    echo "{"
    echo '    "tool": "sling",'
    echo "    \"benchmark_rows\": $BENCHMARK_ROWS,"
    echo "    \"repetitions\": $BENCHMARK_REPETITIONS,"
    echo "    \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo '    "benchmarks": {'

    first=true
    while IFS='|' read -r bid bdesc bavg bavg_mem; do
        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false
        mem_val="${bavg_mem:-0}"
        if ! [[ "$mem_val" =~ ^[0-9]+$ ]]; then
            mem_val="\"$mem_val\""
        fi
        if [[ "$bavg" =~ ^[0-9]+$ ]]; then
            printf '      "%s": { "description": "%s", "avg_duration_ms": %s, "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "$mem_val"
        else
            printf '      "%s": { "description": "%s", "avg_duration_ms": "%s", "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "$mem_val"
        fi
    done < "$RESULTS_CSV"

    echo ""
    echo '    }'
    echo "}"
} > "$ARTIFACTS_DIR/sling/sling_report.json"

echo -e "${GREEN}sling report saved: $ARTIFACTS_DIR/sling/sling_report.json${NC}"
