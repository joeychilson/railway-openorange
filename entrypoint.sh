#!/bin/sh
# Serves the Worker that openorange-build built, as a node of the Rivet Engine
# in RIVET_ENDPOINT. With arguments, it runs the orange CLI instead, as in
# `docker run IMAGE --version`.
set -eu

STATE=/opt/railway-openorange

# Nothing needs root at runtime. Drop it before anything else runs, and keep
# the environment, which holds the service's variables.
if [ "$(id -u)" = "0" ]; then
  HOME=/home/openorange
  export HOME
  exec setpriv --reuid=openorange --regid=openorange --init-groups --inh-caps=-all -- "$0" "$@"
fi

if [ "$#" -gt 0 ]; then
  exec orange "$@"
fi

if [ ! -f "$STATE/build.sh" ]; then
  echo "ERROR: this image has no Worker. Build one with openorange-build in your Dockerfile." >&2
  exit 1
fi

if [ -z "${RIVET_ENDPOINT:-}" ]; then
  cat >&2 <<'EOF'
ERROR: RIVET_ENDPOINT is not set.

Set it to the Rivet Engine's URL, such as
http://${{rivet-engine.RAILWAY_PRIVATE_DOMAIN}}:6420 on Railway, and set
RIVET_TOKEN to the Engine's RIVET__AUTH__ADMIN_TOKEN. The Railway template sets
both. RIVET_ENDPOINT can also carry them, as https://<namespace>:<token>@<host>.
EOF
  exit 1
fi

# Sets OPENORANGE_WORKDIR, OPENORANGE_NODE_VERSION, the variables the build
# needs, and the arguments for `orange`.
# shellcheck disable=SC1091
. "$STATE/build.sh"

# Durable Objects start only on nodes of the newest version, so each build's
# nodes take new and waking objects as soon as they connect.
RIVET_NODE_VERSION="${RIVET_NODE_VERSION:-$OPENORANGE_NODE_VERSION}"
export RIVET_NODE_VERSION

# Railway keeps a variable set to an empty value. orange serve would then use
# the namespace "", while bootstrap.mjs, like the template, means "default".
if [ -z "${RIVET_NAMESPACE:-}" ]; then
  unset RIVET_NAMESPACE
fi

# Waits for the Engine, checks its version, and creates the namespace and node
# pool when they don't exist yet. The Engine refuses a node whose pool is
# missing. It runs in the background so a stop while it waits for the Engine
# ends it at once: sh runs a trap only after a foreground command returns.
node "$STATE/bootstrap.mjs" &
bootstrap=$!
trap 'kill -TERM "$bootstrap" 2>/dev/null; exit 143' TERM INT
wait "$bootstrap"
trap - TERM INT

# Answers /cdn-cgi/railway/health on PORT before a request reaches the Worker.
NODE_OPTIONS="--import=$STATE/health.mjs${NODE_OPTIONS:+ $NODE_OPTIONS}"
export NODE_OPTIONS

cd "$OPENORANGE_WORKDIR"
# "::" also accepts IPv4, so the Worker answers on Railway's public edge and on
# its private network, which is IPv6-only in older environments. tini passes
# SIGTERM to orange serve, which puts each Durable Object to sleep before it
# exits, and reaps the processes OpenOrange starts. Railway runs its own init
# as PID 1, so -s makes tini a subreaper, which reaps whether or not it is PID 1.
exec tini -s -- orange "$@" --ip "::"
