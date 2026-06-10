#!/usr/bin/env bash
# =============================================================================
# 03-meltano.sh - Meltano benchmark (executions INSIDE benchmark-meltano container)
# Runs actual Meltano pipelines using Singer taps and targets
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
    if (( BENCHMARK_ROWS % 1000000 == 0 )); then
        SUFFIX="$(( BENCHMARK_ROWS / 1000000 ))m"
    else
        SUFFIX="${BENCHMARK_ROWS}"
    fi
fi

# Container compose helper
container_compose_helper() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml "$@"
}

# Container exec helper for benchmark-meltano container
exec_meltano_container() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec benchmark-meltano bash -c "$1"
}

# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/meltano"
RESULTS_CSV="$ARTIFACTS_DIR/meltano/.tmp_results.csv"
> "$RESULTS_CSV"        # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  meltano benchmark (benchmark-meltano container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# Helper to run database drops prior to Meltano runs to ensure a clean schema
drop_target_table() {
    local target_db="$1"
    local table_name="$2"
    
    if [[ "$target_db" == "postgres" ]]; then
        COMPOSE_PROJECT_DIR="$REPO_ROOT/infra"
         container_compose -f "docker-compose.yml" exec dtpipe-integ-postgres psql -U postgres -d integration -c "DROP TABLE IF EXISTS public.${table_name} CASCADE" >/dev/null 2>&1 || true
    elif [[ "$target_db" == "mssql" ]]; then
        COMPOSE_PROJECT_DIR="$CONFIG_DIR"
         container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec benchmark-native sqlcmd -C -S dtpipe-integ-mssql,1433 -U sa -P Password123! -Q "IF OBJECT_ID('${table_name}', 'U') IS NOT NULL DROP TABLE ${table_name}" >/dev/null 2>&1 || true
    fi
}

