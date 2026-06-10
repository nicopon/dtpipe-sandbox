#!/usr/bin/env bash
# =============================================================================
# 03-ingestr.sh - Ingestr benchmark (executions INSIDE benchmark-ingestr container)
# Runs the same pipelines as other tools for comparison
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
CONFIG_DIR="$SCRIPT_DIR/config"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"

# Source le module de détection du runtime container (docker / podman)
source "$LIB_DIR/container-runtime.sh"
init_container_runtime || exit 1
source "$LIB_DIR/mem-watcher.sh"

# Default values
BENCHMARK_ROWS=2000000
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

# Container compose helper (runs from config directory)
container_compose_helper() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml "$@"
}

# Container exec helper for benchmark-ingestr container
exec_ingestr_container() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec benchmark-ingestr bash -c "$1"
}

# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/ingestr"
RESULTS_CSV="$ARTIFACTS_DIR/ingestr/.tmp_results.csv"
> "$RESULTS_CSV"        # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  ingestr benchmark (benchmark-ingestr container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure ingestr binary is loaded before the first timed run
echo -e "${YELLOW}Warming up ingestr...${NC}"
exec_ingestr_container "ingestr --version" > /dev/null 2>&1 || true

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
        echo "$bench_id|$description|Not supported" >> "$RESULTS_CSV"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id: $description ---${NC}"

    # Build the ingestr command
    local ingestr_cmd="ingestr ingest --source-uri '$src_uri' --source-table '$src_table' --dest-uri '$dest_uri' --dest-table '$dest_table' --yes --progress log --full-refresh --schema-naming direct $extra_flags"

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        mem_watcher_start benchmark-ingestr
        # Execute ingestr inside the container and capture timing
        if exec_ingestr_container "/usr/bin/time -f '%e' -o /tmp/ingestr_timing_${bench_id}_$i.txt $ingestr_cmd > /tmp/ingestr_output_${bench_id}_$i.txt 2>&1"; then
            local peak_mem
            peak_mem=$(mem_watcher_stop)
            # Extract timing from the container's output file
            local wall_time
            wall_time=$(exec_ingestr_container "cat /tmp/ingestr_timing_${bench_id}_$i.txt" || echo "")

            if [[ -n "$wall_time" ]]; then
                local ms
                ms=$(echo "$wall_time" | awk '{printf "%d", $1 * 1000}')
                echo -e " ${GREEN}OK (${ms} ms, +${peak_mem} MiB)${NC}"
                run_times+=("$ms")
                run_mem_peaks+=("$peak_mem")
            else
                echo -e " ${GREEN}OK (measurement not available)${NC}"
                run_times+=("0")
            fi

            exec_ingestr_container "rm -f /tmp/ingestr_timing_${bench_id}_$i.txt /tmp/ingestr_output_${bench_id}_$i.txt" >/dev/null 2>&1 || true
        else
            mem_watcher_stop > /dev/null
            echo -e " ${RED}FAILED${NC}"
            exec_ingestr_container "cat /tmp/ingestr_output_${bench_id}_$i.txt" || true
            run_times+=("ERROR:0")
            exec_ingestr_container "rm -f /tmp/ingestr_timing_${bench_id}_$i.txt /tmp/ingestr_output_${bench_id}_$i.txt" >/dev/null 2>&1 || true
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
    if [[ $count -gt 0 ]]; then
        avg=$((sum / count))
    fi

    local mem_sum=0
    local mem_count=0
    for m in "${run_mem_peaks[@]+"${run_mem_peaks[@]}"}"; do
        mem_sum=$((mem_sum + m))
        mem_count=$((mem_count + 1))
    done
    local avg_mem=0
    if [[ $mem_count -gt 0 ]]; then
        avg_mem=$((mem_sum / mem_count))
    fi

    echo -e "   Average: ${avg} ms, peak memory delta: +${avg_mem} MiB ($count runs)"

    # Store result
    echo "$bench_id|$description|$avg|$avg_mem" >> "$RESULTS_CSV"

    # Verify target data matches source
    if [[ "$avg" -ne 0 ]]; then
        python3 "$SCRIPT_DIR/scripts/verify_data.py" "ingestr" "$bench_id" "$BENCHMARK_ROWS" || true
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
    "$ORACLE_URI" "TESTUSER.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
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
    "$ORACLE_URI" "TESTUSER.BENCHMARK_SOURCE_${SUFFIX_UPPER}" \
    "csv:///bench/artifacts/ingestr_bench_oracle_to_csv.csv" "ingestr_bench_oracle_to_csv" \
    "--columns ID:uuid"


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

    first=true
    while IFS='|' read -r bid bdesc bavg bavg_mem; do
        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false
        if [[ "$bavg" =~ ^[0-9]+$ ]]; then
            printf '      "%s": { "description": "%s", "avg_duration_ms": %s, "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "${bavg_mem:-0}"
        else
            printf '      "%s": { "description": "%s", "avg_duration_ms": "%s", "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "${bavg_mem:-0}"
        fi
    done < "$RESULTS_CSV"

    echo ""
    echo '    }'
    echo "}"
} > "$ARTIFACTS_DIR/ingestr/ingestr_report.json"

echo -e "${GREEN}ingestr report saved: $ARTIFACTS_DIR/ingestr/ingestr_report.json${NC}"
