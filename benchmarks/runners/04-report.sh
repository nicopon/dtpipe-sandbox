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
BENCHMARK_ROWS=1000000
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
# Retrieve tool versions from the benchmark-test container
# =============================================================================
VER_DTPIPE="Unknown"
VER_PANDAS="Unknown"
VER_SQLALCHEMY="Unknown"
VER_MELTANO="Unknown"
VER_SLING="Unknown"
VER_INGESTR="Unknown"
VER_PSQL="Unknown"
VER_BCP="Unknown"
VER_SQLPLUS="Unknown"

if container_is_running "benchmark-test"; then
    VER_DTPIPE=$(container_exec benchmark-test dtpipe --version 2>/dev/null | awk '{print $2}' || echo "Unknown")
    VER_PANDAS=$(container_exec benchmark-test /opt/venv/pandas/bin/python3 -c "import pandas; print(pandas.__version__)" 2>/dev/null || echo "Unknown")
    VER_SQLALCHEMY=$(container_exec benchmark-test /opt/venv/pandas/bin/python3 -c "import sqlalchemy; print(sqlalchemy.__version__)" 2>/dev/null || echo "Unknown")
    VER_MELTANO=$(container_exec benchmark-test /opt/venv/meltano/bin/meltano --version 2>/dev/null | awk '{print $3}' || echo "Unknown")
    VER_SLING=$(container_exec benchmark-test sling --version 2>/dev/null | awk '{print $2}' || echo "Unknown")
    VER_INGESTR=$(container_exec benchmark-test ingestr --version 2>/dev/null | awk '{print $3}' || echo "Unknown")
    VER_PSQL=$(container_exec benchmark-test psql --version 2>/dev/null | awk '{print $3}' || echo "Unknown")
    VER_BCP=$(container_exec benchmark-test bcp -v 2>/dev/null | grep "Version:" | awk '{print $2}' || echo "Unknown")
    VER_SQLPLUS=$(container_exec benchmark-test sqlplus -V 2>/dev/null | grep "Version" | awk '{print $2}' || echo "Unknown")
fi

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

