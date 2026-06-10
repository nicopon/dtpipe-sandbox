#!/usr/bin/env bash
# =============================================================================
# 03-pandas.sh - Pandas benchmark (executions INSIDE benchmark-pandas container)
# Runs the same pipelines as dtpipe and Sling for comparison using Pandas & SQLAlchemy
# 
# IMPORTANT: Everything runs inside the container, nothing on the host
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
BENCHMARK_SCOPE="all"        # all, B01-B12

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

# Docker compose helper (runs from config directory)
docker_compose() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml "$@"
}

# docker exec helper for benchmark-pandas container
exec_pandas_container() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "dtpipe-benchmark" -f docker-compose-benchmark.yml exec benchmark-pandas bash -c "$1"
}

# Ensure artifacts directory exists
mkdir -p "$ARTIFACTS_DIR/pandas"
RESULTS_CSV="$ARTIFACTS_DIR/pandas/.tmp_results.csv"
> "$RESULTS_CSV"        # Clear previous results

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  pandas benchmark (benchmark-pandas container)${NC}"
echo -e "${GREEN}================================================${NC}"
echo "Settings :"
echo -e "   Rows: $BENCHMARK_ROWS"
echo -e "   Repetitions: $BENCHMARK_REPETITIONS"
echo -e "   Scope: $BENCHMARK_SCOPE"
echo ""

# =============================================================================
# Use Python directly for actual benchmarking (faster iteration, more control)
# This is still inside the container, just using Pandas & SQLAlchemy
# =============================================================================

run_python_benchmark() {
    local bench_id="$1"
    local description="$2"
    shift 2

    # Check if this benchmark should run based on scope
    if [[ "$BENCHMARK_SCOPE" != "all" ]] && [[ "$BENCHMARK_SCOPE" != "$bench_id" ]]; then
        echo -e "${YELLOW}$bench_id: $description [SKIPPED - scope filter]${NC}"
        return
    fi

    echo ""
    echo -e "${YELLOW}--- $bench_id (Python): $description ---${NC}"

    local run_times=()
    local run_mem_peaks=()
    for i in $(seq 1 "$BENCHMARK_REPETITIONS"); do
        echo -n "  Run $i/$BENCHMARK_REPETITIONS..."

        mem_watcher_start benchmark-pandas
        # Execute Python benchmark script inside the container
        if exec_pandas_container "/usr/bin/time -f '%e' -o /tmp/pandas_py_timing_${bench_id}_$i.txt python3 /bench/scripts/benchmarks/_pandas_bench.py $bench_id $BENCHMARK_ROWS > /tmp/pandas_py_output_${bench_id}_$i.txt 2>&1"; then
            local peak_mem
            peak_mem=$(mem_watcher_stop)
            # Extract timing from the container's output file
            local wall_time
            wall_time=$(exec_pandas_container "cat /tmp/pandas_py_timing_${bench_id}_$i.txt" || echo "")

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

            exec_pandas_container "rm -f /tmp/pandas_py_timing_${bench_id}_$i.txt /tmp/pandas_py_output_${bench_id}_$i.txt" >/dev/null 2>&1 || true
        else
            mem_watcher_stop > /dev/null
            echo -e " ${RED}FAILED${NC}"
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

    # Store result (append to same CSV, with Python prefix)
    echo "$bench_id|$description(python)|$avg|$avg_mem" >> "$RESULTS_CSV"

    # Verify target data matches source
    if [[ "$avg" -ne 0 ]]; then
        python3 "$SCRIPT_DIR/scripts/verify_data.py" "pandas" "$bench_id" "$BENCHMARK_ROWS" || true
    fi
}

# Use Python-based benchmarks for pandas
run_python_benchmark "B01" "Parquet → PostgreSQL"
run_python_benchmark "B02" "PostgreSQL → Parquet"  
run_python_benchmark "B03" "CSV → SQL Server"
run_python_benchmark "B04" "SQL Server → CSV"
run_python_benchmark "B05" "Parquet → Oracle"
run_python_benchmark "B06" "Oracle → Parquet"
run_python_benchmark "B07" "CSV → PostgreSQL"
run_python_benchmark "B08" "PostgreSQL → CSV"
run_python_benchmark "B09" "Parquet → SQL Server"
run_python_benchmark "B10" "SQL Server → Parquet"
run_python_benchmark "B11" "CSV → Oracle"
run_python_benchmark "B12" "Oracle → CSV"


# =============================================================================
# Generate JSON report for pandas
# =============================================================================
echo ""
echo -e "${YELLOW}Generating JSON report...${NC}"

{
    echo "{"
    echo '     "tool": "pandas",'
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
        # Clean up description (remove "(python)" suffix for display)
        clean_desc=$(echo "$bdesc" | sed 's/(python)//')
        printf '       "%s": { "description": "%s", "avg_duration_ms": %s, "avg_peak_mem_mb": %s }' "$bid" "$clean_desc" "$bavg" "${bavg_mem:-0}"
    done < "$RESULTS_CSV"

    echo ""
    echo '     }'
    echo "}"
} > "$ARTIFACTS_DIR/pandas/pandas_report.json"

echo -e "${GREEN}pandas report saved: $ARTIFACTS_DIR/pandas/pandas_report.json${NC}"
