#!/usr/bin/env bash
# =============================================================================
# 03-native.sh - Native tools benchmark (executions INSIDE benchmark-native container)
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

# Container compose helper (runs from config directory)
container_compose_helper() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml "$@"
}

# Container exec helper for benchmark-native container
exec_native_container() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec benchmark-native bash -c "$1"
}

# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/native"
RESULTS_CSV="$ARTIFACTS_DIR/native/.tmp_results.csv"
> "$RESULTS_CSV"         # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Native tools benchmark (benchmark-native container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure native CLI tools are loaded before the first timed run
echo -e "${YELLOW}Warming up native tools...${NC}"
exec_native_container "psql --version && sqlcmd -? > /dev/null 2>&1; sqlplus -V" > /dev/null 2>&1 || true

# =============================================================================
# Benchmark function: Execute a command N times and record timings
# =============================================================================
run_native_benchmark() {
    local bench_id="$1"
    local description="$2"
    local setup_cmd="$3"
    local run_cmd="$4"

        # Check if this benchmark should run based on scope
    if [[ "$BENCHMARK_SCOPE" != "all" ]] && [[ "$BENCHMARK_SCOPE" != "$bench_id" ]]; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id: $description ---${NC}"

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

         # Run setup command if defined (not timed, run before EVERY repetition to reset DB state)
        if [[ -n "$setup_cmd" ]]; then
            exec_native_container "$setup_cmd" > /dev/null || {
                echo -e "   ${RED}Setup FAILED${NC}"
                run_times+=("ERROR:0")
                continue
             }
        fi

        mem_watcher_start benchmark-native
         # Execute the native command inside the container and capture timing using /usr/bin/time
        if exec_native_container "/usr/bin/time -f '%e' -o /tmp/native_timing_${bench_id}_$i.txt $run_cmd > /tmp/native_output_${bench_id}_$i.txt 2>&1"; then
            local peak_mem
            peak_mem=$(mem_watcher_stop)
             # Extract timing from the container's output file
            local wall_time
            wall_time=$(exec_native_container "cat /tmp/native_timing_${bench_id}_$i.txt" || echo "")

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

            exec_native_container "rm -f /tmp/native_timing_${bench_id}_$i.txt /tmp/native_output_${bench_id}_$i.txt" >/dev/null 2>&1 || true
        else
            mem_watcher_stop > /dev/null
            echo -e " ${RED}FAILED${NC}"
            exec_native_container "cat /tmp/native_output_${bench_id}_$i.txt" || true
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
        python3 "$SCRIPT_DIR/scripts/verify_data.py" "native" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# =============================================================================
# =============================================================================
# B01: Parquet → PostgreSQL (Not natively supported)
# =============================================================================
echo "B01|Parquet → PostgreSQL|Not supported" >> "$RESULTS_CSV"

# =============================================================================
# B02: PostgreSQL → Parquet (Not natively supported)
# =============================================================================
echo "B02|PostgreSQL → Parquet|Not supported" >> "$RESULTS_CSV"

# =============================================================================
# B03: CSV → SQL Server (bcp in)
# =============================================================================
B03_SETUP="sqlcmd -C -S \"$DB_MSSQL_HOST,$DB_MSSQL_PORT\" -U \"$DB_MSSQL_USER\" -P \"$DB_MSSQL_PASSWORD\" -Q \"IF OBJECT_ID('native_bench_mssql', 'U') IS NOT NULL DROP TABLE native_bench_mssql; SELECT TOP 0 * INTO native_bench_mssql FROM benchmark_source_${SUFFIX};\""
B03_RUN="bcp native_bench_mssql in \"/bench/artifacts/source_data_${SUFFIX}.csv\" -c -t ',' -F 2 -u -S \"$DB_MSSQL_HOST,$DB_MSSQL_PORT\" -U \"$DB_MSSQL_USER\" -P \"$DB_MSSQL_PASSWORD\""
run_native_benchmark "B03" "CSV → SQL Server" "$B03_SETUP" "$B03_RUN"

# =============================================================================
# B04: SQL Server → CSV (bcp out)
# =============================================================================
B04_SETUP=""
B04_RUN="bcp \"SELECT * FROM master.dbo.benchmark_source_${SUFFIX}\" queryout \"/bench/artifacts/native_bench_mssql_to_csv.csv\" -c -t ',' -u -S \"$DB_MSSQL_HOST,$DB_MSSQL_PORT\" -U \"$DB_MSSQL_USER\" -P \"$DB_MSSQL_PASSWORD\""
run_native_benchmark "B04" "SQL Server → CSV" "$B04_SETUP" "$B04_RUN"

# =============================================================================
# B05: Parquet → Oracle (Not natively supported)
# =============================================================================
echo "B05|Parquet → Oracle|Not supported" >> "$RESULTS_CSV"

# =============================================================================
# B06: Oracle → Parquet (Not natively supported)
# =============================================================================
echo "B06|Oracle → Parquet|Not supported" >> "$RESULTS_CSV"

# =============================================================================
# B07: CSV → PostgreSQL (psql \copy in)
# =============================================================================
B07_SETUP="PGPASSWORD=\"$DB_POSTGRES_PASSWORD\" psql -h \"$DB_POSTGRES_HOST\" -p \"$DB_POSTGRES_PORT\" -U \"$DB_POSTGRES_USER\" -d \"$DB_POSTGRES_DB\" -c \"DROP TABLE IF EXISTS native_bench_pg; CREATE TABLE native_bench_pg AS SELECT * FROM benchmark_source_${SUFFIX} LIMIT 0;\" && echo \"\\\\copy native_bench_pg FROM '/bench/artifacts/source_data_${SUFFIX}.csv' WITH CSV HEADER\" > /tmp/pg_load.sql"
B07_RUN="env PGPASSWORD=\"$DB_POSTGRES_PASSWORD\" psql -h \"$DB_POSTGRES_HOST\" -p \"$DB_POSTGRES_PORT\" -U \"$DB_POSTGRES_USER\" -d \"$DB_POSTGRES_DB\" -f /tmp/pg_load.sql"
run_native_benchmark "B07" "CSV → PostgreSQL" "$B07_SETUP" "$B07_RUN"

# =============================================================================
# B08: PostgreSQL → CSV (psql \copy out)
# =============================================================================
B08_SETUP="echo \"\\\\copy (SELECT * FROM benchmark_source_${SUFFIX}) TO '/bench/artifacts/native_bench_pg_to_csv.csv' WITH CSV HEADER\" > /tmp/pg_unload.sql"
B08_RUN="env PGPASSWORD=\"$DB_POSTGRES_PASSWORD\" psql -h \"$DB_POSTGRES_HOST\" -p \"$DB_POSTGRES_PORT\" -U \"$DB_POSTGRES_USER\" -d \"$DB_POSTGRES_DB\" -f /tmp/pg_unload.sql"
run_native_benchmark "B08" "PostgreSQL → CSV" "$B08_SETUP" "$B08_RUN"


# =============================================================================
# B09: Parquet → SQL Server (Not natively supported)
# =============================================================================
echo "B09|Parquet → SQL Server|Not supported" >> "$RESULTS_CSV"

# =============================================================================
# B10: SQL Server → Parquet (Not natively supported)
# =============================================================================
echo "B10|SQL Server → Parquet|Not supported" >> "$RESULTS_CSV"

# =============================================================================
# B11: CSV → Oracle (sqlldr)
# =============================================================================
B11_SETUP="echo \"OPTIONS (SKIP=1)\" > /tmp/sqlldr.ctl && \
echo \"LOAD DATA\" >> /tmp/sqlldr.ctl && \
echo \"INFILE '/bench/artifacts/source_data_${SUFFIX}.csv'\" >> /tmp/sqlldr.ctl && \
echo \"INTO TABLE NATIVE_BENCH_ORACLE\" >> /tmp/sqlldr.ctl && \
echo \"FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\\\"'\" >> /tmp/sqlldr.ctl && \
echo \"TRAILING NULLCOLS\" >> /tmp/sqlldr.ctl && \
echo \"(\" >> /tmp/sqlldr.ctl && \
echo \"  ID CHAR(36) \\\"HEXTORAW(REPLACE(:ID, '-', ''))\\\",\" >> /tmp/sqlldr.ctl && \
echo \"  NAME CHAR(255),\" >> /tmp/sqlldr.ctl && \
echo \"  EMAIL CHAR(255),\" >> /tmp/sqlldr.ctl && \
echo \"  AMOUNT DECIMAL EXTERNAL,\" >> /tmp/sqlldr.ctl && \
echo \"  COUNTRY CHAR(10)\" >> /tmp/sqlldr.ctl && \
echo \")\" >> /tmp/sqlldr.ctl && \
echo \"BEGIN EXECUTE IMMEDIATE 'DROP TABLE NATIVE_BENCH_ORACLE'; EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;\" > /tmp/setup_oracle.sql && \
echo \"/\" >> /tmp/setup_oracle.sql && \
echo \"CREATE TABLE NATIVE_BENCH_ORACLE AS SELECT * FROM BENCHMARK_SOURCE_${SUFFIX_UPPER} WHERE 1=0;\" >> /tmp/setup_oracle.sql && \
echo \"EXIT;\" >> /tmp/setup_oracle.sql && \
sqlplus -S \"$DB_ORACLE_USER/$DB_ORACLE_PASSWORD@//$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE\" @/tmp/setup_oracle.sql"

B11_RUN="sqlldr userid=\"$DB_ORACLE_USER/$DB_ORACLE_PASSWORD@//$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE\" control=/tmp/sqlldr.ctl log=/tmp/sqlldr.log bad=/tmp/sqlldr.bad direct=true"
run_native_benchmark "B11" "CSV → Oracle" "$B11_SETUP" "$B11_RUN"

# =============================================================================
# B12: Oracle → CSV (sqlplus spool)
# =============================================================================
B12_SETUP="echo \"SET MARKUP CSV ON DELIMITER ',' QUOTE ON\" > /tmp/unload_oracle.sql && \
echo \"SET FEEDBACK OFF\" >> /tmp/unload_oracle.sql && \
echo \"SET TRIMSPOOL ON\" >> /tmp/unload_oracle.sql && \
echo \"SET PAGESIZE 0\" >> /tmp/unload_oracle.sql && \
echo \"SPOOL /bench/artifacts/native_bench_oracle_to_csv.csv\" >> /tmp/unload_oracle.sql && \
echo \"SELECT RAWTOHEX(id) as id, name, email, amount, country FROM BENCHMARK_SOURCE_${SUFFIX_UPPER};\" >> /tmp/unload_oracle.sql && \
echo \"SPOOL OFF\" >> /tmp/unload_oracle.sql && \
echo \"EXIT;\" >> /tmp/unload_oracle.sql"

B12_RUN="sqlplus -S \"$DB_ORACLE_USER/$DB_ORACLE_PASSWORD@//$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE\" @/tmp/unload_oracle.sql"
run_native_benchmark "B12" "Oracle → CSV" "$B12_SETUP" "$B12_RUN"


# =============================================================================
# Generate JSON report for native
# =============================================================================
echo ""
echo -e "${YELLOW}Generating JSON report...${NC}"

{
    echo "{"
    echo '     "tool": "native",'
    echo "     \"benchmark_rows\": $BENCHMARK_ROWS,"
    echo "     \"repetitions\": $BENCHMARK_REPETITIONS,"
    echo "     \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo '     "benchmarks": {'

    first=true
    while IFS='|' read -r bid bdesc bavg bavg_mem; do
        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false
        if [[ "$bavg" =~ ^[0-9]+$ ]]; then
            printf '       "%s": { "description": "%s", "avg_duration_ms": %s, "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "${bavg_mem:-0}"
        else
            printf '       "%s": { "description": "%s", "avg_duration_ms": "%s", "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "${bavg_mem:-0}"
        fi
    done < "$RESULTS_CSV"

    echo ""
    echo '     }'
    echo "}"
} > "$ARTIFACTS_DIR/native/native_report.json"

echo -e "${GREEN}Native report saved: $ARTIFACTS_DIR/native/native_report.json${NC}"