# =============================================================================
# Helper: Format a dispersion row — "avg ±sd (n)" per tool, unranked.
# Args: benchmark_desc avg1 sd1 runs1 tool1 ... avgN sdN runsN toolN
# Ranking is deliberately absent: this table exists to show how much noise sits
# behind the reference figure, not to declare a winner.
# =============================================================================
format_dispersion_row() {
    local desc="$1"
    shift

    local tmpfile
    tmpfile=$(mktemp)

    while [[ $# -gt 0 ]]; do
        echo "$1|$2|$3" >> "$tmpfile"
        shift 4
    done

    awk -v desc="$desc" '
    BEGIN { n = 0 }
    {
        n++
        split($0, parts, "|")
        avgs[n] = parts[1]
        sds[n]  = parts[2]
        runs[n] = parts[3]
    }
    END {
        printf "| %s", desc
        for (i = 1; i <= n; i++) {
            a = avgs[i]
            if (a == "Not supported" || a == "Not implemented" || a == "N/A" || a == "" || a + 0 <= 0) {
                printf " | —"
                continue
            }
            if (sds[i] == "N/A" || sds[i] == "")
                printf " | %d ms", a + 0
            else if (runs[i] == "N/A" || runs[i] == "")
                printf " | %d ±%.0f ms", a + 0, sds[i] + 0
            else
                printf " | %d ±%.0f ms (%d)", a + 0, sds[i] + 0, runs[i] + 0
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

    # Parse JSON using jq and populate variables.
    # min is the reference statistic (see the Statistics note in the report);
    # avg and the sample stddev travel with it so dispersion stays visible.
    local benchmarks
    benchmarks=$(jq -r '.benchmarks | to_entries[] | "\(.key)|\(.value.avg_duration_ms)|\(.value.avg_peak_mem_mb // "N/A")|\(.value.min_duration_ms // "N/A")|\(.value.stddev_duration_ms // "N/A")|\(.value.runs // "N/A")"' "$json_file" 2>/dev/null) || return

    while IFS='|' read -r key value mem min_value sd_value runs_value; do
        [[ -z "$key" ]] && continue
        # Reports produced before dispersion was added carry only avg_duration_ms;
        # fall back to it so an older artifact still renders instead of blanking out.
        [[ "$min_value" == "N/A" || "$min_value" == "null" ]] && min_value="$value"
        [[ "$sd_value" == "null" ]] && sd_value="N/A"
        [[ "$runs_value" == "null" ]] && runs_value="N/A"
        eval "${tool}_${key}=\"\$value\""
        eval "${tool}_mem_${key}=\"\$mem\""
        eval "${tool}_min_${key}=\"\$min_value\""
        eval "${tool}_sd_${key}=\"\$sd_value\""
        eval "${tool}_runs_${key}=\"\$runs_value\""
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

# Transformation family — dtpipe only, no competitor column (see 03-dtpipe.sh).
# Kept out of BENCHMARK_IDS so the comparative tables stay a like-for-like grid.
TRANSFORM_IDS=("B16" "B17" "B18" "B19")
TRANSFORM_DESCRIPTIONS=(
       "Control — no transformer"
       "Columnar chain — fake + filter + mask"
       "Row chain — compute"
       "Mixed chain — forces row↔columnar bridge"
)
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
    echo "## Tool Versions"
    echo ""
    echo "| Tool | Version |"
    echo "|:---|:---|"
    echo "| dtpipe | ${VER_DTPIPE} |"
    echo "| pandas | ${VER_PANDAS} |"
    echo "| sqlalchemy | ${VER_SQLALCHEMY} |"
    echo "| meltano | ${VER_MELTANO} |"
    echo "| sling | ${VER_SLING} |"
    echo "| ingestr | ${VER_INGESTR} |"
    echo "| psql (PostgreSQL client) | ${VER_PSQL} |"
    echo "| bcp (SQL Server client) | ${VER_BCP} |"
    echo "| sqlplus (Oracle client) | ${VER_SQLPLUS} |"
    echo ""
    echo "---"
    echo ""
    # Columns are the tools this run actually measured, not a fixed six. benchmarks.sh
    # purges every per-tool report before a run, so a file here means that tool ran now.
    # A column of nothing but "N/A" is worse than an absent one: it reads as a tool that
    # was measured and produced nothing, which is the mistake meltano's missing bootstrap
    # already made once.
    REPORT_TOOLS=()
    for _t in dtpipe pandas meltano sling ingestr native; do
        [[ -f "$ARTIFACTS_DIR/${_t}/${_t}_report.json" ]] && REPORT_TOOLS+=("$_t")
    done
    [[ ${#REPORT_TOOLS[@]} -eq 0 ]] && REPORT_TOOLS=(dtpipe)

    _tool_label() { [[ "$1" == "pandas" ]] && echo "pandas - sqlalchemy" || echo "$1"; }
    _header_row() {
        local h="| Benchmark" sep="|:---"
        for _t in "${REPORT_TOOLS[@]}"; do h+=" | $(_tool_label "$_t")"; sep+="|:---:"; done
        echo "$h |"; echo "$sep|"
    }

    echo "## Comparative Table — Duration (min of $BENCHMARK_REPETITIONS runs, ms)"
    echo ""
    echo "> The fastest of the repetitions is the reference figure: scheduling noise,"
    echo "> page-cache warming and neighbour processes can only ever add time to a run."
    echo "> The dispersion table below says how much noise sits behind each figure."
    echo ""
    _header_row

          # Calculate and display results for each benchmark (best value bolded)
      for idx in "${!BENCHMARK_IDS[@]}"; do
          bid="${BENCHMARK_IDS[$idx]}"
          bdesc="${BENCHMARK_DESCRIPTIONS[$idx]}"

          _args=()
          for _t in "${REPORT_TOOLS[@]}"; do
              eval "_v=\${${_t}_min_${bid}:-N/A}"
              _args+=("$_v" "$_t")
          done
          format_table_row --duration "$BENCHMARK_ROWS" "$bdesc" "${_args[@]}"
      done

    echo ""
    echo "## Comparative Table — Dispersion (avg ± sample stddev, runs)"
    echo ""
    echo "> Read against the table above: a gap between two tools that is smaller than"
    echo "> their standard deviations is not a result. \"—\" = not supported or not run."
    echo ""
    _header_row

      for idx in "${!BENCHMARK_IDS[@]}"; do
          bid="${BENCHMARK_IDS[$idx]}"
          bdesc="${BENCHMARK_DESCRIPTIONS[$idx]}"

          _args=()
          for _t in "${REPORT_TOOLS[@]}"; do
              eval "_a=\${${_t}_${bid}:-N/A}"
              eval "_s=\${${_t}_sd_${bid}:-N/A}"
              eval "_r=\${${_t}_runs_${bid}:-N/A}"
              _args+=("$_a" "$_s" "$_r" "$_t")
          done
          format_dispersion_row "$bdesc" "${_args[@]}"
      done

    echo ""
    echo "## Comparative Table — Peak Memory Delta (avg MiB)"
    echo ""
    echo "> Peak cgroup memory increase measured from container baseline during transfer."
    echo "> N/A = not supported or not implemented for this tool."
    echo ""
    _header_row

      for idx in "${!BENCHMARK_IDS[@]}"; do
          bid="${BENCHMARK_IDS[$idx]}"
          bdesc="${BENCHMARK_DESCRIPTIONS[$idx]}"

          _args=()
          for _t in "${REPORT_TOOLS[@]}"; do
              eval "_v=\${${_t}_mem_${bid}:-N/A}"
              _args+=("$_v" "$_t")
          done
          format_mem_row "$bdesc" "${_args[@]}"
      done
      
    echo ""
    echo "---"
    echo ""
    echo "## Transformation Scenarios — dtpipe only (Parquet → null:)"
    echo ""
    echo "> These four measure what a **transformer** costs, not what a target costs:"
    echo "> same Parquet source, \`null:\` sink, so the sink is a no-op and the delta"
    echo "> between two scenarios is transformation work alone. No competitor column —"
    echo "> the question here is internal regression and one design decision, not"
    echo "> how dtpipe places against another tool."
    echo ""
    echo "| Scenario | min | avg ± sd | Peak mem (avg) |"
    echo "|:---|:---:|:---:|:---:|"

      _has_transform=false
      for idx in "${!TRANSFORM_IDS[@]}"; do
          bid="${TRANSFORM_IDS[$idx]}"
          bdesc="${TRANSFORM_DESCRIPTIONS[$idx]}"
          eval "t_min=\${dtpipe_min_${bid}:-N/A}"
          eval "t_avg=\${dtpipe_${bid}:-N/A}"
          eval "t_sd=\${dtpipe_sd_${bid}:-N/A}"
          eval "t_runs=\${dtpipe_runs_${bid}:-N/A}"
          eval "t_mem=\${dtpipe_mem_${bid}:-N/A}"

          if [[ "$t_min" =~ ^[0-9]+$ ]] && [[ "$t_min" -gt 0 ]]; then
              _has_transform=true
              _disp="$t_avg ms"
              [[ "$t_sd" =~ ^[0-9.]+$ ]] && _disp="$t_avg ± $t_sd ms"
              [[ "$t_runs" =~ ^[0-9]+$ ]] && _disp="$_disp ($t_runs)"
              echo "| **$bid** — $bdesc | ${t_min} ms | ${_disp} | ${t_mem} MiB |"
          else
              echo "| **$bid** — $bdesc | not run | — | — |"
          fi
      done

    echo ""
    if [[ "$_has_transform" == "true" ]]; then
        echo "### What the four numbers decide"
        echo ""
        echo "Each scenario subtracts from the control, so the figures below are"
        echo "transformation cost with read, materialization and sink removed."
        echo ""
        echo "| Quantity | Value |"
        echo "|:---|:---:|"

        _b16="${dtpipe_min_B16:-}"
        _b17="${dtpipe_min_B17:-}"
        _b18="${dtpipe_min_B18:-}"
        _b19="${dtpipe_min_B19:-}"

        _delta() {
            # $1 - $2, printed as ms, or "—" when either side is missing
            if [[ "$1" =~ ^[0-9]+$ ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "$(( $1 - $2 )) ms"
            else
                echo "—"
            fi
        }

        echo "| Columnar chain (B17 − B16) | $(_delta "$_b17" "$_b16") |"
        echo "| Row-mode compute (B18 − B16) | $(_delta "$_b18" "$_b16") |"
        if [[ "$_b16" =~ ^[0-9]+$ ]] && [[ "$_b17" =~ ^[0-9]+$ ]] && \
           [[ "$_b18" =~ ^[0-9]+$ ]] && [[ "$_b19" =~ ^[0-9]+$ ]]; then
            _bridge=$(( (_b19 - _b17) - (_b18 - _b16) ))
            _compute=$(( _b18 - _b16 ))
            echo "| **Extra row↔columnar bridge** ((B19 − B17) − (B18 − B16)) | **${_bridge} ms** |"
            echo ""
            echo "The bet on a vectorized \`--compute\` is worth taking only if the mode"
            echo "switch, not the JavaScript evaluation, is what costs. Vectorizing removes"
            echo "the bridge; it does not remove a per-row script call."
            echo ""
            if [[ "$_compute" -gt 0 ]]; then
                _ratio=$(awk -v b="$_bridge" -v c="$_compute" 'BEGIN { printf "%.0f", (b * 100.0) / c }')
                echo "- Bridge as a share of the row-mode compute cost: **${_ratio} %**."
            fi
            echo "- Read this against the standard deviations above: a delta smaller than"
            echo "  the dispersion of its terms is not a result."
        else
            echo "| **Extra row↔columnar bridge** ((B19 − B17) − (B18 − B16)) | — |"
        fi
        echo ""
    fi

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
        jq -r '.benchmarks | to_entries[] | . as $e
            | ($e.value.avg_duration_ms | tostring | ltrimstr("-") | test("^[0-9]+$")) as $numeric
            | if $numeric | not then "- **\($e.key)** (\($e.value.description // "N/A")): \($e.value.avg_duration_ms)"
              else "- **\($e.key)** (\($e.value.description // "N/A")): \($e.value.min_duration_ms // $e.value.avg_duration_ms) ms min · \($e.value.avg_duration_ms) ms avg"
                   + (if ($e.value.stddev_duration_ms // null) != null then " ± \($e.value.stddev_duration_ms)" else "" end)
                   + (if ($e.value.runs // null) != null then " over \($e.value.runs) runs" else "" end)
              end' "$_report_file" 2>/dev/null || echo "- Benchmark data not available"
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
     echo "### Statistics"
     echo ""
     echo "- Each benchmark is run $BENCHMARK_REPETITIONS times."
     echo "- **Reference figure = the minimum.** Noise on a shared machine is one-sided:"
     echo "  it can only make a run slower. The fastest run is therefore the closest"
     echo "  estimate of the tool's own cost, and it is what the comparison gate uses."
     echo "- The average is kept for continuity with earlier reports; the standard"
     echo "  deviation is the **sample** one (Bessel-corrected, n-1) — with 3 to 5"
     echo "  repetitions the uncorrected form understates dispersion by about 20 %."
     echo "- A difference between two figures that is smaller than their standard"
     echo "  deviations is noise, not a result."
     echo "- The machine-readable JSON carries \`min_duration_ms\`, \`avg_duration_ms\`,"
     echo "  \`stddev_duration_ms\`, \`runs\`, \`avg_peak_mem_mb\` and \`min_peak_mem_mb\`."
     echo ""
     echo "### Environment"
     echo ""
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
        --arg ver_dtpipe "$VER_DTPIPE" \
        --arg ver_pandas "$VER_PANDAS" \
        --arg ver_sqlalchemy "$VER_SQLALCHEMY" \
        --arg ver_meltano "$VER_MELTANO" \
        --arg ver_sling "$VER_SLING" \
        --arg ver_ingestr "$VER_INGESTR" \
        --arg ver_psql "$VER_PSQL" \
        --arg ver_bcp "$VER_BCP" \
        --arg ver_sqlplus "$VER_SQLPLUS" \
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
                },
                versions: {
                    dtpipe: $ver_dtpipe,
                    pandas: $ver_pandas,
                    sqlalchemy: $ver_sqlalchemy,
                    meltano: $ver_meltano,
                    sling: $ver_sling,
                    ingestr: $ver_ingestr,
                    psql: $ver_psql,
                    bcp: $ver_bcp,
                    sqlplus: $ver_sqlplus
                }
            },
            benchmarks: {}
        }')

    # Benchmark descriptions
    local bench_ids=("B01" "B02" "B03" "B04" "B05" "B06" "B07" "B08" "B09" "B10" "B11" "B12" "B13" "B14" "B15" "B16" "B17" "B18" "B19")
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
        "Transform control -> null (no transformer)"
        "Transform columnar chain -> null (fake+filter+mask)"
        "Transform row chain -> null (compute)"
        "Transform mixed chain -> null (row/columnar bridge)"
    )

    local tools=("${REPORT_TOOLS[@]}")

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