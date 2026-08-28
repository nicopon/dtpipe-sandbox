#!/usr/bin/env bash
# =============================================================================
# 03-meltano.sh - Meltano benchmark (executions INSIDE benchmark-test container)
# Runs actual Meltano pipelines using Singer taps and targets
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
    if (( BENCHMARK_ROWS % 1000000 == 0 )); then
        SUFFIX="$(( BENCHMARK_ROWS / 1000000 ))m"
    else
        SUFFIX="${BENCHMARK_ROWS}"
    fi
fi


# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/meltano"
RESULTS_CSV="$ARTIFACTS_DIR/meltano/.tmp_results.csv"
> "$RESULTS_CSV"        # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  meltano benchmark (benchmark-test container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Warm-up: ensure meltano and its plugins are loaded before the first timed run
echo -e "${YELLOW}Warming up meltano...${NC}"
container_exec benchmark-test /opt/venv/meltano/bin/meltano --version > /dev/null 2>&1 || true

# Helper to run database drops prior to Meltano runs to ensure a clean schema
drop_target_table() {
    local target_db="$1"
    local table_name="$2"
    
    if [[ "$target_db" == "postgres" ]]; then
        local schema="${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}"
        container_exec dtpipe-integ-postgres psql -U postgres -d integration -c "DROP TABLE IF EXISTS public.${table_name} CASCADE; DROP TABLE IF EXISTS ${schema}.${table_name} CASCADE" >/dev/null 2>&1 || true
    elif [[ "$target_db" == "mssql" ]]; then
        container_exec benchmark-test sqlcmd -C -S dtpipe-integ-mssql,1433 -U sa -P Password123! -Q "IF OBJECT_ID('${table_name}', 'U') IS NOT NULL DROP TABLE ${table_name}" >/dev/null 2>&1 || true
    fi
}

# Helper to locate and rename files created by Meltano targets
move_output_file() {
    local type="$1"
    local stream_name="$2"
    local final_path="$3"

    # Clean old file inside the container
    container_exec benchmark-test rm -f "$final_path"

    if [[ "$type" == "parquet" ]]; then
        # Match *.parquet and *.gz.parquet (target-parquet may compress output)
        local find_cmd="ls -t /bench/artifacts/meltano_bench_out/${stream_name}/*parquet 2>/dev/null | head -n 1"
        local latest_file
        latest_file=$(container_exec benchmark-test bash -c "$find_cmd" | tr -d '\r\n')
        if [[ -n "$latest_file" ]]; then
            container_exec benchmark-test mv "$latest_file" "$final_path"
            # Cleanup target dir inside the container
            container_exec benchmark-test rm -rf "/bench/artifacts/meltano_bench_out/${stream_name}"
        fi
    elif [[ "$type" == "csv" ]]; then
        local csv_file="/bench/artifacts/meltano_bench_out_csv/${stream_name}.csv"
        # Move it inside the container
        container_exec benchmark-test bash -c "if [ -f '$csv_file' ]; then mv '$csv_file' '$final_path'; fi"
    fi
}

