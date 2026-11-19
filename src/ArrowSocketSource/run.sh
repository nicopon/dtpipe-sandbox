#!/usr/bin/env bash
# A coordinator in a container, a runner and the service as processes of the host. The service hosts the node 'shop' in its
# process and runs the dtpipe tool package its build downloaded. Two bricks are read: the service's Arrow socket and dtpipe's
# own `generate:1000`. Each has a pipeline armed and run twice with no restart, then once more after the service restarts.
#
#   bash src/ArrowSocketSource/run.sh
#   DTPIPE_VERSION=1.18.0 PORT=18080 bash src/ArrowSocketSource/run.sh
#   COORDINATOR_IMAGE=registry.example/dtpipe-coordinator:tag bash src/ArrowSocketSource/run.sh
#
# DTPIPE_VERSION names the node library, the dtpipe tool package and, unless COORDINATOR_IMAGE names an image in full, the tag
# of ghcr.io/nicopon/dtpipe-coordinator. Needs dotnet, docker or podman, curl and jq on the host; every package and the image
# come from public registries. Nothing outlives the script: the container is removed, the work directory too once the run
# succeeds (a failed run keeps it, for its logs).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DTPIPE_VERSION="${DTPIPE_VERSION:-1.18.0}"
COORDINATOR_IMAGE="${COORDINATOR_IMAGE:-ghcr.io/nicopon/dtpipe-coordinator:$DTPIPE_VERSION}"
PORT="${PORT:-18080}"
URL="http://127.0.0.1:$PORT"
NAME="dtpipe-arrow-socket-source-$$"
SOCKETS=/tmp
WORK=""
PIDS=()

