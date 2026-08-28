#!/usr/bin/env bash
# =============================================================================
# benchmarks.sh — Self-contained competitive benchmark orchestrator
#
# Handles the full lifecycle:
#   0. Start DB infrastructure (PostgreSQL / SQL Server / Oracle)
#   1. Build & start benchmark containers
#   2. Initialize source datasets
#   3. Run benchmarks for each tool
#   4. Generate comparative report
#
# Tools compared: dtpipe · pandas/SQLAlchemy · Meltano · Sling · ingestr · native
#
# Platform:      Linux · macOS · Windows (Git Bash / WSL)
# Architecture:  x86_64 and arm64 — Docker pulls the native image automatically
#
# IMPORTANT: All benchmark executions happen INSIDE Docker containers.
#            Nothing is installed permanently on the host.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
INFRA_DIR="$REPO_ROOT/infra"
LIB_DIR="$SCRIPT_DIR/lib"

# Source the container runtime detection module (docker / podman)
source "$LIB_DIR/container-runtime.sh"

# =============================================================================
# Defaults
# =============================================================================
BENCHMARK_ROWS=1000000
BENCHMARK_REPETITIONS=3
BENCHMARK_SCOPE="all"          # all | transfer | transform | B01 … B19 | comma-separated ids
BENCHMARK_TOOL="all"           # all | one tool | comma-separated list
SKIP_INFRA=false               # --skip-infra  → skip DB infrastructure startup
CLEAN_ARTIFACTS=false          # --clean-artifacts → wipe tool output files before running
INFRA_COMPOSE_FILE=""          # --infra-compose FILE → custom infra compose path

# Docker compose project name → determines network name
COMPOSE_PROJECT="dtpipe-benchmark"
BENCHMARK_NETWORK="${COMPOSE_PROJECT}_benchmark-net"

# =============================================================================
# Color support (disabled automatically when not in a TTY or NO_COLOR=1)
# =============================================================================
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' BLUE='' CYAN='' NC=''
fi

format_number() {
     # Format an integer with thousands separators, e.g. 250000 → 250,000
     printf '%s\n' "$1" | awk '{printf "%'\''d\n", $1}' 2>/dev/null || echo "$1"
}

# =============================================================================
# Help
# =============================================================================
show_help() {
    cat <<EOF

Usage: $(basename "$0") [OPTIONS]

Self-contained benchmark runner — starts infrastructure, initializes data,
runs all tool benchmarks and generates a comparative report.

Options:
  --rows NUM              Number of source rows            (default: 1000000)
  --repetitions NUM       Runs per benchmark               (default: 3)
  --scope SELECTOR        Restrict which benchmarks run     (default: all)
                          all        every benchmark
                          transfer   B01-B15, the competitive transfers
                          transform  B16-B19, the dtpipe-only transformer family
                          B07        a single benchmark
                          B16,B19    a comma-separated list
  --tool SELECTOR         Restrict which tools run          (default: all)
                          all                every tool
                          dtpipe             a single tool
                          dtpipe,ingestr     a comma-separated list
                          Names: dtpipe pandas meltano sling ingestr native
  --skip-infra            Do not start DB infrastructure
                          (use when containers are already running)
   --infra-compose FILE    Path to the infrastructure docker-compose file
                           (default: infra/docker-compose.yml)
  --clean-artifacts       Remove previous tool output files before running
  -h, --help              Show this help

Examples:
  # Full benchmark — 1 000 000 rows, 3 runs, all tools (default):
  ./benchmarks.sh

  # Smaller and faster, for iterating on the suite itself
  # (not for publication — see "Fixed cost" in benchmarks/README.md):
  ./benchmarks.sh --rows 250000 --repetitions 3

  # Single tool, single pipeline:
  ./benchmarks.sh --tool dtpipe --scope B01

  # Baseline run for the performance gate: only dtpipe is compared, so measuring
  # the competitors costs time and buys nothing (it is ~20 % of the full run):
  ./benchmarks.sh --tool dtpipe

  # Head-to-head against the closest competitor only:
  ./benchmarks.sh --tool dtpipe,ingestr

  # Only the transformer family (dtpipe-only, no DB target needed):
  ./benchmarks.sh --tool dtpipe --scope transform

  # Infrastructure already running, clean outputs:
  ./benchmarks.sh --skip-infra --clean-artifacts

  # Point to a custom infra compose file:
  ./benchmarks.sh --infra-compose /path/to/docker-compose.yml

EOF
}

