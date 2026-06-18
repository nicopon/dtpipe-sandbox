#!/usr/bin/env bash
# =============================================================================
# 04-report.sh - Generation of the final comparative report
# Compiles results from all tools into a table
#
# IMPORTANT: Everything runs inside the benchmark-test container (jq, etc.)
#            No host dependencies beyond bash and a container runtime.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
ARTIFACTS_DIR="$SCRIPT_DIR/../artifacts"

source "$LIB_DIR/container-runtime.sh"
init_container_runtime || exit 1

# jq wrapper: runs jq inside benchmark-test so the host needs no jq install.
# -i forwards stdin (needed when called from a pipe: echo ... | jq ...).
# Host artifact paths are translated to the container mount point.
_NATIVE_ARTIFACTS_DIR="/bench/artifacts"
jq() {
    local args=()
    for arg in "$@"; do
        args+=("${arg/#$ARTIFACTS_DIR/$_NATIVE_ARTIFACTS_DIR}")
    done
    "$CONTAINER_CMD" exec -i benchmark-test jq "${args[@]}"
}

# Default values
BENCHMARK_ROWS=250000
BENCHMARK_REPETITIONS=3

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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
            --help|-h)
             echo "Usage: $0 [--rows NUM] [--repetitions NUM]"
             exit 0
                ;;
            *)
             echo -e "${RED}Unknown option: $1${NC}"
             exit 1
                ;;
    esac
