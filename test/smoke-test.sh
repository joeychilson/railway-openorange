#!/usr/bin/env bash
# Runs the image as a node of the Rivet Engine release its Dockerfile pins, on
# a private Docker network: CLI passthrough, the configuration and Engine
# checks, the health route, the starter's Durable Object across a restart, an
# Engine outage, and a deploy that overlaps the old node, Worker variables, the
# node pool and version, the unprivileged runtime, graceful stop, and
# openorange-build on the Workers in test/fixtures, one of them built from
# examples/Dockerfile and its .dockerignore.
set -euo pipefail

IMAGE="${1:-railway-openorange:test}"
NAME="openorange-smoke-$$"
ENGINE="$NAME-engine"
LOG="$(mktemp)"
NEXT="$(mktemp -d)"
LOADER="$(mktemp -d)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOKEN="smoke-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
ENDPOINT="http://$ENGINE:6420"
# Builds go through the Docker driver of the current context, the one builder
# that sees $IMAGE in the local image store.
BUILDER="$(docker context show)"
CONTAINERS=("$NAME" "$ENGINE" "$NAME-waiting" "$NAME-old-engine" "$NAME-app" "$NAME-next" "$NAME-worker" "$NAME-loader")

current="$NAME"
cleanup() {
  docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1 || true
  docker image rm -f "$NAME-next" "$NAME-worker" "$NAME-loader" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
  rm -rf "$LOG" "$NEXT" "$LOADER"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  docker logs "$current" 2>&1 | tail -80 >&2 || true
  exit 1
}
pass() { echo "  ok: $*"; }

# Output is matched from a variable or $LOG, never piped into grep -q: grep
# exits at the first match, and pipefail fails the writer it cut off.

# The host port Docker published for a container port, which a restart changes.
url() { echo "http://$(docker port "$1" "$2/tcp" | head -1)"; }

# Runs the image once, expecting it to exit 1 with a message in $LOG.
refuses() {
  local rc
  set +e
  docker run --rm --network "$NAME" "$@" "$IMAGE" >"$LOG" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || { cat "$LOG" >&2; fail "exited $rc, expected 1"; }
}

wait_healthy() {
  local _
  for _ in $(seq 1 120); do
    [[ "$(curl -fsS "$(url "$1" 8080)/cdn-cgi/railway/health" 2>/dev/null || true)" == *'"status":"ok"'* ]] && return 0
    [[ "$(docker inspect --format '{{.State.Running}}' "$1")" == "true" ]] || fail "$1 exited"
    sleep 1
  done
  fail "$1 did not become healthy"
}

# Requests a path until it answers 2xx, for the seconds after the Engine comes
# back, then matches the answer once. Each visit counts, so a request that
# answered is never repeated.
expect_body() {
  local path="$1" want="$2" body="" _
  for _ in $(seq 1 60); do
    if body="$(curl -fsS "$(url "$current" 8080)$path" 2>&1)"; then
      [[ "$body" == *"$want"* ]] || fail "$path answered '$body', expected '$want'"
      return 0
    fi
    sleep 1
  done
  fail "$path kept failing: $body"
}

engine_api() {
  curl -fsS -H "Authorization: Bearer $TOKEN" "$(url "$ENGINE" 6420)$1"
}

# A node with $TOKEN and Railway's replica variables.
start_node() {
  local container="$1" image="$2"
  shift 2
  docker run -d --name "$container" --network "$NAME" -p 127.0.0.1::8080 \
    -e RIVET_ENDPOINT="$ENDPOINT" -e RIVET_TOKEN="$TOKEN" "$@" "$image" >/dev/null
  current="$container"
  wait_healthy "$container"
}

echo "==> upstream CLI"
expected="$(sed -n 's/^ARG OPEN_ORANGE_VERSION=//p' "$ROOT/Dockerfile")"
version="$(docker run --rm "$IMAGE" --version)"
[[ "$version" == *"$expected"* ]] || fail "expected OpenOrange $expected, got: $version"
pass "orange $version"
[[ "$(docker run --rm "$IMAGE" --help)" == *serve* ]] || fail "orange --help does not list serve"
pass "arguments run the orange CLI"

echo "==> configuration"
docker network create "$NAME" >/dev/null
refuses
grep -q 'RIVET_ENDPOINT is not set' "$LOG" || fail "missing RIVET_ENDPOINT error was not actionable"
pass "a node without RIVET_ENDPOINT fails closed"
refuses -e RIVET_ENDPOINT="$ENDPOINT"
grep -q 'RIVET_TOKEN is not set' "$LOG" || fail "missing RIVET_TOKEN error was not actionable"
pass "a node without RIVET_TOKEN fails closed"
refuses -e RIVET_ENDPOINT=rivet-engine.railway.internal:6420 -e RIVET_TOKEN="$TOKEN"
grep -q 'not an http or https URL' "$LOG" || { cat "$LOG" >&2; fail "an endpoint without a scheme was not reported"; }
pass "a RIVET_ENDPOINT without http:// fails at once"