# =============================================================================
# Parse command-line arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --rows)             BENCHMARK_ROWS="$2";         shift 2 ;;
        --repetitions)      BENCHMARK_REPETITIONS="$2";  shift 2 ;;
        --scope)            BENCHMARK_SCOPE="$2";         shift 2 ;;
        --tool)             BENCHMARK_TOOL="$2";          shift 2 ;;
        --skip-infra)       SKIP_INFRA=true;              shift   ;;
        --clean-artifacts)  CLEAN_ARTIFACTS=true;         shift   ;;
        --infra-compose)    INFRA_COMPOSE_FILE="$2";      shift 2 ;;
        -h|--help)          show_help; exit 0 ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Run '$0 --help' for usage."
            exit 1
            ;;
    esac
done

# =============================================================================
# Banner
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Competitive Benchmark — dtpipe vs the field            ║${NC}"
echo -e "${GREEN}║  dtpipe · pandas · meltano · sling · ingestr · native        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}Rows:${NC}         $(format_number "$BENCHMARK_ROWS")"
echo -e "  ${BLUE}Repetitions:${NC}  $BENCHMARK_REPETITIONS"
echo -e "  ${BLUE}Scope:${NC}        $BENCHMARK_SCOPE"
echo -e "  ${BLUE}Tool:${NC}         $BENCHMARK_TOOL"
echo ""

# =============================================================================
# Helper: docker compose with explicit project name
# (ensures a predictable network name: dtpipe-benchmark_benchmark-net)
# =============================================================================
DOCKER_COMPOSE_CMD() {
    COMPOSE_PROJECT_DIR="$CONFIG_DIR"
     container_compose -p "$COMPOSE_PROJECT" -f docker-compose-benchmark.yml "$@"
}

# =============================================================================
# Step 0a: Start DB infrastructure
# =============================================================================
if [[ "$SKIP_INFRA" == "true" ]]; then
    echo -e "${YELLOW}--skip-infra: skipping infrastructure startup${NC}"
else
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo -e "${CYAN}  Step 0: DB Infrastructure${NC}"
    echo -e "${CYAN}══════════════════════════════════════${NC}"

    # Resolve infra compose file
    if [[ -z "$INFRA_COMPOSE_FILE" ]]; then
        INFRA_COMPOSE_FILE="$INFRA_DIR/docker-compose.yml"
    fi

    # Check if all DB containers are already running (healthy)
    _infra_all_running() {
        for db in dtpipe-integ-postgres dtpipe-integ-mssql dtpipe-integ-oracle; do
            local state
            state=$(container_inspect -f '{{.State.Running}}' "$db" 2>/dev/null || echo "false")
            if [[ "$state" != "true" ]]; then
                return 1
            fi
        done
        return 0
     }

    if _infra_all_running; then
        echo -e "${GREEN}✓ DB containers already running${NC}"
    elif [[ -f "$INFRA_COMPOSE_FILE" ]]; then
        # Try the dedicated start_infra.sh first (performs health checks + wait)
        INFRA_START_SH="$(dirname "$INFRA_COMPOSE_FILE")/start_infra.sh"
        if [[ -f "$INFRA_START_SH" ]]; then
            echo -e "${YELLOW}Starting infrastructure via start_infra.sh ...${NC}"
            bash "$INFRA_START_SH"
        else
            echo -e "${YELLOW}Starting infrastructure via container compose ...${NC}"
             COMPOSE_PROJECT_DIR="$(dirname "$INFRA_COMPOSE_FILE")"
             container_compose -f "$(basename "$INFRA_COMPOSE_FILE")" up -d

             # Wait for containers to become running (up to 120s)
            echo -n "Waiting for DB containers"
            _elapsed=0
            until _infra_all_running || [[ $_elapsed -ge 120 ]]; do
                sleep 3; _elapsed=$((_elapsed + 3)); echo -n "."
            done
            echo ""
            if ! _infra_all_running; then
                echo -e "${RED}Error: DB containers did not start within 120 s.${NC}"
                echo -e "${RED}Run '$0 --skip-infra' if they are managed externally.${NC}"
                exit 1
            fi
        fi
        echo -e "${GREEN}✓ DB infrastructure ready${NC}"
    else
        echo -e "${RED}Error: infra compose file not found at: $INFRA_COMPOSE_FILE${NC}"
        echo -e "${RED}Options:${NC}"
        echo -e "${RED}  • Use --infra-compose FILE to point to your compose file${NC}"
        echo -e "${RED}  • Use --skip-infra if DB containers are already running${NC}"
        exit 1
    fi
