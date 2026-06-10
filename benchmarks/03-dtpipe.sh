#!/usr/bin/env bash
# =============================================================================
# 03-dtpipe.sh - dtpipe benchmark (executions INSIDE benchmark-dtpipe container)
# Runs the same pipelines as Meltano and Sling for comparison
#
# IMPORTANT: Everything runs inside the container, nothing on the host
# =============================================================================

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
echo -e "${GREEN}  dtpipe benchmark (benchmark-dtpipe container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# =============================================================================
# Benchmark function: Execute a dtpipe pipeline N times and record timings
# Writes a runner script into the container to avoid shell quoting issues
# =============================================================================
run_pipeline() {
    local bench_id="$1"
    local description="$2"
    shift 2

       # Check if this benchmark should run based on scope
    if [[ "$BENCHMARK_SCOPE" != "all" ]] && [[ "$BENCHMARK_SCOPE" != "$bench_id" ]]; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id: $description ---${NC}"

       # Write a runner script to a temp file on the host
    local runner_script="$RUNNER_TMP/${bench_id}.sh"
    cat > "$runner_script" << 'SCRIPT_HEADER'
#!/bin/bash
set +e
export PATH="${PATH}:/root/.dotnet/tools"
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
    container_cp "$runner_script" benchmark-dtpipe:/tmp/bench_runner.sh || {
        echo -e " ${RED}FAILED (script copy impossible)${NC}"
        return
     }

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        mem_watcher_start benchmark-dtpipe
            # Execute the runner script inside the container
        local output
        output=$(container_exec benchmark-dtpipe bash /tmp/bench_runner.sh 2>&1) || true
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
        python3 "$SCRIPT_DIR/scripts/verify_data.py" "dtpipe" "$bench_id" "$BENCHMARK_ROWS" || true
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

    first=true
    while IFS='|' read -r bid bdesc bavg bavg_mem; do
        if [[ "$first" != "true" ]]; then
            echo ","
        fi
        first=false
        printf '            "%s": { "description": "%s", "avg_duration_ms": %s, "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "${bavg_mem:-0}"
    done < "$RESULTS_CSV"

    echo ""
    echo "        }"
    echo "}"
} > "$ARTIFACTS_DIR/dtpipe/dtpipe_report.json"

echo -e "${GREEN}dtpipe report saved: $ARTIFACTS_DIR/dtpipe/dtpipe_report.json${NC}"