# A node waits up to three minutes for the Engine, but a stop ends the wait.
current="$NAME-waiting"
docker run -d --name "$NAME-waiting" --network "$NAME" \
  -e RIVET_ENDPOINT="http://$NAME-nowhere:6420" -e RIVET_TOKEN="$TOKEN" "$IMAGE" >/dev/null
for _ in $(seq 1 30); do
  docker logs "$NAME-waiting" >"$LOG" 2>&1
  grep -q 'waiting for the Rivet Engine' "$LOG" && break
  sleep 1
done
grep -q 'waiting for the Rivet Engine' "$LOG" || fail "the node did not wait for a missing Engine"
started=$SECONDS
docker stop --time 30 "$NAME-waiting" >/dev/null
stopped=$((SECONDS - started))
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$NAME-waiting")"
((stopped < 10)) || fail "stopping a node that waits for the Engine took $stopped s"
[[ "$exit_code" == "143" ]] || fail "a node stopped while it waits exited $exit_code, expected 143"
pass "a node that waits for the Engine stops at once"
docker rm -f "$NAME-waiting" >/dev/null

echo "==> Rivet Engine"
engine_version="$(sed -n 's/^ARG RIVET_ENGINE_VERSION=//p' "$ROOT/Dockerfile")"
# Configured as the template configures it, with local object storage in place
# of the Railway Bucket.
docker run -d --name "$ENGINE" --network "$NAME" -p 127.0.0.1::6420 \
  -e RIVET__AUTH__ADMIN_TOKEN="$TOKEN" \
  -e RIVET__TELEMETRY__ENABLED=false \
  -e RIVET__STORAGE__LOG_DIRECTORY=/var/lib/rivet/log \
  -e RIVET__STORAGE__AUTO_PROVISION_PARTITIONS=1 \
  -e RIVET__STORAGE__BALANCING__ENABLED=false \
  -e RIVET__OBJECT_STORAGE__PRIMARY__FILE_SYSTEM__PATH=/var/lib/rivet/objects \
  --entrypoint sh "rivetdev/engine:$engine_version" \
  -c 'mkdir -p /var/lib/rivet/log && exec /usr/bin/rivet-engine' >/dev/null
current="$ENGINE"
health=""
for _ in $(seq 1 60); do
  health="$(curl -fsS "$(url "$ENGINE" 6420)/health" 2>/dev/null || true)"
  [[ "$health" == *'"status":"ok"'* ]] && break
  sleep 1
done
[[ "$health" == *"\"version\":\"$engine_version\""* ]] || fail "Engine health answered: $health"
pass "Rivet Engine $engine_version"

refuses -e RIVET_ENDPOINT="$ENDPOINT" -e RIVET_TOKEN=wrong
grep -q 'refused RIVET_TOKEN' "$LOG" || { cat "$LOG" >&2; fail "a wrong RIVET_TOKEN was not reported"; }
pass "a node with the wrong RIVET_TOKEN fails closed"

# An Engine older than the image's RivetKit, as far as its /health tells.
docker run -d --name "$NAME-old-engine" --network "$NAME" --entrypoint node "$IMAGE" -e '
  require("node:http").createServer((request, response) => {
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ status: "ok", version: "2.0.0" }));
  }).listen(6420);
' >/dev/null
refuses -e RIVET_ENDPOINT="http://$NAME-old-engine:6420" -e RIVET_TOKEN="$TOKEN"
grep -q 'Upgrade the Engine first' "$LOG" || { cat "$LOG" >&2; fail "an old Engine was not refused"; }
pass "a node refuses an Engine older than its RivetKit"

echo "==> starter Worker"
start_node "$NAME" "$IMAGE" \
  -e ORANGE_WORKER_VARS=RAILWAY_REPLICA_ID,RAILWAY_REPLICA_REGION \
  -e RAILWAY_REPLICA_ID=smoke-replica -e RAILWAY_REPLICA_REGION=smoke-region
pass "/cdn-cgi/railway/health is healthy"

expect_body /api/visit '{"visits":1,"replica":"smoke-replica","region":"smoke-region"}'
expect_body /api/visit '"visits":2,'
pass "the Durable Object counts, and ORANGE_WORKER_VARS reach the Worker"
# The page counts a visit too.
expect_body / '<span>Visits</span><strong>3</strong>'
status="$(curl -s -o /dev/null -w '%{http_code}' "$(url "$NAME" 8080)/missing")"
[[ "$status" == "404" ]] || fail "/missing answered $status"
pass "requests reach the Worker"

