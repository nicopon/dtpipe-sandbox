#!/usr/bin/env bash
# =============================================================================
# 03-native.sh - Native tools benchmark (executions INSIDE benchmark-test container)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/../artifacts"
CONFIG_DIR="$SCRIPT_DIR/../config"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source le module de détection du runtime container (docker / podman)
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
mkdir -p "$ARTIFACTS_DIR/native"
RESULTS_CSV="$ARTIFACTS_DIR/native/.tmp_results.csv"
> "$RESULTS_CSV"         # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Native tools benchmark (benchmark-test container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure native CLI tools are loaded before the first timed run
echo -e "${YELLOW}Warming up native tools...${NC}"
container_exec benchmark-test bash -c 'psql --version && sqlcmd -? > /dev/null 2>&1; sqlplus -V' > /dev/null 2>&1 || true

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
    echo -e "${YELLOW}--- $bench_id (native): $description ---${NC}"

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        # Run setup command if defined (not timed, run before EVERY repetition to reset DB state)
        if [[ -n "$setup_cmd" ]]; then
            container_exec benchmark-test bash -c "$setup_cmd" > /dev/null || {
                echo -e "   ${RED}Setup FAILED${NC}"
                run_times+=("ERROR:0")
                continue
            }
        fi

        # Write runner script to a temp file and copy it into the container (avoids quoting issues)
        local runner_script
        runner_script=$(mktemp)
        cat > "$runner_script" << 'RUNNER_HEADER'
#!/bin/bash
set +e
START=$(date +%s%N)
RUNNER_HEADER
        echo "$run_cmd > /tmp/out.txt 2>&1; EC=\$?" >> "$runner_script"
        cat >> "$runner_script" << 'RUNNER_FOOTER'
END=$(date +%s%N)
echo "ELAPSED_MS:$(( (END-START)/1000000 )):$EC"
cat /tmp/out.txt; rm -f /tmp/out.txt
RUNNER_FOOTER
        container_cp "$runner_script" benchmark-test:/tmp/bench_runner.sh
        rm -f "$runner_script"

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

    # Verify target data matches source (run inside benchmark-test container)
    if [[ "$avg" -ne 0 ]]; then
        container_exec benchmark-test /opt/venv/pandas/bin/python3 /bench/scripts/verify_data.py "native" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# =============================================================================
# =============================================================================
# B01: Parquet → PostgreSQL (Not natively supported)
# =============================================================================
echo "B01|Parquet → PostgreSQL|Not supported|N/A" >> "$RESULTS_CSV"

# =============================================================================
# B02: PostgreSQL → Parquet (Not natively supported)
# =============================================================================
echo "B02|PostgreSQL → Parquet|Not supported|N/A" >> "$RESULTS_CSV"

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
echo "B05|Parquet → Oracle|Not supported|N/A" >> "$RESULTS_CSV"

# =============================================================================
# B06: Oracle → Parquet (Not natively supported)
# =============================================================================
echo "B06|Oracle → Parquet|Not supported|N/A" >> "$RESULTS_CSV"

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
echo "B09|Parquet → SQL Server|Not supported|N/A" >> "$RESULTS_CSV"

# =============================================================================
# B10: SQL Server → Parquet (Not natively supported)
# =============================================================================
echo "B10|SQL Server → Parquet|Not supported|N/A" >> "$RESULTS_CSV"

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

DB_ORACLE_USER_UPPER=$(echo "${DB_ORACLE_USER:-testuser}" | tr '[:lower:]' '[:upper:]')
DB_ORACLE_WRITER_UPPER=$(echo "${DB_ORACLE_WRITER_USER:-bench_writer}" | tr '[:lower:]' '[:upper:]')