say() { printf '\n== %s\n' "$*"; }
fail() {
  echo "FAIL: $*" >&2
  for log in coordinator runner service; do
    if [ -n "$WORK" ] && [ -f "$WORK/$log.log" ]; then echo "-- $log.log (tail)" >&2; tail -n 15 "$WORK/$log.log" >&2; fi
  done
  exit 1
}
# A signal is handled once the command it interrupted ends, inside that command's redirections: the cleanup writes to a copy of
# the script's own stderr.
exec 3>&2
cleanup() {
  local status=$?
  # A second signal must not cut the cleanup short.
  trap '' INT TERM
  if [ "$status" -ne 0 ] && [ -n "$WORK" ]; then echo "Work directory kept: $WORK" >&3; fi
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  [ -n "${RT:-}" ] && "$RT" rm -fv "$NAME" >/dev/null 2>&1 || true
  wait 2>/dev/null || true
  if [ "$status" -eq 0 ] && [ -n "$WORK" ]; then rm -rf "$WORK"; fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for tool in dotnet curl jq; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
if command -v docker >/dev/null 2>&1; then RT=docker
elif command -v podman >/dev/null 2>&1; then RT=podman
else fail "docker or podman is required"; fi
"$RT" info >/dev/null 2>&1 || fail "$RT is installed but its engine is not running"

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
# The container's user is 1654: it must be able to walk down to the seeds.
chmod 755 "$WORK"
cd "$WORK"
echo "Work directory: $WORK"

say "Build the service (dtpipe $DTPIPE_VERSION)"
dotnet build "$HERE/ArrowSocketSource.csproj" -c Release -p:DtPipeVersion="$DTPIPE_VERSION" -p:NodeHostVersion="$DTPIPE_VERSION" \
  -v q -nologo > build.log 2>&1 || { tail -n 30 build.log >&2; fail "the build failed"; }
SERVICE_EXE="$HERE/bin/Release/net10.0/ArrowSocketSource"
# The dtpipe the node runs, and the one that makes keys, starts the runner and witnesses the orders: the package the build
# downloaded, run through the dotnet host.
PACKAGES="${NUGET_PACKAGES:-$(dotnet nuget locals global-packages --list | sed 's/^global-packages: *//')}"
PACKAGES="${PACKAGES%/}"
TOOL="$(ls "$PACKAGES"/dtpipe/"$DTPIPE_VERSION"/tools/*/any/DtPipe.dll 2>/dev/null | head -1 || true)"
[ -f "$TOOL" ] || fail "the dtpipe $DTPIPE_VERSION package is not in the NuGet cache ($PACKAGES)"
echo "dtpipe of the node: $TOOL"
dtpipe() { dotnet "$TOOL" "$@"; }

say "Keys, rights and library"
# Everything the coordinator is seeded with sits in one folder, mounted read-only. The keys are 0644 on purpose: the image
# runs as uid 1654, and on Linux a bind-mounted key of mode 0600 owned by the host user is unreadable there. They open
# nothing outside this run.
SEED="$WORK/seed"
mkdir -p "$SEED/library"
for id in admin runner-1 shop; do dtpipe keygen "$id" --out "$SEED/$id.key" >/dev/null; done
# The matrix only: identities come with their keys from the bootstrap settings below.
cat > "$SEED/rights-seed.json" <<'EOF'
{ "identities": [], "matrix": { "data": ["runner", "data"], "runner": ["data"] } }
EOF
cat > "$SEED/library/api-orders-by-country.yaml" <<'EOF'
# Orders by country and status: reads the orders brick of the service's node (a .NET source on an Arrow socket),
# aggregates on the runner, writes through the node's report brick.
orders:
  input: brick:shop/orders
by-country:
  from: orders
  provider-options:
    sql:
      query: SELECT country, status, COUNT(*) AS orders, SUM(total) AS total FROM orders GROUP BY country, status ORDER BY country, status
write:
  from: by-country
  output: brick:shop/report
EOF
cat > "$SEED/library/generated-numbers.yaml" <<'EOF'
# Counts and sums the numbers brick (dtpipe's own generate source) on the runner.
numbers:
  input: brick:shop/numbers
total:
  from: numbers
  provider-options:
    sql:
      query: SELECT COUNT(*) AS n, SUM(GenerateIndex) AS total FROM numbers
write:
  from: total
  output: brick:shop/numbers-report
EOF
echo '{ "orders": { "mode": "strict" }, "write": { "mode": "strict" } }' > "$SEED/library/api-orders-by-country.bindings.json"
echo '{ "numbers": { "mode": "strict" }, "write": { "mode": "strict" } }' > "$SEED/library/generated-numbers.bindings.json"
chmod -R a+rX "$SEED"
chmod 644 "$SEED"/*.key
mkdir -p reports

say "Coordinator $COORDINATOR_IMAGE on $URL"
"$RT" image inspect "$COORDINATOR_IMAGE" >/dev/null 2>&1 || "$RT" pull -q "$COORDINATOR_IMAGE" >/dev/null || fail "cannot pull $COORDINATOR_IMAGE"
# The image listens on 8080 and keeps its state under /state, inside the container: --rm takes it away. The port is
# published on the loopback only, and the public address is the one the runner and the node use.
"$RT" run --rm --init --name "$NAME" -p "127.0.0.1:$PORT:8080" -v "$SEED:/seed:ro" \
  -e Coordinator__Initialize=true \
  -e Coordinator__PublicUrl="$URL" \
  -e Coordinator__Auth__AllowHttpKeys=true \
  -e Coordinator__Studio__ClientId=dtpipe-studio \
  -e Coordinator__LibrarySeed=/seed/library \
  -e Coordinator__RightsSeed=/seed/rights-seed.json \
  -e Coordinator__Bootstrap__AdminKey=@/seed/admin.key \
  -e Coordinator__Bootstrap__Identities__0__Id=runner-1 \
  -e Coordinator__Bootstrap__Identities__0__Name=runner-1 \
  -e Coordinator__Bootstrap__Identities__0__Groups__0=runner \
  -e Coordinator__Bootstrap__Identities__0__Key=@/seed/runner-1.key \
  -e Coordinator__Bootstrap__Identities__1__Id=shop \
  -e Coordinator__Bootstrap__Identities__1__Name=shop \
  -e Coordinator__Bootstrap__Identities__1__Groups__0=data \
  -e Coordinator__Bootstrap__Identities__1__Key=@/seed/shop.key \
  "$COORDINATOR_IMAGE" > coordinator.log 2>&1 &
COORDINATOR=$!
PIDS+=("$COORDINATOR")
for _ in $(seq 60); do
  kill -0 "$COORDINATOR" 2>/dev/null || fail "the coordinator container exited"
  curl -sf "$URL/.well-known/openid-configuration" >/dev/null && break
  sleep 1
done
curl -sf "$URL/.well-known/openid-configuration" >/dev/null || fail "the coordinator does not answer on $URL"

TOKEN=$(curl -sf "$URL/connect/token" -d grant_type=client_credentials -d client_id=admin \
  --data-urlencode "client_secret=$(cat "$SEED/admin.key")" | jq -r .access_token)
api() { local method=$1 path=$2; shift 2; curl -s -X "$method" "$URL/api$path" -H "Authorization: Bearer $TOKEN" \
  -H "X-Dtpipe-Csrf: 1" -H "Content-Type: application/json" "$@"; }
echo "flow matrix: $(api GET /flow-matrix | jq -c .groups)"

say "Runner"
mkdir -p runner
(cd runner && exec dotnet "$TOOL" node --runner --name runner-1 --coordinator "$URL" --client-secret "@$SEED/runner-1.key") > runner.log 2>&1 &
PIDS+=($!)

start_service() {
  # Started as its own executable, not through `dotnet`: the node finds the dotnet host from its runtime.
  "$SERVICE_EXE" node --coordinator "$URL" --name shop --key-file "$SEED/shop.key" --work "$WORK/shop" \
    --report-dir "$WORK/reports" --socket-dir "$SOCKETS" >> service.log 2>&1 &
  SERVICE=$!
  PIDS+=("$SERVICE")
}
wait_nodes() {
  for _ in $(seq 60); do
    local online; online=$(api GET /nodes | jq -r '[.[] | select(.online) | .name] | sort | join(",")')
    [ "$online" = "runner-1,shop" ] && { echo "online: $online"; return 0; }
    sleep 1
  done
  echo "nodes not online: $(api GET /nodes | jq -c '[.[] | {name, online}]')"; return 1
}
versions() { api GET /bricks | jq -c '[.[] | {id, version}] | sort_by(.id)'; }

say "Service (hosts the node 'shop')"
start_service
wait_nodes || fail "the runner and the service did not both come online"
BEFORE=$(versions)
echo "bricks: $(api GET /bricks | jq -c '[.[] | {node, id, kind, version}]')"
grep -h "runs dtpipe" service.log | sed -E 's/^[^ ]+ //'

say "Nothing of the socket reaches the coordinator"
if { api GET /nodes; api GET /bricks; api GET /library; } | grep -q "dtps-"; then fail "a socket path is visible to the coordinator"; fi
echo "no socket path in /nodes, /bricks or /library"

say "Previews"
echo "-- shop/orders"; api POST /bricks/shop/orders/preview | jq -r '.csv // .' | head -4
echo "-- shop/numbers"; api POST /bricks/shop/numbers/preview | jq -r '.csv // .' | head -4

say "Arm both pipelines"
for p in api-orders-by-country generated-numbers; do
  api POST "/library/$p/deploy" | jq -c '{pipelineId, error}' | cut -c1-300
done

run_once() {
  local label=$1 pipeline=$2 run state
  run=$(api POST /runs -d "{\"pipelineId\":\"$pipeline\"}" | jq -r .runId)
  for _ in $(seq 120); do
    state=$(api GET "/runs?pipeline=$pipeline" | jq -r --arg id "$run" '.[] | select(.runId == $id) | .state')
    case "$state" in succeeded|failed|cancelled|refused|error) break;; esac
    sleep 1
  done
  echo "$label: run $run $state"
  if [ "$state" != succeeded ]; then
    api GET "/runs?pipeline=$pipeline" | jq -c --arg id "$run" '.[] | select(.runId == $id) | {state, refusal, result}' | cut -c1-800
    return 1
  fi
}

check_orders() {
  # The same read, by the same dtpipe, straight from the service's socket.
  dtpipe -i "arrow:pipe://$SOCKETS/dtps-$SERVICE/orders.sock" --alias orders --from orders \
    --sql "SELECT country, status, COUNT(*) AS orders, SUM(total) AS total FROM orders GROUP BY country, status ORDER BY country, status" \
    -o "csv:$WORK/witness.csv" --no-stats >/dev/null 2>&1
  if diff -q "$WORK/witness.csv" reports/report.csv >/dev/null; then echo "$1: orders report identical to a read of the socket ($(($(wc -l < reports/report.csv) - 1)) rows)"
  else echo "$1: orders report differs from a read of the socket"; diff "$WORK/witness.csv" reports/report.csv | head -10; return 1; fi
}
check_numbers() {
  local got; got=$(tail -n +2 reports/numbers-report.csv | tr -d '\r')
  [ "$got" = "1000,499500" ] || fail "$1: numbers report is '$got', expected '1000,499500'"
  echo "$1: numbers report 1000 rows, sum 499500"
}
round() {
  rm -f reports/*.csv
  run_once "$1 orders" api-orders-by-country; check_orders "$1"
  run_once "$1 numbers" generated-numbers; check_numbers "$1"
}

say "Two rounds, no restart"
round "round 1"
round "round 2"

say "Service restarted, third round on the same armings"
kill "$SERVICE"; wait "$SERVICE" 2>/dev/null || true
sleep 2
start_service
wait_nodes || fail "the runner and the service did not both come online"
[ "$(versions)" = "$BEFORE" ] || fail "the bricks' versions changed with the restart: $BEFORE -> $(versions)"
echo "bricks' versions unchanged by the restart"
round "round 3"

say "Done"
