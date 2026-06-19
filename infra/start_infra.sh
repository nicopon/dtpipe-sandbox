#!/usr/bin/env bash
# Start container infrastructure for integration tests
# This script checks if containers are already running and healthy before starting them.
# Supports Docker and Podman runtimes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/benchmarks/lib"

# Source the container runtime detection module (docker / podman)
source "$LIB_DIR/container-runtime.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check if docker-compose.yml exists
if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "${RED}Error: docker-compose.yml not found at $COMPOSE_FILE${NC}"
    exit 1
fi

# Initialize container runtime (detects docker or podman)
init_container_runtime || exit 1

echo -e "${GREEN}Using container runtime: $CONTAINER_CMD${NC}"

# Function to check if a container is running and healthy
is_container_healthy() {
    local container_name=$1
    
     # Check if container exists and is running
    local state
    state=$(container_inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "not-found")
    
    if [ "$state" != "running" ]; then
        return 1
    fi
    
     # Check health status (if healthcheck is defined)
    local health_status
    health_status=$(container_inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || echo "none")
    
    if [ "$health_status" = "healthy" ]; then
        return 0
    fi

    if [ "$health_status" = "none" ]; then
         # If no healthcheck is defined, we rely on the container being 'running'
        return 0
    fi
    
    return 1
}

# Advanced check: verify if the database is actually accepting connections/queries
# NOTE: We capture output in a variable to prevent `set -e` from exiting the script
#       when a command fails (containers may not be ready on first start).
#       Also, `[[ -n "$result" ]] || true` prevents `set -e` from exiting when result is empty.
is_db_ready() {
    local container=$1
    case "$container" in
        "dtpipe-integ-postgres")
            container_exec "$container" pg_isready -U postgres >/dev/null 2>&1 && return 0 || return 1
            ;;
        "dtpipe-integ-mssql")
            # Using sqlcmd inside the tools sidecar (shares networking via container-compose)
            container_exec "dtpipe-integ-mssql-tools" /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'Password123!' -Q "SELECT 1" >/dev/null 2>&1 && return 0 || return 1
            ;;
        "dtpipe-integ-oracle")
            # Oracle free has a healthcheck script or we can use sqlplus
            if container_exec "$container" bash -c "ls /usr/local/bin/healthcheck.sh" >/dev/null 2>&1; then
                container_exec "$container" /usr/local/bin/healthcheck.sh >/dev/null 2>&1 && return 0 || return 1
            else
                container_exec "$container" sqlplus -L -S / as sysdba <<< "SELECT 1 FROM DUAL;" >/dev/null 2>&1 && return 0 || return 1
            fi
            ;;
        *)
            return 0 # Default to success for others
            ;;
    esac
}

# List of expected containers from docker-compose.yml
CONTAINERS=("dtpipe-integ-postgres" "dtpipe-integ-mssql" "dtpipe-integ-oracle" "dtpipe-integ-mssql-tools")

check_all_ready() {
    for container in "${CONTAINERS[@]}"; do
        if ! is_container_healthy "$container"; then
            return 1
        fi
        # Deeper check for databases
        if ! is_db_ready "$container"; then
            return 1
        fi
    done
    return 0
}

# Check if all containers are healthy and ready
if check_all_ready; then
    echo -e "${GREEN}✓ All containers are already running and healthy${NC}"
    exit 0
fi

# Start containers
echo -e "${YELLOW}Starting container infrastructure...${NC}"
COMPOSE_PROJECT_DIR="$SCRIPT_DIR"
container_compose -f "$(basename "$COMPOSE_FILE")" up -d

# Wait for containers to be healthy
# Note: Oracle can take several minutes to fully initialize, so we use a
#        longer timeout (300 s = 5 min) and print a warning if it exceeds 2 min.
echo -e "${YELLOW}Waiting for containers to be healthy and databases to be ready...${NC}"
max_wait=300
elapsed=0
warned=false

while [ $elapsed -lt $max_wait ]; do
    if check_all_ready; then
        echo -e "\n${GREEN}✓ All containers are running and healthy${NC}"
        exit 0
    fi
    
    sleep 5
    elapsed=$((elapsed + 5))
    
    # Print a warning after 2 minutes so the user knows something is happening
    if [[ "$warned" == "false" ]] && [ $elapsed -ge 120 ]; then
        echo -e "\n${YELLOW}⚠ Oracle may take several minutes to initialize (elapsed: ${elapsed}s)...${NC}"
        warned=true
    fi
    echo -n "."
done

echo -e "\n${RED}Error: Infrastructure failed to become healthy within ${max_wait}s (${max_wait}/5 min)${NC}"
echo -e "${YELLOW}This can happen on first run when images need to be pulled and databases${NC}"
echo -e "${YELLOW}initialized. Try running the script again — on subsequent runs the DBs${NC}"
echo -e "${YELLOW}should already be healthy and it will complete instantly.${NC}"
echo -e "${RED}Container status:${NC}"
for container in "${CONTAINERS[@]}"; do
    echo -n "   $container: "
    container_inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not found"
done
exit 1
