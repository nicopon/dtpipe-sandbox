#!/usr/bin/env bash
# =============================================================================
# 04-report.sh - Generation of the final comparative report
# Compiles results from all 3 tools (dtpipe, meltano, sling) into a table
# 
# IMPORTANT: Everything runs locally, only reads JSON files
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"

# Default values
BENCHMARK_ROWS=2000000
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
# Returns: populates BENCH_RESULTS associative array
# =============================================================================
# Store results in variables named like <tool>_<bench_id> (e.g. dtpipe_B01)

read_tool_results() {
    local tool="$1"
     local json_file="$ARTIFACTS_DIR/$tool/${tool}_report.json"
    
    if [[ ! -f "$json_file" ]]; then
         echo -e "${YELLOW}Warning: $json_file not found. $tool skipped from report.${NC}"
         return
    fi
    
        # Parse JSON and populate BENCH_RESULTS
     while IFS='|' read -r key value mem; do
         eval "${tool}_${key}=\"\$value\""
         eval "${tool}_mem_${key}=\"\$mem\""
      done < <(python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    avg = bdata.get('avg_duration_ms', 0)
    mem = 'N/A' if avg in ('Not supported', 'Not implemented') else bdata.get('avg_peak_mem_mb', 0)
    print(f'{bid}|{avg}|{mem}')
" 2>/dev/null || echo "")
}

# Read results from all tools
read_tool_results "dtpipe"
read_tool_results "pandas"
read_tool_results "meltano"
read_tool_results "sling"
read_tool_results "ingestr"
read_tool_results "native"

# Define the benchmark IDs and descriptions
BENCHMARK_IDS=("B01" "B02" "B03" "B04" "B05" "B06" "B07" "B08" "B09" "B10" "B11" "B12")
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
    echo "| Source rows | $(python3 -c "print(f'{int($BENCHMARK_ROWS):,}')") |"
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

         # Calculate and display results for each benchmark
      for idx in "${!BENCHMARK_IDS[@]}"; do
          bid="${BENCHMARK_IDS[$idx]}"
          bdesc="${BENCHMARK_DESCRIPTIONS[$idx]}"

          eval "dtpipe_ms=\${dtpipe_${bid}:-N/A}"
          eval "pandas_ms=\${pandas_${bid}:-N/A}"
          eval "meltano_ms=\${meltano_${bid}:-N/A}"
          eval "sling_ms=\${sling_${bid}:-N/A}"
          eval "ingestr_ms=\${ingestr_${bid}:-N/A}"
          eval "native_ms=\${native_${bid}:-N/A}"

          echo "| $bdesc | $dtpipe_ms | $pandas_ms | $meltano_ms | $sling_ms | $ingestr_ms | $native_ms |"
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

          echo "| $bdesc | $dtpipe_mem | $pandas_mem | $meltano_mem | $sling_mem | $ingestr_mem | $native_mem |"
      done
      
    echo ""
    echo "---"
    echo ""
    echo "## Detail by tool"
    echo ""
    
        # Detail for dtpipe
    echo "### dtpipe"
    echo ""
    if [[ -f "$ARTIFACTS_DIR/dtpipe/dtpipe_report.json" ]]; then
        python3 -c "
import json
with open('$ARTIFACTS_DIR/dtpipe/dtpipe_report.json') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    desc = bdata.get('description', 'N/A')
    avg = bdata.get('avg_duration_ms', 0)
    print(f'- **{bid}** ({desc}): {avg}' + (' ms' if str(avg).lstrip('-').isdigit() else ''))
" 2>/dev/null || echo "- Benchmark data not available"
    else
        echo "- Benchmark data not available"
    fi
    
    echo ""
    
     # Detail for pandas
     echo "### pandas - sqlalchemy"
     echo ""
     if [[ -f "$ARTIFACTS_DIR/pandas/pandas_report.json" ]]; then
          python3 -c "
import json
with open('$ARTIFACTS_DIR/pandas/pandas_report.json') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    desc = bdata.get('description', 'N/A')
    avg = bdata.get('avg_duration_ms', 0)
    print(f'- **{bid}** ({desc}): {avg}' + (' ms' if str(avg).lstrip('-').isdigit() else ''))
" 2>/dev/null || echo "- Benchmark data not available"
     else
          echo "- Benchmark data not available"
     fi
     
     echo ""
     
     # Detail for meltano
      echo "### meltano"
     echo ""
     if [[ -f "$ARTIFACTS_DIR/meltano/meltano_report.json" ]]; then
          python3 -c "
import json
with open('$ARTIFACTS_DIR/meltano/meltano_report.json') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    desc = bdata.get('description', 'N/A')
    avg = bdata.get('avg_duration_ms', 0)
    print(f'- **{bid}** ({desc}): {avg}' + (' ms' if str(avg).lstrip('-').isdigit() else ''))
" 2>/dev/null || echo "- Benchmark data not available"
     else
          echo "- Benchmark data not available"
     fi
     
     echo ""
     
         # Detail for sling
      echo "### sling"
      echo ""
     if [[ -f "$ARTIFACTS_DIR/sling/sling_report.json" ]]; then
         python3 -c "
import json
with open('$ARTIFACTS_DIR/sling/sling_report.json') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    desc = bdata.get('description', 'N/A')
    avg = bdata.get('avg_duration_ms', 0)
    print(f'- **{bid}** ({desc}): {avg} ms')
" 2>/dev/null || echo "- Benchmark data not available"
     else
          echo "- Benchmark data not available"
     fi
     
     echo ""
     
     # Detail for ingestr
     echo "### ingestr"
     echo ""
     if [[ -f "$ARTIFACTS_DIR/ingestr/ingestr_report.json" ]]; then
         python3 -c "
import json
with open('$ARTIFACTS_DIR/ingestr/ingestr_report.json') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    desc = bdata.get('description', 'N/A')
    avg = bdata.get('avg_duration_ms', 0)
    print(f'- **{bid}** ({desc}): {avg}' + (' ms' if str(avg).isdigit() else ''))
" 2>/dev/null || echo "- Benchmark data not available"
     else
         echo "- Benchmark data not available"
     fi
     
     echo ""
     
      # Detail for native
      echo "### native"
      echo ""
     if [[ -f "$ARTIFACTS_DIR/native/native_report.json" ]]; then
         python3 -c "
import json
with open('$ARTIFACTS_DIR/native/native_report.json') as f:
    data = json.load(f)
benchmarks = data.get('benchmarks', {})
for bid, bdata in benchmarks.items():
    desc = bdata.get('description', 'N/A')
    avg = bdata.get('avg_duration_ms', 0)
    print(f'- **{bid}** ({desc}): {avg}' + (' ms' if str(avg).isdigit() else ''))
" 2>/dev/null || echo "- Benchmark data not available"
     else
          echo "- Benchmark data not available"
     fi
     
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
{
     python3 -c "
import json
from datetime import datetime, timezone

report = {
     'title': 'Competitive Benchmark: dtpipe vs Pandas vs Meltano vs Sling vs Native',
     'configuration': {
         'benchmark_rows': $BENCHMARK_ROWS,
         'repetitions': $BENCHMARK_REPETITIONS,
         'date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
         'host': {
             'os': '$HOST_OS',
             'arch': '$HOST_ARCH',
             'cpu': '$HOST_CPU_MODEL',
             'cpu_cores': int('$HOST_CPUS') if '$HOST_CPUS'.isdigit() else None,
             'ram': '$HOST_RAM'
         }
     },
     'benchmarks': {}
}

benchmark_ids = ['B01', 'B02', 'B03', 'B04', 'B05', 'B06', 'B07', 'B08', 'B09', 'B10', 'B11', 'B12']
descriptions = [
       'Parquet -> PostgreSQL',
       'PostgreSQL -> Parquet',
       'CSV -> SQL Server',
       'SQL Server -> CSV',
       'Parquet -> Oracle',
       'Oracle -> Parquet',
       'CSV -> PostgreSQL',
       'PostgreSQL -> CSV',
       'Parquet -> SQL Server',
       'SQL Server -> Parquet',
       'CSV -> Oracle',
       'Oracle -> CSV'
]


tools = ['dtpipe', 'pandas', 'meltano', 'sling', 'ingestr', 'native']

for bid, desc in zip(benchmark_ids, descriptions):
    report['benchmarks'][bid] = {
        'description': desc,
        'tools': {}
    }
    for tool in tools:
        json_file = f'$ARTIFACTS_DIR/{tool}/{tool}_report.json'
        try:
            with open(json_file) as f:
                data = json.load(f)
            benchmarks = data.get('benchmarks', {})
            if bid in benchmarks:
                report['benchmarks'][bid]['tools'][tool] = {
                    'avg_duration_ms': benchmarks[bid].get('avg_duration_ms', 0),
                    'avg_peak_mem_mb': benchmarks[bid].get('avg_peak_mem_mb', 0),
                    'description': benchmarks[bid].get('description', desc)
                }
        except FileNotFoundError:
            pass

print(json.dumps(report, indent=4))
" 2>/dev/null || echo '{"error": "Impossible to generate JSON report"}'
} > "$REPORT_JSON"

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