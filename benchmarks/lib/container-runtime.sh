# =============================================================================
# lib/container-runtime.sh
# Container runtime detection module (docker / podman)
#
# Source this from any script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#   source "$REPO_ROOT/lib/container-runtime.sh"
#
# Variables exported after calling init_container_runtime():
#   CONTAINER_CMD     → "docker" or "podman"
#   COMPOSE_CMD       → "docker compose" or "podman compose" / "podman-compose"
#
# Compatible with: Linux, macOS, Windows (Git Bash / MSYS / Cygwin)
# =============================================================================

# Global variable to avoid re-running detection
_CONTAINER_RUNTIME_INITIALIZED=""

# ---------------------------------------------------------------------------
# Internal container runtime detection
# ---------------------------------------------------------------------------

# Find the path of an executable, compatible with Windows (Git Bash) and Unix
# Usage: _find_cmd <executable_name>
# Returns the full path of the executable, or empty if not found
_find_cmd() {
    local cmd_name="$1"
    local result=""

    # Environment detection
    local is_windows=false
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
        is_windows=true
    fi
    # Git Bash on Windows also sets the WIN env var
    if [[ -n "${WIN:+}" ]]; then
        is_windows=true
    fi

    if $is_windows; then
        # On Windows/Git Bash, use 'where' to find executables
        # 'where' returns full Windows paths (e.g., C:\Program Files\Docker\docker.exe)
        result=$(where "$cmd_name" 2>/dev/null | head -n1)
        if [[ -n "$result" ]]; then
            # Convert Windows path to Git Bash format:
            # - Convert backslashes to forward slashes
            # - Convert to lowercase
            # - Normalize paths like /c/Program Files/...
            result=$(echo "$result" | tr '[:upper:]' '[:lower:]' | sed 's/\\/\//g')
            # Git Bash on Windows uses /c/ for C:, so ensure the format is correct
            # The sed above should already handle this correctly
        fi
    else
        # On Unix (Linux/macOS), use command -v
        if command -v "$cmd_name" &>/dev/null; then
            result=$(command -v "$cmd_name")
        fi
    fi

    echo "$result"
}

# Check if a container runtime is available and return its name
# Usage: _check_runtime <runtime_name>
# Returns 0 if available, 1 otherwise
_check_runtime() {
    local runtime="$1"
    local runtime_path

    runtime_path=$(_find_cmd "$runtime")
    if [[ -z "$runtime_path" ]]; then
        return 1
    fi

    # On Windows/Git Bash, we don't check execution because the daemon may be
    # in a VM (Docker Desktop) or the service may not be started.
    # On Unix, we verify that the command works.
    if [[ "$OSTYPE" != "msys" && "$OSTYPE" != "cygwin" && "$OSTYPE" != "win32" && -z "${WIN:-}" ]]; then
        if ! "$runtime" info &>/dev/null 2>&1; then
            return 1
        fi
    fi

    return 0
}