run_pipeline() {
    local bench_id="$1"
    local description="$2"
    local is_supported="$3"
    local extractor="${4:-}"
    local loader="${5:-}"
    local setup_cmds="${6:-}"
    local cleanup_cmds="${7:-}"
    local target_db="${8:-}"
    local target_table="${9:-}"

    # Check scope
    if [[ "$BENCHMARK_SCOPE" != "all" ]] && [[ "$BENCHMARK_SCOPE" != "$bench_id" ]]; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    # Check support
    if [[ "$is_supported" == "false" ]]; then
        echo -e "${YELLOW}$bench_id: $description [NOT IMPLEMENTED]${NC}"
        stats_record_unavailable "$RESULTS_CSV" "$bench_id" "$description" "Not implemented"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id (meltano): $description ---${NC}"

    local meltano_project_dir="/bench/artifacts/meltano/meltano_project"

    # Environment variables injected as inline shell exports (docker compose exec does not support -e)
    local env_exports="export PATH=\"/opt/venv/meltano/bin:\${PATH}\"; "
    
    local tap_pg_url="postgresql+psycopg2://${DB_POSTGRES_USER}:${DB_POSTGRES_PASSWORD}@${DB_POSTGRES_HOST}:${DB_POSTGRES_PORT}/${DB_POSTGRES_DB}"
    local tgt_pg_url="postgresql+psycopg2://${DB_POSTGRES_USER}:${DB_POSTGRES_PASSWORD}@${DB_POSTGRES_HOST}:${DB_POSTGRES_PORT}/${DB_POSTGRES_DB}"
    local target_schema="public"
    
    if [[ "$bench_id" == "B13" ]]; then
        tap_pg_url="postgresql+psycopg2://${DB_POSTGRES_READER_USER:-bench_reader}:${DB_POSTGRES_READER_PASSWORD:-password}@${DB_POSTGRES_HOST}:${DB_POSTGRES_PORT}/${DB_POSTGRES_DB}"
        tgt_pg_url="postgresql+psycopg2://${DB_POSTGRES_WRITER_USER:-bench_writer}:${DB_POSTGRES_WRITER_PASSWORD:-password}@${DB_POSTGRES_HOST}:${DB_POSTGRES_PORT}/${DB_POSTGRES_DB}"
        target_schema="${DB_POSTGRES_WRITER_SCHEMA:-bench_tgt}"
        env_exports="${env_exports}export TAP_POSTGRES_STREAM_MAPS='{\"public-benchmark_source_${SUFFIX}\": {\"__alias__\": \"meltano_bench_pg2pg\"}}'; "
    fi
    
    env_exports="${env_exports}export TAP_POSTGRES_SQLALCHEMY_URL='${tap_pg_url}'; "
    env_exports="${env_exports}export TARGET_POSTGRES_SQLALCHEMY_URL='${tgt_pg_url}'; "
    env_exports="${env_exports}export TARGET_POSTGRES_DEFAULT_TARGET_SCHEMA='${target_schema}'; "
    
    env_exports="${env_exports}export TARGET_POSTGRES_LOAD_METHOD=overwrite; "
    env_exports="${env_exports}export TAP_MSSQL_HOST=${DB_MSSQL_HOST}; "
    env_exports="${env_exports}export TAP_MSSQL_PORT=${DB_MSSQL_PORT}; "
    env_exports="${env_exports}export TAP_MSSQL_DATABASE=${DB_MSSQL_DB}; "
    env_exports="${env_exports}export TAP_MSSQL_USER=${DB_MSSQL_USER}; "
    env_exports="${env_exports}export TAP_MSSQL_PASSWORD='${DB_MSSQL_PASSWORD}'; "
    env_exports="${env_exports}export TARGET_MSSQL_SQLALCHEMY_URL='mssql+pymssql://${DB_MSSQL_USER}:${DB_MSSQL_PASSWORD}@${DB_MSSQL_HOST}:${DB_MSSQL_PORT}/${DB_MSSQL_DB}'; "
    env_exports="${env_exports}export TARGET_MSSQL_DEFAULT_TARGET_SCHEMA=dbo; "
    env_exports="${env_exports}export TARGET_MSSQL_LOAD_METHOD=overwrite; "

    # Dynamic selection & configuration based on extractor/loader
    if [[ "$extractor" == "tap-postgres" ]]; then
        env_exports="${env_exports}export TAP_POSTGRES__SELECT='[\"public-benchmark_source_${SUFFIX}.*\"]'; "
    elif [[ "$extractor" == "tap-mssql" ]]; then
        env_exports="${env_exports}export TAP_MSSQL__SELECT='[\"dbo-benchmark_source_${SUFFIX}.*\"]'; "
    elif [[ "$extractor" == "tap-csv" ]]; then
        if [[ "$bench_id" == "B03" ]]; then
            env_exports="${env_exports}export TAP_CSV_FILES='[{\"entity\": \"meltano_bench_mssql\", \"path\": \"/bench/artifacts/source_data_${SUFFIX}.csv\", \"keys\": [\"id\"]}]'; "
            env_exports="${env_exports}export TAP_CSV__SELECT='[\"meltano_bench_mssql.*\"]'; "
        elif [[ "$bench_id" == "B07" ]]; then
            env_exports="${env_exports}export TAP_CSV_FILES='[{\"entity\": \"meltano_bench_pg_csv\", \"path\": \"/bench/artifacts/source_data_${SUFFIX}.csv\", \"keys\": [\"id\"]}]'; "
            env_exports="${env_exports}export TAP_CSV__SELECT='[\"meltano_bench_pg_csv.*\"]'; "
        fi
    fi

    if [[ "$loader" == "target-parquet" ]]; then
        env_exports="${env_exports}export TARGET_PARQUET_DESTINATION_PATH='/bench/artifacts/meltano_bench_out'; "
    elif [[ "$loader" == "target-csv" ]]; then
        env_exports="${env_exports}export TARGET_CSV_DESTINATION_PATH='/bench/artifacts/meltano_bench_out_csv'; "
    fi

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        # 1. Drop table if destination database
        if [[ -n "$target_db" && -n "$target_table" ]]; then
            drop_target_table "$target_db" "$target_table"
        fi

        # 2. Run setup commands in Meltano project directory
        if [[ -n "$setup_cmds" ]]; then
            container_exec benchmark-test bash -c "${env_exports}cd $meltano_project_dir && $setup_cmds" >/dev/null 2>&1 || true
        fi

        # 3. Execute meltano run inside container and capture timing
        local cmd="meltano run $extractor $loader"
        local runner_script
        runner_script=$(mktemp)
        cat > "$runner_script" << 'RUNNER_HEADER'
#!/bin/bash
set +e
RUNNER_HEADER
        echo "${env_exports}" >> "$runner_script"
        echo "cd ${meltano_project_dir}" >> "$runner_script"
        cat >> "$runner_script" << 'RUNNER_MIDDLE'
START=$(date +%s%N)
RUNNER_MIDDLE
        echo "$cmd > /tmp/out.txt 2>&1; EC=\$?" >> "$runner_script"
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

            # 4. Run cleanup/move commands
            if [[ -n "$cleanup_cmds" ]]; then
                eval "$cleanup_cmds"
            fi
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
        container_exec benchmark-test /opt/venv/pandas/bin/python3 /bench/scripts/verify_data.py "meltano" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# =============================================================================
# Run Benchmarks
# =============================================================================

# B01: Parquet → PostgreSQL (Not supported: tap-parquet fails on fixed_size_binary[16] UUID)
run_pipeline "B01" "Parquet → PostgreSQL" "false"

# B02: PostgreSQL → Parquet
run_pipeline "B02" "PostgreSQL → Parquet" "true" \
    "tap-postgres" "target-parquet" \
    "rm -f .meltano/run/tap-postgres/tap.properties.json .meltano/run/tap-postgres/tap.properties.cache_key" \
    "move_output_file parquet public-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_pg_to_pq.parquet"

# B03: CSV → SQL Server
run_pipeline "B03" "CSV → SQL Server" "true" \
    "tap-csv" "target-mssql" \
    "" \
    "" "mssql" "meltano_bench_mssql"

# B04: SQL Server → CSV
run_pipeline "B04" "SQL Server → CSV" "true" \
    "tap-mssql" "target-csv" \
    "rm -f .meltano/run/tap-mssql/tap.properties.json .meltano/run/tap-mssql/tap.properties.cache_key" \
    "move_output_file csv dbo-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_mssql_to_csv.csv"

# B05: Parquet → Oracle (Not supported)
run_pipeline "B05" "Parquet → Oracle" "false"

# B06: Oracle → Parquet (Not supported)
run_pipeline "B06" "Oracle → Parquet" "false"

# B07: CSV → PostgreSQL
run_pipeline "B07" "CSV → PostgreSQL" "true" \
    "tap-csv" "target-postgres" \
    "" \
    "" "postgres" "meltano_bench_pg_csv"

# B08: PostgreSQL → CSV
run_pipeline "B08" "PostgreSQL → CSV" "true" \
    "tap-postgres" "target-csv" \
    "rm -f .meltano/run/tap-postgres/tap.properties.json .meltano/run/tap-postgres/tap.properties.cache_key" \
    "move_output_file csv public-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_pg_to_csv.csv"

# B09: Parquet → SQL Server (Not supported)
run_pipeline "B09" "Parquet → SQL Server" "false"

# B10: SQL Server → Parquet
run_pipeline "B10" "SQL Server → Parquet" "true" \
    "tap-mssql" "target-parquet" \
    "rm -f .meltano/run/tap-mssql/tap.properties.json .meltano/run/tap-mssql/tap.properties.cache_key" \
    "move_output_file parquet dbo-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_mssql_to_pq.parquet"

# B11: CSV → Oracle (Not supported)
run_pipeline "B11" "CSV → Oracle" "false"

# B12: Oracle → CSV (Not supported)
run_pipeline "B12" "Oracle → CSV" "false"

# B13: PostgreSQL → PostgreSQL
run_pipeline "B13" "PostgreSQL → PostgreSQL" "true" \
    "tap-postgres" "target-postgres" \
    "rm -f .meltano/run/tap-postgres/tap.properties.json .meltano/run/tap-postgres/tap.properties.cache_key" \
    "" "postgres" "meltano_bench_pg2pg"

# B14: SQL Server → SQL Server (Not implemented)
run_pipeline "B14" "SQL Server → SQL Server" "false"

# B15: Oracle → Oracle (Not implemented)
run_pipeline "B15" "Oracle → Oracle" "false"


# =============================================================================
# Generate JSON report for meltano
# =============================================================================
echo ""
echo -e "${YELLOW}Generating JSON report...${NC}"

{
    echo "{"
    echo '    "tool": "meltano",'
    echo "    \"benchmark_rows\": $BENCHMARK_ROWS,"
    echo "    \"repetitions\": $BENCHMARK_REPETITIONS,"
    echo "    \"date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo '    "benchmarks": {'

    stats_json_benchmarks "$RESULTS_CSV" "      "
    echo '    }'
    echo "}"
} > "$ARTIFACTS_DIR/meltano/meltano_report.json"

echo -e "${GREEN}meltano report saved: $ARTIFACTS_DIR/meltano/meltano_report.json${NC}"