fi

# =============================================================================
# Step 0b: Ensure artifacts directories exist
# =============================================================================
mkdir -p "$ARTIFACTS_DIR"/{dtpipe,pandas,meltano,sling,ingestr,native,reports}

# Optionally clean previous tool output files (not source data)
if [[ "$CLEAN_ARTIFACTS" == "true" ]]; then
    echo -e "${YELLOW}--clean-artifacts: removing previous tool output files...${NC}"
    for tool in dtpipe pandas meltano sling ingestr native; do
        rm -f "$ARTIFACTS_DIR/${tool}/${tool}_report.json"
    done
    rm -f "$ARTIFACTS_DIR"/*.parquet "$ARTIFACTS_DIR"/*.csv 2>/dev/null || true
    rm -f "$ARTIFACTS_DIR/reports/"*.md "$ARTIFACTS_DIR/reports/"*.json 2>/dev/null || true
fi

# =============================================================================
# Step 0c: Build & start benchmark containers
# =============================================================================
echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}  Step 0b: Benchmark containers${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"

echo -e "${YELLOW}Cleaning up leftover benchmark containers...${NC}"
DOCKER_COMPOSE_CMD down --remove-orphans 2>/dev/null || true
for _c in benchmark-test; do
    "$CONTAINER_CMD" rm -f "$_c" 2>/dev/null || true
done

# Resolve latest tool versions from GitHub releases
echo -e "${YELLOW}Resolving latest tool versions from GitHub...${NC}"
_resolve_tag() {
    local repo="$1"
    local url
    url=$(curl -sIL -o /dev/null -w "%{url_effective}" "https://github.com/${repo}/releases/latest" 2>/dev/null | tr -d "\r\n")
    if [[ "$url" =~ /tag/([^/]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

DTPIPE_LATEST=$(_resolve_tag "nicopon/dtpipe" || echo "")
SLING_LATEST=$(_resolve_tag "slingdata-io/sling-cli" || echo "")
INGESTR_LATEST=$(_resolve_tag "bruin-data/ingestr" || echo "")

# Fallback to default pinned versions if resolution failed (e.g. offline)
DTPIPE_LATEST="${DTPIPE_LATEST:-v1.4.0}"
SLING_LATEST="${SLING_LATEST:-v1.5.20}"
INGESTR_LATEST="${INGESTR_LATEST:-v1.0.37}"

echo "  dtpipe version:  $DTPIPE_LATEST"
echo "  sling version:   $SLING_LATEST"
echo "  ingestr version: $INGESTR_LATEST"
echo ""

DOCKER_COMPOSE_CMD build \
    --build-arg DTPIPE_VERSION="$DTPIPE_LATEST" \
    --build-arg SLING_VERSION="$SLING_LATEST" \
    --build-arg INGESTR_VERSION="$INGESTR_LATEST" || {
    echo -e "${RED}Error while building containers.${NC}"
    exit 1
}

DOCKER_COMPOSE_CMD up -d || {
    echo -e "${RED}Error while starting benchmark containers.${NC}"
    exit 1
}

# Connect DB containers to the benchmark network
echo -e "${YELLOW}Connecting DB containers to benchmark network (${BENCHMARK_NETWORK})...${NC}"
for db in dtpipe-integ-postgres dtpipe-integ-oracle dtpipe-integ-mssql; do
    container_network_connect "$BENCHMARK_NETWORK" "$db" 2>/dev/null || true
done


echo ""
echo -e "${GREEN}Container status:${NC}"
DOCKER_COMPOSE_CMD ps || true
echo ""

# =============================================================================
# Step 1: Initialize source data
# =============================================================================
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}  Step 1: Source data initialization${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"

INIT_SCRIPT="$SCRIPT_DIR/runners/01-init-data.sh"
if [[ -f "$INIT_SCRIPT" ]]; then
    bash "$INIT_SCRIPT" --rows "$BENCHMARK_ROWS" || {
        echo -e "${RED}Error during data initialization.${NC}"
        exit 1
    }
else
    echo -e "${YELLOW}Warning: 01-init-data.sh not found — skipping data initialization.${NC}"
fi
echo ""

# =============================================================================
# Step 2: Run benchmarks per tool
# =============================================================================
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}  Step 2: Benchmarks${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"

ALL_TOOLS=("dtpipe" "pandas" "meltano" "sling" "ingestr" "native")
if [[ "$BENCHMARK_TOOL" == "all" ]]; then
    TOOLS=("${ALL_TOOLS[@]}")
else
    # Comma-separated list, same grammar as --scope. A typo used to degrade
    # silently into "03-<typo>.sh not found - skipped", so validate instead.
    IFS=',' read -ra TOOLS <<< "$BENCHMARK_TOOL"
    for _t in "${TOOLS[@]}"; do
        _known=false
        for _k in "${ALL_TOOLS[@]}"; do [[ "$_t" == "$_k" ]] && _known=true; done
        if [[ "$_known" != true ]]; then
            echo -e "${RED}Unknown tool: '$_t'${NC}"
            echo -e "${RED}Known tools: ${ALL_TOOLS[*]}${NC}"
            exit 1
        fi
    done
fi

for tool in "${TOOLS[@]}"; do
    echo ""
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  Tool: $tool${NC}"
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"

    BENCH_SCRIPT="$SCRIPT_DIR/runners/03-${tool}.sh"
    if [[ -f "$BENCH_SCRIPT" ]]; then
        chmod +x "$BENCH_SCRIPT"
        bash "$BENCH_SCRIPT" \
            --rows "$BENCHMARK_ROWS" \
            --repetitions "$BENCHMARK_REPETITIONS" \
            --scope "$BENCHMARK_SCOPE" || \
            echo -e "${RED}Error during benchmark for $tool (continuing with next tool).${NC}"
    else
        echo -e "${YELLOW}Warning: 03-${tool}.sh not found — benchmark skipped for $tool.${NC}"
    fi
done

# =============================================================================
# Step 3: Generate final comparative report
# =============================================================================
echo ""
echo -e "${CYAN}══════════════════════════════════════${NC}"
echo -e "${CYAN}  Step 3: Generating report${NC}"
echo -e "${CYAN}══════════════════════════════════════${NC}"

REPORT_SCRIPT="$SCRIPT_DIR/runners/04-report.sh"
if [[ -f "$REPORT_SCRIPT" ]]; then
    chmod +x "$REPORT_SCRIPT"
    bash "$REPORT_SCRIPT" \
        --rows "$BENCHMARK_ROWS" \
        --repetitions "$BENCHMARK_REPETITIONS" || \
        echo -e "${RED}Error while generating report.${NC}"
else
    echo -e "${YELLOW}Warning: 04-report.sh not found — report not generated.${NC}"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                  Benchmark complete ✓                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Reports:"
echo -e "  ${BLUE}$ARTIFACTS_DIR/reports/benchmark_report.md${NC}"
echo -e "  ${BLUE}$ARTIFACTS_DIR/reports/benchmark_report.json${NC}"
echo ""