done

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Generating final comparative report${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""

# Ensure artifacts directories exist for reports
mkdir -p "$ARTIFACTS_DIR/reports"

REPORT_FILE="$ARTIFACTS_DIR/reports/benchmark_report.md"
REPORT_JSON="$ARTIFACTS_DIR/reports/benchmark_report.json"

# =============================================================================
# Helper: Read benchmark results from a tool's JSON report
# Args: tool_name
# Returns: populates variables like <tool>_<bench_id>
# =============================================================================

# =============================================================================
# Helper: Format a number with thousands separators (e.g. 250000 → 250,000)
# =============================================================================
format_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

# =============================================================================
# Helper: Format duration table row with ranking and rows/sec
# Args: [--duration ROWS] benchmark_desc val1 tool1 val2 tool2 ... valN toolN
#   --duration ROWS : enable rows/sec column annotation; ROWS = source row count
# Excludes "Not supported", "Not implemented", "N/A" from ranking.
# Outputs a markdown table row with rank suffixes and bolded winner.
# =============================================================================
format_table_row() {
    local rows_count=0
    if [[ "${1:-}" == "--duration" ]]; then
        rows_count="$2"
        shift 2
    fi

    local desc="$1"
    shift

    local tmpfile
    tmpfile=$(mktemp)

    while [[ $# -gt 0 ]]; do
        local val="$1"
        local tool="$2"
        echo "${tool}|${val}" >> "$tmpfile"
        shift 2
    done

    awk -v desc="$desc" -v rows="$rows_count" '
    BEGIN { n = 0 }
    {
        n++
        split($0, parts, "|")
        tools[n] = parts[1]
        vals[n]  = parts[2]
    }
    END {
        # Collect numeric values and sort them (bubble sort)
        num_count = 0
        for (i = 1; i <= n; i++) {
            v = vals[i]
            if (v != "Not supported" && v != "Not implemented" && v != "N/A" && v != "" && v+0 > 0) {
                num_vals[++num_count] = v + 0
            }
        }
        # Sort ascending
        for (i = 1; i <= num_count; i++)
            for (j = i+1; j <= num_count; j++)
                if (num_vals[j] < num_vals[i]) { tmp = num_vals[i]; num_vals[i] = num_vals[j]; num_vals[j] = tmp }
        # Build rank map (lowest ms = rank 1)
        for (i = 1; i <= num_count; i++)
            rank_of[num_vals[i]] = i

        printf "| %s", desc
        for (i = 1; i <= n; i++) {
            v = vals[i]
            is_numeric = (v != "Not supported" && v != "Not implemented" && v != "N/A" && v != "" && v+0 > 0)
            if (!is_numeric) {
                printf " | %s", v
                continue
            }
            vnum = v + 0
            r = rank_of[vnum]

            # Rows per second annotation
            rps_str = ""
            if (rows > 0) {
                rps = int(rows / (vnum / 1000))
                # Format with K/M suffix
                if (rps >= 1000000)      rps_str = sprintf(" %.1fM rows/s", rps/1000000)
                else if (rps >= 1000)    rps_str = sprintf(" %.0fK rows/s", rps/1000)
                else                     rps_str = sprintf(" %d rows/s", rps)
            }

            cell = sprintf("%d ms%s (#%d)", vnum, rps_str, r)
            if (r == 1)
                printf " | **%s**", cell
            else
                printf " | %s", cell
        }
        printf " |\n"
    }
    ' "$tmpfile" 2>/dev/null

    rm -f "$tmpfile"
}

# =============================================================================
# Helper: Format memory table row with ranking (lower = better)
# Same as above but no rows/sec annotation
# =============================================================================
format_mem_row() {
    local desc="$1"
    shift

    local tmpfile
    tmpfile=$(mktemp)

    while [[ $# -gt 0 ]]; do
        local val="$1"
        local tool="$2"
        echo "${tool}|${val}" >> "$tmpfile"
        shift 2
    done

    awk -v desc="$desc" '
    BEGIN { n = 0 }
    {
        n++
        split($0, parts, "|")
        tools[n] = parts[1]
        vals[n]  = parts[2]
    }
    END {
        num_count = 0
        for (i = 1; i <= n; i++) {
            v = vals[i]
            if (v != "Not supported" && v != "Not implemented" && v != "N/A" && v != "" && v+0 >= 0) {
                num_vals[++num_count] = v + 0
            }
        }
        for (i = 1; i <= num_count; i++)
            for (j = i+1; j <= num_count; j++)
                if (num_vals[j] < num_vals[i]) { tmp = num_vals[i]; num_vals[i] = num_vals[j]; num_vals[j] = tmp }
        for (i = 1; i <= num_count; i++)
            rank_of[num_vals[i]] = i

        printf "| %s", desc
        for (i = 1; i <= n; i++) {
            v = vals[i]
            is_numeric = (v != "Not supported" && v != "Not implemented" && v != "N/A" && v != "")
            if (!is_numeric) { printf " | %s", v; continue }
            vnum = v + 0
            r = rank_of[vnum]
            cell = sprintf("%d MiB (#%d)", vnum, r)
            if (r == 1)
                printf " | **%s**", cell
            else
                printf " | %s", cell
        }
        printf " |\n"
    }
    ' "$tmpfile" 2>/dev/null

    rm -f "$tmpfile"
}

read_tool_results() {
    local tool="$1"
    local json_file="$ARTIFACTS_DIR/$tool/${tool}_report.json"

    if [[ ! -f "$json_file" ]]; then
        echo -e "${YELLOW}Warning: $json_file not found. $tool skipped from report.${NC}"
        return
    fi

    # Parse JSON using jq and populate variables
    local benchmarks
    benchmarks=$(jq -r '.benchmarks | to_entries[] | "\(.key)|\(.value.avg_duration_ms)|\(.value.avg_peak_mem_mb // "N/A")"' "$json_file" 2>/dev/null) || return

    while IFS='|' read -r key value mem; do
        [[ -z "$key" ]] && continue
        eval "${tool}_${key}=\"\$value\""
        eval "${tool}_mem_${key}=\"\$mem\""
    done <<< "$benchmarks"
}

# Read results from all tools
read_tool_results "dtpipe"
read_tool_results "pandas"
read_tool_results "meltano"
read_tool_results "sling"
read_tool_results "ingestr"
read_tool_results "native"

# Define the benchmark IDs and descriptions
BENCHMARK_IDS=("B01" "B02" "B03" "B04" "B05" "B06" "B07" "B08" "B09" "B10" "B11" "B12" "B13" "B14" "B15")
BENCHMARK_DESCRIPTIONS=(
       "Parquet → PostgreSQL"
       "PostgreSQL → Parquet"
       "CSV → SQL Server"
       "SQL Server → CSV"
       "Parquet → Oracle"
       "Oracle → Parquet"
       "CSV → PostgreSQL"
       "PostgreSQL → CSV"
       "Parquet → SQL Server"
       "SQL Server → Parquet"
       "CSV → Oracle"
       "Oracle → CSV"
       "PostgreSQL → PostgreSQL"
       "SQL Server → SQL Server"
       "Oracle → Oracle"
)


# =============================================================================
# Collect host machine information
# =============================================================================
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
HOST_CPUS="$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo '?')"
HOST_RAM="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f GiB", $1/1073741824}' \
    || grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f GiB", $2/1048576}' \
    || echo '?')"
HOST_CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null \
    || grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs \
    || echo '?')"

# =============================================================================
# Generate Markdown report
# =============================================================================
{
    echo "# Competitive Benchmark Report: dtpipe vs Meltano vs Sling vs ingestr vs Native"
    echo ""
    echo "---"
    echo ""
    echo "## Configuration"
    echo ""
    echo "| Parameter | Value |"
    echo "|:---|:---|"
    echo "| Source rows | $(format_number "$BENCHMARK_ROWS") |"
    echo "| Repetitions | $BENCHMARK_REPETITIONS |"
    echo "| Date | $(date -u +"%Y-%m-%d %H:%M UTC") |"
    echo "| Host OS | ${HOST_OS} ${HOST_ARCH} |"
    echo "| CPU | ${HOST_CPU_MODEL} (${HOST_CPUS} cores) |"
    echo "| Memory | ${HOST_RAM} |"
    echo ""
    echo "---"
    echo ""
    echo "## Comparative Table — Duration (avg ms)"
    echo ""
    echo "| Benchmark | dtpipe | pandas - sqlalchemy | meltano | sling | ingestr | native |"
    echo "|:---|:---:|:---:|:---:|:---:|:---:|:---:|"

          # Calculate and display results for each benchmark (best value bolded)
      for idx in "${!BENCHMARK_IDS[@]}"; do
          bid="${BENCHMARK_IDS[$idx]}"
          bdesc="${BENCHMARK_DESCRIPTIONS[$idx]}"

          eval "dtpipe_ms=\${dtpipe_${bid}:-N/A}"
          eval "pandas_ms=\${pandas_${bid}:-N/A}"
          eval "meltano_ms=\${meltano_${bid}:-N/A}"
          eval "sling_ms=\${sling_${bid}:-N/A}"
          eval "ingestr_ms=\${ingestr_${bid}:-N/A}"
          eval "native_ms=\${native_${bid}:-N/A}"

          format_table_row --duration "$BENCHMARK_ROWS" "$bdesc" \
              "$dtpipe_ms" "dtpipe" \
              "$pandas_ms" "pandas" \
              "$meltano_ms" "meltano" \
              "$sling_ms" "sling" \
              "$ingestr_ms" "ingestr" \
              "$native_ms" "native"
      done

    echo ""
    echo "## Comparative Table — Peak Memory Delta (avg MiB)"
    echo ""
    echo "> Peak cgroup memory increase measured from container baseline during transfer."
    echo "> N/A = not supported or not implemented for this tool."
    echo ""
    echo "| Benchmark | dtpipe | pandas - sqlalchemy | meltano | sling | ingestr | native |"
    echo "|:---|:---:|:---:|:---:|:---:|:---:|:---:|"

      for idx in "${!BENCHMARK_IDS[@]}"; do
          bid="${BENCHMARK_IDS[$idx]}"
          bdesc="${BENCHMARK_DESCRIPTIONS[$idx]}"

          eval "dtpipe_mem=\${dtpipe_mem_${bid}:-N/A}"
          eval "pandas_mem=\${pandas_mem_${bid}:-N/A}"
          eval "meltano_mem=\${meltano_mem_${bid}:-N/A}"
          eval "sling_mem=\${sling_mem_${bid}:-N/A}"
          eval "ingestr_mem=\${ingestr_mem_${bid}:-N/A}"
          eval "native_mem=\${native_mem_${bid}:-N/A}"

          format_mem_row "$bdesc" \
              "$dtpipe_mem" "dtpipe" \
              "$pandas_mem" "pandas" \
              "$meltano_mem" "meltano" \
              "$sling_mem" "sling" \
              "$ingestr_mem" "ingestr" \
              "$native_mem" "native"
      done
      
    echo ""
    echo "---"
    echo ""
    echo "## Detail by tool"
    echo ""
    
# Detail for each tool
for _tool_name in dtpipe pandas meltano sling ingestr native; do
    _display_name="${_tool_name}"
    if [[ "${_tool_name}" == "pandas" ]]; then
        _display_name="pandas - sqlalchemy"
    fi
    echo "### ${_display_name}"
    echo ""
    _report_file="$ARTIFACTS_DIR/${_tool_name}/${_tool_name}_report.json"
    if [[ -f "$_report_file" ]]; then
        jq -r '.benchmarks | to_entries[] | "- **\(.key)** (\(.value.description // "N/A")): \(.value.avg_duration_ms)\(.value.avg_duration_ms | if (. | tostring | ltrimstr("-") | test("^[0-9]+$")) then " ms" else "" end)"' "$_report_file" 2>/dev/null || echo "- Benchmark data not available"
    else
        echo "- Benchmark data not available"
    fi

    echo ""
done
     
     echo ""
     echo "---"
     echo ""
     echo "## Notes"
     echo ""
     echo "- Measured times are averages over $BENCHMARK_REPETITIONS executions."
     echo "- Benchmarks were run in isolated Docker containers."
     echo "- Nothing was installed on the host: all executions happen inside containers."
     echo ""
     echo "---"
     echo ""
     echo "*Report generated on $(date -u +"%Y-%m-%d %H:%M UTC").*"
     
 } > "$REPORT_FILE"

# =============================================================================
# Generate JSON report (machine-readable)
# =============================================================================
_generate_json_report() {
     # Build JSON using jq
    local date_str
    date_str=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local cpu_cores_num=0
     [[ "$HOST_CPUS" =~ ^[0-9]+$ ]] && cpu_cores_num=$HOST_CPUS

     # Start with a base structure
    local base_json
    base_json=$(jq -n \
        --arg title "Competitive Benchmark: dtpipe vs Pandas vs Meltano vs Sling vs Native" \
        --argjson rows "$BENCHMARK_ROWS" \
        --argjson reps "$BENCHMARK_REPETITIONS" \
        --arg date "$date_str" \
        --arg os "$HOST_OS" \
        --arg arch "$HOST_ARCH" \
        --arg cpu "$HOST_CPU_MODEL" \
        --argjson cores "$cpu_cores_num" \
        --arg ram "$HOST_RAM" \
        '{
            title: $title,
            configuration: {
                benchmark_rows: $rows,
                repetitions: $reps,
                date: $date,
                host: {
                    os: $os,
                    arch: $arch,
                    cpu: $cpu,
                    cpu_cores: $cores,
                    ram: $ram
                }
            },
            benchmarks: {}
        }')

    # Benchmark descriptions
    local bench_ids=("B01" "B02" "B03" "B04" "B05" "B06" "B07" "B08" "B09" "B10" "B11" "B12" "B13" "B14" "B15")
    local bench_descs=(
        "Parquet -> PostgreSQL"
        "PostgreSQL -> Parquet"
        "CSV -> SQL Server"
        "SQL Server -> CSV"
        "Parquet -> Oracle"
        "Oracle -> Parquet"
        "CSV -> PostgreSQL"
        "PostgreSQL -> CSV"
        "Parquet -> SQL Server"
        "SQL Server -> Parquet"
        "CSV -> Oracle"
        "Oracle -> CSV"
        "PostgreSQL -> PostgreSQL"
        "SQL Server -> SQL Server"
        "Oracle -> Oracle"
    )

    local tools=("dtpipe" "pandas" "meltano" "sling" "ingestr" "native")

    local result="$base_json"

    for idx in "${!bench_ids[@]}"; do
        local bid="${bench_ids[$idx]}"
        local bdesc="${bench_descs[$idx]}"

        # Add benchmark entry with description
        result=$(echo "$result" | jq --arg bid "$bid" --arg desc "$bdesc" '.benchmarks[$bid] = {description: $desc, tools: {}}')

        for tool in "${tools[@]}"; do
            local json_file="$ARTIFACTS_DIR/${tool}/${tool}_report.json"
            if [[ -f "$json_file" ]]; then
                # Try to extract the benchmark data
                local bench_data
                bench_data=$(jq -r --arg bid "$bid" '.benchmarks[$bid] // empty' "$json_file" 2>/dev/null) || continue
                [[ -z "$bench_data" ]] && continue

                result=$(echo "$result" | jq \
                    --arg bid "$bid" \
                    --arg tool "$tool" \
                    --argjson data "$bench_data" \
                    '.benchmarks[$bid].tools[$tool] = $data')
            fi
        done
    done

     echo "$result"
}

_generate_json_report > "$REPORT_JSON"

echo ""
echo -e "${CYAN}Reports generated:${NC}"
echo -e "    ${BLUE}$REPORT_FILE${NC} (Markdown)"
echo -e "    ${BLUE}$REPORT_JSON${NC} (JSON)"
echo ""

# Display the Markdown report in terminal
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Report preview${NC}"
echo -e "${GREEN}================================================${NC}"
cat "$REPORT_FILE"
echo ""
echo -e "${GREEN}================================================${NC}"

echo ""
echo -e "${GREEN}Report saved in:${NC}"
echo -e "    $REPORT_FILE"
echo -e "    $REPORT_JSON"