docker logs "$NAME" >"$LOG" 2>&1
grep -q 'created node pool default in namespace default' "$LOG" || fail "the node did not create pool default"
node_version="$(docker exec "$NAME" sh -c '. /opt/railway-openorange/build.sh && echo "$OPENORANGE_NODE_VERSION"')"
nodes="$(engine_api '/pools/default/nodes?namespace=default')"
[[ "$nodes" == *"\"version\":$node_version"* && "$nodes" == *'"connected":true'* ]] \
  || fail "the Engine lists no connected node of version $node_version: $nodes"
pass "the node joins pool default as version $node_version, its build's"

[[ "$(docker exec "$NAME" cat /proc/1/comm)" == "tini" ]] || fail "PID 1 is not tini"
uids="$(docker exec -u 10001 "$NAME" sh -c "awk '/^Uid:/ { print \$2 }' /proc/[0-9]*/status | sort -u")"
[[ "$uids" == "10001" ]] || fail "processes run as UIDs $uids, expected only 10001"
pass "every process runs as UID 10001 under tini"

echo "==> graceful stop and restart"
docker stop --time 60 "$NAME" >/dev/null
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$NAME")"
[[ "$exit_code" == "0" ]] || fail "SIGTERM stop exited $exit_code"
pass "SIGTERM reaches orange serve and it exits cleanly"
docker start "$NAME" >/dev/null
wait_healthy "$NAME"
expect_body /api/visit '"visits":4,'
pass "the Durable Object keeps its data across a restart"

echo "==> Engine outage"
docker stop "$ENGINE" >/dev/null
body=""
for _ in $(seq 1 15); do
  body="$(curl -s "$(url "$NAME" 8080)/cdn-cgi/railway/health" || true)"
  [[ "$body" == *'Rivet Engine unreachable'* ]] && break
  sleep 1
done
[[ "$body" == *'Rivet Engine unreachable'* ]] || fail "health answered '$body' with the Engine down"
status="$(curl -s -o /dev/null -w '%{http_code}' "$(url "$NAME" 8080)/cdn-cgi/railway/health")"
[[ "$status" == "503" ]] || fail "health answered $status with the Engine down, expected 503"
pass "health answers 503 while the Engine is down"
docker start "$ENGINE" >/dev/null
wait_healthy "$NAME"
expect_body /api/visit '"visits":5,'
pass "the node reconnects when the Engine is back"

echo "==> namespaces"
refuses -e RIVET_ENDPOINT="$ENDPOINT" -e RIVET_TOKEN="$TOKEN" -e RIVET_NAMESPACE=Not_A_Label
grep -q 'refused namespace Not_A_Label' "$LOG" || { cat "$LOG" >&2; fail "an invalid RIVET_NAMESPACE was not reported"; }
pass "an invalid RIVET_NAMESPACE fails closed"
start_node "$NAME-app" "$IMAGE" -e RIVET_NAMESPACE=smoke-app
docker logs "$NAME-app" >"$LOG" 2>&1
grep -q 'created namespace smoke-app' "$LOG" || fail "the node did not create namespace smoke-app"
expect_body /api/visit '"visits":1,'
nodes="$(engine_api '/pools/default/nodes?namespace=smoke-app')"
[[ "$nodes" == *'"connected":true'* ]] || fail "no node in namespace smoke-app: $nodes"
pass "a new RIVET_NAMESPACE is created, with Durable Objects of its own"
docker rm -f "$NAME-app" >/dev/null
current="$NAME"

echo "==> a new build"
# The starter with changed code. Durable Objects belong to the Worker's name
# and Wrangler environment, so the new build reaches the same Counter. Its
# files are readable only by their owner, as under umask 077.
cp -R "$ROOT/starter/." "$NEXT/"
sed -i.orig 's/return Response.json(visit);/return Response.json({ ...visit, build: "next" });/' "$NEXT/src/index.ts"
rm "$NEXT/src/index.ts.orig"
grep -q 'build: "next"' "$NEXT/src/index.ts" || fail "could not change the starter for the new build"
find "$NEXT" -type f -exec chmod 600 {} +
current="$NAME-next"
docker buildx build --builder "$BUILDER" --progress=plain --load -t "$NAME-next" -f - "$NEXT" >"$LOG" 2>&1 <<EOF || { tail -60 "$LOG" >&2; fail "the new build failed"; }
FROM $IMAGE
COPY . .
RUN openorange-build
EOF
pass "a project whose files only their owner can read builds"
# As in a Railway deploy, the new node starts while the old one serves, and
# both reach the same Counter until the old one stops.
start_node "$NAME-next" "$NAME-next"
expect_body /api/visit '{"visits":6,"replica":"local","region":"local","build":"next"}'
current="$NAME"
expect_body /api/visit '{"visits":7,"replica":"smoke-replica","region":"smoke-region"}'
pass "old and new nodes serve the same Durable Object while they overlap"
docker stop --time 60 "$NAME" >/dev/null
current="$NAME-next"
expect_body /api/visit '{"visits":8,"replica":"local","region":"local","build":"next"}'
pass "the new build keeps the Durable Object once the old node stops"
docker rm -f "$NAME" "$NAME-next" >/dev/null

