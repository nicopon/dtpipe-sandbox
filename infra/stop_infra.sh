#!/usr/bin/env bash
# Stop container infrastructure for integration tests
# Supports Docker and Podman runtimes.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"

# Source le module de détection du runtime container (docker / podman)
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
echo -e "${YELLOW}Stopping container infrastructure...${NC}"
COMPOSE_PROJECT_DIR="$SCRIPT_DIR"
container_compose -f "$(basename "$COMPOSE_FILE")" down

echo -e "${GREEN}✓ Infrastructure stopped${NC}"