# Helper to locate and rename files created by Meltano targets
move_output_file() {
    local type="$1"
    local stream_name="$2"
    # Translate container path (/bench/artifacts) to host path ($ARTIFACTS_DIR)
    # The function runs on the host but callers may pass the container-side path
    local final_path="${3/\/bench\/artifacts/$ARTIFACTS_DIR}"

    # Clean old file
    rm -f "$final_path"

    if [[ "$type" == "parquet" ]]; then
        local search_pattern="$ARTIFACTS_DIR/meltano_bench_out/${stream_name}/*.parquet"
        # Find latest parquet file matching pattern
        local latest_file
        latest_file=$(ls -t $search_pattern 2>/dev/null | head -n 1 || echo "")
        if [[ -n "$latest_file" ]]; then
            mv "$latest_file" "$final_path"
            # Cleanup target dir
            rm -rf "$ARTIFACTS_DIR/meltano_bench_out/${stream_name}"
        fi
    elif [[ "$type" == "csv" ]]; then
        local csv_file="$ARTIFACTS_DIR/meltano_bench_out_csv/${stream_name}.csv"
        if [[ -f "$csv_file" ]]; then
            mv "$csv_file" "$final_path"
        fi
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
        echo -e "${YELLOW}$bench_id: $description [NOT SUPPORTED by real Meltano]${NC}"
        echo "$bench_id|$description|Not supported" >> "$RESULTS_CSV"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id: $description ---${NC}"

    local meltano_project_dir="/bench/artifacts/meltano/meltano_project"

    # Environment variables injected as inline shell exports (docker compose exec does not support -e)
    local env_exports=""
    env_exports="${env_exports}export TAP_POSTGRES_SQLALCHEMY_URL='postgresql+psycopg2://${DB_POSTGRES_USER}:${DB_POSTGRES_PASSWORD}@${DB_POSTGRES_HOST}:${DB_POSTGRES_PORT}/${DB_POSTGRES_DB}'; "
    env_exports="${env_exports}export TARGET_POSTGRES_SQLALCHEMY_URL='postgresql+psycopg2://${DB_POSTGRES_USER}:${DB_POSTGRES_PASSWORD}@${DB_POSTGRES_HOST}:${DB_POSTGRES_PORT}/${DB_POSTGRES_DB}'; "
    env_exports="${env_exports}export TARGET_POSTGRES_DEFAULT_TARGET_SCHEMA=public; "
    env_exports="${env_exports}export TARGET_POSTGRES_LOAD_METHOD=overwrite; "
    env_exports="${env_exports}export TAP_MSSQL_HOST=${DB_MSSQL_HOST}; "
    env_exports="${env_exports}export TAP_MSSQL_PORT=${DB_MSSQL_PORT}; "
    env_exports="${env_exports}export TAP_MSSQL_DATABASE=${DB_MSSQL_DB}; "
    env_exports="${env_exports}export TAP_MSSQL_USER=${DB_MSSQL_USER}; "
    env_exports="${env_exports}export TAP_MSSQL_PASSWORD='${DB_MSSQL_PASSWORD}'; "
    env_exports="${env_exports}export TARGET_MSSQL_SQLALCHEMY_URL='mssql+pymssql://${DB_MSSQL_USER}:${DB_MSSQL_PASSWORD}@${DB_MSSQL_HOST}:${DB_MSSQL_PORT}/${DB_MSSQL_DB}'; "
    env_exports="${env_exports}export TARGET_MSSQL_DEFAULT_TARGET_SCHEMA=dbo; "
    env_exports="${env_exports}export TARGET_MSSQL_LOAD_METHOD=overwrite; "

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
            exec_meltano_container "${env_exports}cd $meltano_project_dir && $setup_cmds" >/dev/null 2>&1 || true
        fi

        # 3. Execute meltano run inside container and capture timing
        local cmd="meltano run $extractor $loader"
        mem_watcher_start benchmark-meltano
        if exec_meltano_container "${env_exports}cd $meltano_project_dir && /usr/bin/time -f '%e' -o /tmp/mel_timing_${bench_id}_$i.txt bash -c '$cmd' > /tmp/mel_output_${bench_id}_$i.txt 2>&1"; then
            local peak_mem
            peak_mem=$(mem_watcher_stop)
            local wall_time
            wall_time=$(exec_meltano_container "cat /tmp/mel_timing_${bench_id}_$i.txt" || echo "")

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

            # 4. Run cleanup/move commands
            if [[ -n "$cleanup_cmds" ]]; then
                eval "$cleanup_cmds"
            fi

            exec_meltano_container "rm -f /tmp/mel_timing_${bench_id}_$i.txt /tmp/mel_output_${bench_id}_$i.txt" >/dev/null 2>&1 || true
        else
            mem_watcher_stop > /dev/null
            echo -e " ${RED}FAILED${NC}"
            exec_meltano_container "cat /tmp/mel_output_${bench_id}_$i.txt" || true
            run_times+=("ERROR:0")
            exec_meltano_container "rm -f /tmp/mel_timing_${bench_id}_$i.txt /tmp/mel_output_${bench_id}_$i.txt" >/dev/null 2>&1 || true
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
        python3 "$SCRIPT_DIR/scripts/verify_data.py" "meltano" "$bench_id" "$BENCHMARK_ROWS" || true
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
    "meltano select tap-postgres --clear && meltano select tap-postgres 'public-benchmark_source_${SUFFIX}' '*' && meltano config set target-parquet destination_path '/bench/artifacts/meltano_bench_out'" \
    "move_output_file parquet public-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_pg_to_pq.parquet"

# B03: CSV → SQL Server
run_pipeline "B03" "CSV → SQL Server" "true" \
    "tap-csv" "target-mssql" \
    "meltano config set tap-csv files '[{\"entity\": \"meltano_bench_mssql\", \"path\": \"/bench/artifacts/source_data_${SUFFIX}.csv\", \"keys\": [\"id\"]}]'" \
    "" "mssql" "meltano_bench_mssql"

# B04: SQL Server → CSV
run_pipeline "B04" "SQL Server → CSV" "true" \
    "tap-mssql" "target-csv" \
    "meltano select tap-mssql --clear && meltano select tap-mssql 'dbo-benchmark_source_${SUFFIX}' '*' && meltano config set target-csv destination_path '/bench/artifacts/meltano_bench_out_csv'" \
    "move_output_file csv dbo-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_mssql_to_csv.csv"

# B05: Parquet → Oracle (Not supported)
run_pipeline "B05" "Parquet → Oracle" "false"

# B06: Oracle → Parquet (Not supported)
run_pipeline "B06" "Oracle → Parquet" "false"

# B07: CSV → PostgreSQL
run_pipeline "B07" "CSV → PostgreSQL" "true" \
    "tap-csv" "target-postgres" \
    "meltano config set tap-csv files '[{\"entity\": \"meltano_bench_pg_csv\", \"path\": \"/bench/artifacts/source_data_${SUFFIX}.csv\", \"keys\": [\"id\"]}]'" \
    "" "postgres" "meltano_bench_pg_csv"

# B08: PostgreSQL → CSV
run_pipeline "B08" "PostgreSQL → CSV" "true" \
    "tap-postgres" "target-csv" \
    "meltano select tap-postgres --clear && meltano select tap-postgres 'public-benchmark_source_${SUFFIX}' '*' && meltano config set target-csv destination_path '/bench/artifacts/meltano_bench_out_csv'" \
    "move_output_file csv public-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_pg_to_csv.csv"

# B09: Parquet → SQL Server (Not supported)
run_pipeline "B09" "Parquet → SQL Server" "false"

# B10: SQL Server → Parquet
run_pipeline "B10" "SQL Server → Parquet" "true" \
    "tap-mssql" "target-parquet" \
    "meltano select tap-mssql --clear && meltano select tap-mssql 'dbo-benchmark_source_${SUFFIX}' '*' && meltano config set target-parquet destination_path '/bench/artifacts/meltano_bench_out'" \
    "move_output_file parquet dbo-benchmark_source_${SUFFIX} /bench/artifacts/meltano_bench_mssql_to_pq.parquet"

# B11: CSV → Oracle (Not supported)
run_pipeline "B11" "CSV → Oracle" "false"

# B12: Oracle → CSV (Not supported)
run_pipeline "B12" "Oracle → CSV" "false"


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
} > "$ARTIFACTS_DIR/meltano/meltano_report.json"

echo -e "${GREEN}meltano report saved: $ARTIFACTS_DIR/meltano/meltano_report.json${NC}"