echo "==> openorange-build"
set +e
docker run --rm --user 0 --entrypoint openorange-build "$IMAGE" /app >"$LOG" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]] || ! grep -q 'where the built Worker goes' "$LOG"; then
  cat "$LOG" >&2
  fail "openorange-build built a project copied over /app"
fi
pass "a project in /app is refused"

set +e
docker run --rm --user 0 --entrypoint sh "$IMAGE" -c '
  mkdir /tmp/berry && cd /tmp/berry \
    && echo "{}" > package.json && : > yarn.lock && : > .yarnrc.yml \
    && echo "{\"name\": \"berry\", \"main\": \"index.js\"}" > wrangler.json \
    && exec openorange-build' >"$LOG" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 1 ]] || ! grep -q "doesn't say which Yarn" "$LOG"; then
  cat "$LOG" >&2
  fail "a Yarn 2 project without packageManager was not reported"
fi
pass "a Yarn 2 project without a packageManager version is refused"

current="$NAME-worker"
docker buildx build --builder "$BUILDER" --progress=plain --load -t "$NAME-worker" \
  -f - "$ROOT/test/fixtures/worker" >"$LOG" 2>&1 <<EOF || { tail -60 "$LOG" >&2; fail "the worker fixture did not build"; }
FROM $IMAGE
COPY . .
RUN openorange-build --env smoke
EOF
docker run --rm --entrypoint sh "$NAME-worker" -c 'test ! -e /src/node_modules && test ! -e /app/node_modules' \
  || fail "node_modules stayed in the image"
pass "wrangler.toml, npm packages, build.command, and --env build without leaving node_modules"
start_node "$NAME-worker" "$NAME-worker" -e ORANGE_WORKER_SECRETS=SMOKE_SECRET -e SMOKE_SECRET=smoke-secret-value
expect_body / '{"built":"by build.command","greeting":"hello from env.smoke","dependency":172800000,"secret":true,"engineToken":false}'
pass "the Worker gets ORANGE_WORKER_SECRETS but not the Engine's token"
docker rm -f "$NAME-worker" >/dev/null

# The loader fixture, with the example's Dockerfile and .dockerignore and the
# local files a project has, which must stay out of the image.
current="$NAME-loader"
cp -R "$ROOT/test/fixtures/loader/." "$LOADER/"
sed "s|^FROM .*|FROM $IMAGE|" "$ROOT/examples/Dockerfile" >"$LOADER/Dockerfile"
cp "$ROOT/examples/.dockerignore" "$LOADER/.dockerignore"
echo "SMOKE_LOCAL_SECRET=1" >"$LOADER/.dev.vars"
echo "SMOKE_LOCAL_SECRET=1" >"$LOADER/.env.local"
mkdir -p "$LOADER/node_modules/smoke-local"
docker buildx build --builder "$BUILDER" --progress=plain --load -t "$NAME-loader" \
  "$LOADER" >"$LOG" 2>&1 || { tail -60 "$LOG" >&2; fail "the loader fixture did not build"; }
grep -q 'installing OpenOrange packages for this Worker: @rivet-dev/agentos-core' "$LOG" \
  || { tail -60 "$LOG" >&2; fail "openorange-build did not add agentOS for a Worker Loader"; }
docker run --rm --entrypoint sh "$NAME-loader" -c \
  'test -f /src/wrangler.jsonc && test ! -e /src/.dev.vars && test ! -e /src/.env.local && test ! -e /src/node_modules' \
  || fail "examples/.dockerignore let local files into /src"
pass "examples/.dockerignore keeps .dev.vars, .env files, and node_modules out of the image"
start_node "$NAME-loader" "$NAME-loader"
expect_body / 'hello from a dynamic worker'
pass "examples/Dockerfile builds a Worker Loader Worker with the packages it needs"

echo
echo "All smoke tests passed."