# =============================================================================
# B13: PostgreSQL → PostgreSQL (pg_dump custom format → pg_restore)
# Uses two separate accounts: bench_reader dumps, bench_writer restores
# =============================================================================
# COPY TO STDOUT (FORMAT binary) piped to COPY FROM STDIN (FORMAT binary).
# No pg_dump/pg_restore version dependency — pure SQL protocol, works across all PG versions.
# Setup: drop+recreate target table with same schema (LIKE), owned by bench_writer.
B13_SETUP="PGPASSWORD=\"${DB_POSTGRES_WRITER_PASSWORD:-password}\" psql \
  -h \"$DB_POSTGRES_HOST\" -p \"$DB_POSTGRES_PORT\" \
  -U \"${DB_POSTGRES_WRITER_USER:-bench_writer}\" -d \"$DB_POSTGRES_DB\" -c \
  \"DROP TABLE IF EXISTS ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.native_bench_pg2pg CASCADE; \
    CREATE TABLE ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.native_bench_pg2pg \
      (id UUID, name TEXT, email TEXT, amount NUMERIC, country TEXT);\""


B13_RUN="PGPASSWORD=\"${DB_POSTGRES_READER_PASSWORD:-password}\" psql \
  -h \"$DB_POSTGRES_HOST\" -p \"$DB_POSTGRES_PORT\" \
  -U \"${DB_POSTGRES_READER_USER:-bench_reader}\" -d \"$DB_POSTGRES_DB\" \
  -c \"\\\\copy (SELECT * FROM benchmark_source_${SUFFIX}) TO STDOUT (FORMAT binary)\" \
  | PGPASSWORD=\"${DB_POSTGRES_WRITER_PASSWORD:-password}\" psql \
  -h \"$DB_POSTGRES_HOST\" -p \"$DB_POSTGRES_PORT\" \
  -U \"${DB_POSTGRES_WRITER_USER:-bench_writer}\" -d \"$DB_POSTGRES_DB\" \
  -c \"\\\\copy ${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}.native_bench_pg2pg FROM STDIN (FORMAT binary)\""

run_native_benchmark "B13" "PostgreSQL → PostgreSQL" "$B13_SETUP" "$B13_RUN"

# =============================================================================
# B14: SQL Server → SQL Server (bcp binary out → bcp binary in)
# Uses bench_reader for export, bench_writer for import
# =============================================================================
B14_SETUP="sqlcmd -C -S \"$DB_MSSQL_HOST,$DB_MSSQL_PORT\" -U \"${DB_MSSQL_WRITER_USER:-bench_writer}\" -P \"${DB_MSSQL_WRITER_PASSWORD:-BenchWriter1!}\" -Q \"IF OBJECT_ID('${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.native_bench_mssql2mssql', 'U') IS NOT NULL DROP TABLE ${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.native_bench_mssql2mssql; CREATE TABLE ${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.native_bench_mssql2mssql (id UNIQUEIDENTIFIER, name NVARCHAR(MAX), email NVARCHAR(MAX), amount DECIMAL(18,2), country NVARCHAR(MAX));\""

B14_RUN="bcp \"SELECT * FROM master.dbo.benchmark_source_${SUFFIX}\" queryout /tmp/native_bench_mssql2mssql.bcp -n -u -S \"$DB_MSSQL_HOST,$DB_MSSQL_PORT\" -U \"${DB_MSSQL_READER_USER:-bench_reader}\" -P \"${DB_MSSQL_READER_PASSWORD:-BenchReader1!}\" && \
bcp ${DB_MSSQL_WRITER_SCHEMA:-bench_tgt}.native_bench_mssql2mssql in /tmp/native_bench_mssql2mssql.bcp -n -u -S \"$DB_MSSQL_HOST,$DB_MSSQL_PORT\" -U \"${DB_MSSQL_WRITER_USER:-bench_writer}\" -P \"${DB_MSSQL_WRITER_PASSWORD:-BenchWriter1!}\""

run_native_benchmark "B14" "SQL Server → SQL Server" "$B14_SETUP" "$B14_RUN"