_detect_container_runtime() {
    # Try Docker first
    if _check_runtime "docker"; then
        CONTAINER_CMD="docker"
        COMPOSE_CMD="docker compose"
        _COMPOSE_CMD=(docker compose)
        return 0
    fi

    # Try Podman next
    if _check_runtime "podman"; then
        CONTAINER_CMD="podman"
        # Look for a compose implementation for Podman
        if _find_cmd "podman-compose" >/dev/null 2>&1; then
            COMPOSE_CMD="podman-compose"
            _COMPOSE_CMD=(podman-compose)
        elif podman compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="podman compose"
            _COMPOSE_CMD=(podman compose)
        else
            echo "Error: podman is available but no compose implementation found (install podman-compose or podman compose plugin)" >&2
            return 1
        fi
        return 0
    fi

    # No runtime found
    echo "Error: no container runtime found (neither docker nor podman is available)" >&2
    echo "   - On Linux/macOS: install Docker or Podman" >&2
    echo "   - On Windows (Git Bash): ensure Docker Desktop or Podman is installed and running" >&2
    echo "   - You can also set CONTAINER_CMD manually: export CONTAINER_CMD=docker" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Initialize the runtime (call once at the beginning of the script)
# ---------------------------------------------------------------------------
init_container_runtime() {
    if [[ -n "${_CONTAINER_RUNTIME_INITIALIZED:-}" ]]; then
        return 0
    fi
    if _detect_container_runtime; then
        _CONTAINER_RUNTIME_INITIALIZED="1"
        return 0
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Wrapper functions abstracting over the detected runtime
# ---------------------------------------------------------------------------

# Execute a command inside a container
# Usage: container_exec <container> <command> [args...]
# MSYS_NO_PATHCONV prevents Git Bash on Windows from rewriting Unix-style paths in args.
container_exec() {
    init_container_runtime || return 1
    local container="$1"
    shift
    MSYS_NO_PATHCONV=1 "$CONTAINER_CMD" exec "$container" "$@"
}

# Execute a compose command with an optional project and file
# Usage: container_compose [-p <project>] [-f <compose-file>] <args...>
# Sets COMPOSE_PROJECT_DIR before executing (required by caller scripts).
container_compose() {
    init_container_runtime || return 1
    local args=()
    local project=""
    local file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p) project="$2"; shift 2 ;;
            -f) file="$2"; shift 2 ;;
            *)  args+=("$1"); shift ;;
        esac
    done

    # Working directory is set by the caller via COMPOSE_PROJECT_DIR
    if [[ -z "${COMPOSE_PROJECT_DIR:-}" ]]; then
        echo "Error: COMPOSE_PROJECT_DIR is not set. Set it before calling container_compose." >&2
        return 1
    fi

    local compose_args=()
    if [[ -n "$project" ]]; then
        compose_args+=("-p" "$project")
    fi
    if [[ -n "$file" ]]; then
        compose_args+=("-f" "$file")
    fi
    compose_args+=("${args[@]}")

    (cd "$COMPOSE_PROJECT_DIR" && "${_COMPOSE_CMD[@]}" "${compose_args[@]}")
}

# Inspect a container
# Usage: container_inspect [-f <format>] <container>
#        container_inspect --format='{{.State.Status}}' <container>
container_inspect() {
    init_container_runtime || return 1
    local format=""
    local container=""
     # Parse arguments — support both --format=value and --format value and -f value
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f)           format="$2"; shift 2 ;;
            -f*)          format="${1#-f}"; shift 1 ;;          # -f=value
            --format)     format="$2"; shift 2 ;;
            --format*)    format="${1#--format=}"; shift 1 ;;   # --format=value
            *)            container="$1"; shift ;;
        esac
    done

    if [[ -n "$format" ]]; then
         "$CONTAINER_CMD" inspect -f "$format" "$container" 2>/dev/null
    else
         "$CONTAINER_CMD" inspect "$container" 2>/dev/null
    fi
}

# Connect a container to a network
# Usage: container_network_connect <network> <container>
container_network_connect() {
    init_container_runtime || return 1
    "$CONTAINER_CMD" network connect "$1" "$2"
}

# Copy a file into/from a container
# Usage: container_cp <src> <dst>
# MSYS_NO_PATHCONV prevents Git Bash on Windows from rewriting Unix paths (e.g. /tmp/foo)
# into Windows paths before passing them to the container runtime.
container_cp() {
    init_container_runtime || return 1
    MSYS_NO_PATHCONV=1 "$CONTAINER_CMD" cp "$@"
}

# Check if a container is currently running
# Usage: container_is_running <container>
# Returns 0 if the container is running, 1 otherwise
container_is_running() {
    init_container_runtime || return 1
    local container="$1"
    local state
    state=$(container_inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
    [[ "$state" == "true" ]]
}

# Check if a specific database is ready (to be specialized by caller)
# This function is a placeholder; callers should implement their own
# DB health check using container_exec.
