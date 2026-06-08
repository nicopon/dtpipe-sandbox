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
INFRA_DIR="$REPO_ROOT/tests/infra"

# =============================================================================
# Defaults
# =============================================================================
BENCHMARK_ROWS=250000
BENCHMARK_REPETITIONS=3
BENCHMARK_SCOPE="all"          # all | B01 … B12
BENCHMARK_TOOL="all"           # all | dtpipe | pandas | meltano | sling | ingestr | native
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

# =============================================================================
# Python detection (python3 on Linux/macOS, python on Windows)
# =============================================================================
PYTHON_CMD=""
for _py in python3 python py; do
    if command -v "$_py" &>/dev/null; then
        PYTHON_CMD="$_py"
        break
    fi
done

format_number() {
    # Format an integer with thousands separators, e.g. 250000 → 250,000
    if [[ -n "$PYTHON_CMD" ]]; then
        $PYTHON_CMD -c "print(f'{int($1):,}')" 2>/dev/null || echo "$1"
    else
        echo "$1"
    fi
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
  --rows NUM              Number of source rows            (default: 250000)
  --repetitions NUM       Runs per benchmark               (default: 3)
  --scope B01|...|all     Restrict to a single pipeline    (default: all)
  --tool NAME|all         Restrict to a single tool        (default: all)
                          Names: dtpipe pandas meltano sling ingestr native
  --skip-infra            Do not start DB infrastructure
                          (use when containers are already running)
  --infra-compose FILE    Path to the infrastructure docker-compose file
                          (default: tests/infra/docker-compose.yml)
  --clean-artifacts       Remove previous tool output files before running
  -h, --help              Show this help

Examples:
  # Full benchmark — 250 000 rows, 3 runs, all tools (default):
  ./benchmarks.sh

  # Larger dataset with 5 repetitions:
  ./benchmarks.sh --rows 1000000 --repetitions 5

  # Single tool, single pipeline:
  ./benchmarks.sh --tool dtpipe --scope B01

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
    (cd "$CONFIG_DIR" && docker compose -p "$COMPOSE_PROJECT" -f docker-compose-benchmark.yml "$@")
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
            state=$(docker inspect -f '{{.State.Running}}' "$db" 2>/dev/null || echo "false")
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
            echo -e "${YELLOW}Starting infrastructure via docker compose ...${NC}"
            (cd "$(dirname "$INFRA_COMPOSE_FILE")" && \
                docker compose -f "$(basename "$INFRA_COMPOSE_FILE")" up -d)

            # Wait for containers to become running (up to 120s)
            echo -n "Waiting for DB containers"
            local _elapsed=0
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

DOCKER_COMPOSE_CMD build || {
    echo -e "${RED}Error while building containers.${NC}"
    exit 1
}

for container in benchmark-dtpipe benchmark-pandas benchmark-meltano benchmark-sling benchmark-ingestr benchmark-native; do
    if ! DOCKER_COMPOSE_CMD ps "$container" 2>/dev/null | grep -q "running\|Running"; then
        echo "Starting $container..."
        DOCKER_COMPOSE_CMD up -d "$container" || \
            echo -e "${YELLOW}Warning: Unable to start $container${NC}"
    fi
done

# Connect DB containers to the benchmark network
echo -e "${YELLOW}Connecting DB containers to benchmark network (${BENCHMARK_NETWORK})...${NC}"
for db in dtpipe-integ-postgres dtpipe-integ-oracle dtpipe-integ-mssql; do
    docker network connect "$BENCHMARK_NETWORK" "$db" 2>/dev/null || true
done

# Install/update the local dtpipe CLI package in its container
echo -e "${YELLOW}Installing local dtpipe package...${NC}"
docker exec benchmark-dtpipe bash -c \
    "dotnet tool uninstall -g dtpipe 2>/dev/null || true; \
     dotnet tool install -g dtpipe --add-source /bench/artifacts"

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

INIT_SCRIPT="$SCRIPT_DIR/01-init-data.sh"
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

TOOLS=("dtpipe" "pandas" "meltano" "sling" "ingestr" "native")
[[ "$BENCHMARK_TOOL" != "all" ]] && TOOLS=("$BENCHMARK_TOOL")

for tool in "${TOOLS[@]}"; do
    echo ""
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  Tool: $tool${NC}"
    echo -e "${GREEN}────────────────────────────────────────────────${NC}"

    BENCH_SCRIPT="$SCRIPT_DIR/03-${tool}.sh"
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

REPORT_SCRIPT="$SCRIPT_DIR/04-report.sh"
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