# =============================================================================
# B15: Oracle → Oracle (sqlplus spool CSV → sqlldr into bench_writer schema)
# Oracle sqlldr has no binary format; CSV is the native high-performance path
# =============================================================================
B15_SETUP="echo \"SET MARKUP CSV ON DELIMITER ',' QUOTE ON\" > /tmp/spool_ora2ora.sql && \
echo \"SET FEEDBACK OFF\" >> /tmp/spool_ora2ora.sql && \
echo \"SET HEADING OFF\" >> /tmp/spool_ora2ora.sql && \
echo \"SET TRIMSPOOL ON\" >> /tmp/spool_ora2ora.sql && \
echo \"SET PAGESIZE 0\" >> /tmp/spool_ora2ora.sql && \
echo \"SPOOL /tmp/native_bench_ora2ora.csv\" >> /tmp/spool_ora2ora.sql && \
echo \"SELECT RAWTOHEX(id) as id, name, email, amount, country FROM ${DB_ORACLE_USER_UPPER}.BENCHMARK_SOURCE_${SUFFIX_UPPER};\" >> /tmp/spool_ora2ora.sql && \
echo \"SPOOL OFF\" >> /tmp/spool_ora2ora.sql && \
echo \"EXIT;\" >> /tmp/spool_ora2ora.sql && \
sqlplus -S \"${DB_ORACLE_READER_USER:-bench_reader}/${DB_ORACLE_READER_PASSWORD:-password}@//$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE\" @/tmp/spool_ora2ora.sql && \
echo \"OPTIONS (SKIP=0)\" > /tmp/sqlldr_ora2ora.ctl && \
echo \"LOAD DATA\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"INFILE '/tmp/native_bench_ora2ora.csv'\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"INTO TABLE ${DB_ORACLE_WRITER_UPPER}.NATIVE_BENCH_ORA2ORA\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '\\\"'\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"TRAILING NULLCOLS\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"(\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"  ID CHAR(36) \\\"HEXTORAW(REPLACE(:ID, '-', ''))\\\",\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"  NAME CHAR(255),\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"  EMAIL CHAR(255),\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"  AMOUNT DECIMAL EXTERNAL,\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"  COUNTRY CHAR(10)\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \")\" >> /tmp/sqlldr_ora2ora.ctl && \
echo \"BEGIN\" > /tmp/setup_ora2ora.sql && \
echo \"  EXECUTE IMMEDIATE 'DROP TABLE ${DB_ORACLE_WRITER_UPPER}.NATIVE_BENCH_ORA2ORA';\" >> /tmp/setup_ora2ora.sql && \
echo \"EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF; END;\" >> /tmp/setup_ora2ora.sql && \
echo \"/\" >> /tmp/setup_ora2ora.sql && \
echo \"CREATE TABLE ${DB_ORACLE_WRITER_UPPER}.NATIVE_BENCH_ORA2ORA (id RAW(16), name VARCHAR2(4000), email VARCHAR2(4000), amount NUMBER, country VARCHAR2(4000));\" >> /tmp/setup_ora2ora.sql && \
echo \"EXIT;\" >> /tmp/setup_ora2ora.sql && \
sqlplus -S \"${DB_ORACLE_WRITER_USER:-bench_writer}/${DB_ORACLE_WRITER_PASSWORD:-password}@//$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE\" @/tmp/setup_ora2ora.sql"

B15_RUN="sqlldr userid=\"${DB_ORACLE_WRITER_USER:-bench_writer}/${DB_ORACLE_WRITER_PASSWORD:-password}@//$DB_ORACLE_HOST:$DB_ORACLE_PORT/$DB_ORACLE_SERVICE\" control=/tmp/sqlldr_ora2ora.ctl log=/tmp/sqlldr_ora2ora.log bad=/tmp/sqlldr_ora2ora.bad direct=true"

run_native_benchmark "B15" "Oracle → Oracle" "$B15_SETUP" "$B15_RUN"


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
        mem_val="${bavg_mem:-0}"
        if ! [[ "$mem_val" =~ ^[0-9]+$ ]]; then
            mem_val="\"$mem_val\""
        fi
        if [[ "$bavg" =~ ^[0-9]+$ ]]; then
            printf '       "%s": { "description": "%s", "avg_duration_ms": %s, "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "$mem_val"
        else
            printf '       "%s": { "description": "%s", "avg_duration_ms": "%s", "avg_peak_mem_mb": %s }' "$bid" "$bdesc" "$bavg" "$mem_val"
        fi
    done < "$RESULTS_CSV"

    echo ""
    echo '     }'
    echo "}"
} > "$ARTIFACTS_DIR/native/native_report.json"

echo -e "${GREEN}Native report saved: $ARTIFACTS_DIR/native/native_report.json${NC}"