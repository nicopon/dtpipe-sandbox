# =============================================================================
# lib/container-runtime.sh
# Module de détection du runtime container (docker / podman)
#
# À sourcer depuis n'importe quel script :
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#   source "$REPO_ROOT/lib/container-runtime.sh"
#
# Variables exportées après appel à init_container_runtime() :
#   CONTAINER_CMD   → "docker" ou "podman"
#   COMPOSE_CMD     → "docker compose" ou "podman compose" / "podman-compose"
# =============================================================================

# Variable globale pour éviter de ré-exécuter la détection
_CONTAINER_RUNTIME_INITIALIZED=""

# ---------------------------------------------------------------------------
# Détection interne du runtime container
# ---------------------------------------------------------------------------
_detect_container_runtime() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        CONTAINER_CMD="docker"
        COMPOSE_CMD="docker compose"
        _COMPOSE_CMD=(docker compose)
        return 0
    elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        CONTAINER_CMD="podman"
        if command -v podman-compose &>/dev/null; then
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
    else
        echo "Error: no container runtime found (neither docker nor podman is available)" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Initialiser le runtime (à appeler une fois au début du script)
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
# Fonctions wrapper abstraites sur le runtime détecté
# ---------------------------------------------------------------------------

# Exécute une commande dans un container
# Usage: container_exec <container> <command> [args...]
container_exec() {
    init_container_runtime || return 1
    local container="$1"
    shift
    "$CONTAINER_CMD" exec "$container" "$@"
}

# Exécute une commande compose avec un projet et un fichier optionnels
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

    # Le répertoire de travail est défini par l'appelant via COMPOSE_PROJECT_DIR
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

# Inspecte un container
# Usage: container_inspect [-f <format>] <container>
container_inspect() {
    init_container_runtime || return 1
    local format=""
    local container=""
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) format="$2"; shift 2 ;;
            *)  container="$1"; shift ;;
        esac
    done

    if [[ -n "$format" ]]; then
        "$CONTAINER_CMD" inspect -f "$format" "$container" 2>/dev/null
    else
        "$CONTAINER_CMD" inspect "$container" 2>/dev/null
    fi
}

# Connecte un container à un réseau
# Usage: container_network_connect <network> <container>
container_network_connect() {
    init_container_runtime || return 1
    "$CONTAINER_CMD" network connect "$1" "$2"
}

# Copie un fichier dans/depuis un container
# Usage: container_cp <src> <dst>
container_cp() {
    init_container_runtime || return 1
    "$CONTAINER_CMD" cp "$@"
}

# Vérifie si un container est en cours d'exécution
# Usage: container_is_running <container>
# Returns 0 si le container tourne, 1 sinon
container_is_running() {
    init_container_runtime || return 1
    local container="$1"
    local state
    state=$(container_inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
    [[ "$state" == "true" ]]
}

# Vérifie si une base de données spécifique est prête (à spécialiser par appelant)
# Cette fonction est un placeholder; les appelants doivent implémenter leur propre
# vérification de santé DB en utilisant container_exec.