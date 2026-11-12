#!/usr/bin/env bash
# Builds a Wrangler project into the Worker this image serves, the way
# `orange deploy` builds its images. Run it as the last step of a Dockerfile
# that starts FROM this image, whose working directory is an empty /src:
#
#   COPY . .
#   RUN openorange-build
#
# It installs the project's packages with its own package manager, runs the
# Wrangler `build.command` if there is one, bundles the Worker's packages into
# its entry file with `orange deploy --dry-run`, and replaces /app with the
# result. The result has no node_modules, .git, .env, .dev.vars, or
# .open-orange, so local secrets never reach /app, and the node_modules it
# installed for the build are removed again. A Worker with a Sandbox or Worker
# Loader binding also gets the OpenOrange packages those need. Each build
# stamps a new RIVET_NODE_VERSION, so new Durable Objects start on the newest
# deploy.
set -euo pipefail

STATE=/opt/railway-openorange
ORANGE=/opt/openorange
APP=/app

usage() {
  cat <<'EOF'
Usage: openorange-build [options] [project-directory]

Builds the Wrangler project in project-directory (default: the current
directory, /src in this image) into /app.

Options:
  -c, --config <path>  Wrangler configuration file, relative to the project
  -e, --env <name>     Wrangler environment to build, as in `wrangler deploy -e`
      --no-install     Don't install packages; run your own install first
  -h, --help           Show this help
EOF
}

fail() {
  echo "openorange-build: $*" >&2
  exit 1
}

config=""
environment=""
install=1
project=""
while (($#)); do
  case "$1" in
    -c | --config) config="${2:?--config needs a path}"; shift 2 ;;
    --config=*) config="${1#*=}"; shift ;;
    -e | --env) environment="${2:?--env needs a name}"; shift 2 ;;
    --env=*) environment="${1#*=}"; shift ;;
    --no-install) install=0; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; fail "unknown option $1" ;;
    *)
      [[ -z "$project" ]] || fail "takes one project directory, not '$project' and '$1'"
      project="$1"
      shift
      ;;
  esac
done

[[ "$(id -u)" == "0" ]] || fail "must run as root, the Dockerfile's default user"
project="$(cd "${project:-$PWD}" && pwd)"
# /app holds the built Worker, the starter until this build replaces it. A
# project copied over it would build with whatever of the starter it doesn't
# overwrite, such as its wrangler.jsonc next to your wrangler.toml.
if [[ "$project" == "$APP" || "$project" == "$APP/"* ]]; then
  fail "the project is in $APP, where the built Worker goes. Copy it to /src, the image's working directory, with COPY . . in your Dockerfile."
fi
if [[ ! -f "$project/wrangler.jsonc" && ! -f "$project/wrangler.json" && ! -f "$project/wrangler.toml" && -z "$config" ]]; then
  fail "no wrangler.jsonc, wrangler.json, or wrangler.toml in $project. Copy your Worker project into it, or pass --config."
fi

work="$(mktemp -d /tmp/openorange-build.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# The package manager comes from the lockfile, then from package.json's
# packageManager field. A packageManager version is used as pinned, except for
# npm: the image's npm installs from any lockfile npm 7 or later wrote.
install_packages() {
  [[ -f package.json ]] || return 0

  local spec pm version lockfile=1
  spec="$(node -p 'require("./package.json").packageManager ?? ""')"
  if [[ -f bun.lock || -f bun.lockb ]]; then
    pm=bun
  elif [[ -f pnpm-lock.yaml ]]; then
    pm=pnpm
  elif [[ -f yarn.lock ]]; then
    pm=yarn
  elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    pm=npm
  else
    pm="${spec%%@*}"
    pm="${pm:-npm}"
    lockfile=0
  fi
  version=""
  if [[ "$spec" == "$pm@"* && "$pm" != npm ]]; then
    version="${spec#*@}"
    version="${version%%+*}"
  fi

  echo "openorange-build: installing packages with $pm${version:+ $version}"
  # The image sets NODE_ENV=production, which would skip devDependencies. A
  # Worker's build and bundle often need them, and none reach the image.
  case "$pm" in
    npm)
      if ((lockfile)); then
        NODE_ENV=development npm ci --no-audit --no-fund
      else
        NODE_ENV=development npm install --no-audit --no-fund
      fi
      ;;
    pnpm)
      if [[ -n "$version" ]]; then
        set -- npx --yes "pnpm@$version"
      else
        set -- pnpm
      fi
      if ((lockfile)); then
        NODE_ENV=development "$@" install --frozen-lockfile
      else
        NODE_ENV=development "$@" install
      fi
      ;;
    yarn)
      if [[ "$version" == 1.* ]] || [[ -z "$version" && ! -f .yarnrc.yml ]]; then
        set -- npx --yes "yarn@${version:-1}" install
        if ((lockfile)); then
          set -- "$@" --frozen-lockfile
        fi
      else
        # Yarn 2 and later, which .yarnrc.yml configures. Corepack runs the
        # version packageManager pins. Older projects pin it with yarnPath.
        local yarnpath
        yarnpath=""
        if [[ -f .yarnrc.yml ]]; then
          yarnpath="$(sed -n 's/^yarnPath:[[:space:]]*//p' .yarnrc.yml | tr -d "\"'" | sed -n 1p)"
        fi
        if [[ -z "$version" && -n "$yarnpath" ]]; then
          set -- node "$yarnpath" install
        elif [[ -z "$version" ]]; then
          fail "this project has .yarnrc.yml, for Yarn 2 or later, but doesn't say which Yarn. Add \"packageManager\": \"yarn@<version>\" to package.json, or install the packages yourself and pass --no-install."
        else
          command -v corepack >/dev/null || fail "Yarn $version needs Corepack, which this Node.js doesn't include"
          set -- env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn install
        fi
        if ((lockfile)); then
          set -- "$@" --immutable
        fi
      fi
      NODE_ENV=development "$@"
      ;;
    bun)
      set -- npx --yes "bun@${version:-latest}"
      if ((lockfile)); then
        NODE_ENV=development "$@" install --frozen-lockfile
      else
        NODE_ENV=development "$@" install
      fi
      ;;
    *)
      fail "packageManager names '$pm', which openorange-build can't install with. Install the packages yourself and pass --no-install."
      ;;
  esac
}

cd "$project"
# What the build adds to the project, to take out of the image again after.
created=()
for name in node_modules .open-orange .pnp.cjs .pnp.loader.mjs .yarn/cache .yarn/unplugged .yarn/install-state.gz; do
  [[ -e "$name" ]] || created+=("$project/$name")
done
if ((install)); then
  install_packages
fi

# The same build `orange deploy` makes, without Docker or Rivet Cloud. It runs
# build.command, bundles, and writes Dockerfile and context/ to the outdir.
echo "openorange-build: bundling the Worker"
args=(deploy --dry-run --outdir "$work/out")
[[ -n "$config" ]] && args+=(--config "$config")
[[ -n "$environment" ]] && args+=(--env "$environment")
orange "${args[@]}" >/dev/null

# Record how to serve this build, from the Dockerfile OpenOrange generated:
# the command, the working directory, the variables it sets, and a version
# for RIVET_NODE_VERSION that grows with every build.
node - "$work/out/Dockerfile" "$STATE/build.sh" "$APP" <<'EOF'
const fs = require("node:fs");
const [dockerfile, output, app] = process.argv.slice(2);
const lines = fs.readFileSync(dockerfile, "utf8").split("\n");
if (!lines[0].startsWith("# Generated by orange deploy")) {
  throw new Error(`${dockerfile} is not a Dockerfile from orange deploy`);
}
const cmd = lines.find((line) => line.startsWith("CMD "));
const command = cmd === undefined ? undefined : JSON.parse(cmd.slice(4));
if (!Array.isArray(command) || command[0] !== "orange" || command[1] !== "serve") {
  throw new Error(`The generated Dockerfile runs ${cmd ?? "nothing"}, not orange serve`);
}
// The second stage starts at /app. A later WORKDIR holds the project when
// its entry file sits outside it.
const workdirs = lines.filter((line) => line.startsWith("WORKDIR "));
let workdir = workdirs.at(-1)?.slice(8) ?? "/app";
if (workdir !== "/app" && !workdir.startsWith("/app/")) workdir = "/app";
const env = {};
for (const line of lines.filter((line) => line.startsWith("ENV "))) {
  for (const pair of line.slice(4).split(/\s+/)) {
    const at = pair.indexOf("=");
    const name = pair.slice(0, at);
    if (at > 0 && name !== "NODE_ENV" && name !== "PORT") env[name] = pair.slice(at + 1);
  }
}
const quote = (value) => `'${String(value).replaceAll("'", `'\\''`)}'`;
const script = [
  `# Written by openorange-build on ${new Date().toISOString()}. The entrypoint reads it.`,
  `OPENORANGE_WORKDIR=${quote(app + workdir.slice(4))}`,
  `OPENORANGE_NODE_VERSION=${quote(Math.floor(Date.now() / 1000))}`,
  ...Object.entries(env).map(([name, value]) => `export ${name}=${quote(value)}`),
  `set -- ${command.slice(1).map(quote).join(" ")}`,
  "",
].join("\n");
fs.mkdirSync(require("node:path").dirname(output), { recursive: true });
fs.writeFileSync(output, script);
EOF

# A Sandbox or Worker Loader binding needs agentOS or the sandbox providers,
# which the image leaves out. Install what this Worker's build asks for from
# the lockfile OpenOrange wrote for it, then put back the full package.json,
# which OpenOrange reads to plan the next build.
# shellcheck disable=SC2016 # ${...} below is JavaScript.
missing="$(node -e '
  const deps = Object.keys(require(process.argv[1]).dependencies ?? {});
  const fs = require("node:fs");
  console.log(deps.filter((name) => !fs.existsSync(`${process.argv[2]}/node_modules/${name}`)).join(" "));
' "$work/out/context/orange/package.json" "$ORANGE")"
if [[ -n "$missing" ]]; then
  echo "openorange-build: installing OpenOrange packages for this Worker: $missing"
  cp "$ORANGE/package.json" "$work/package.full.json"
  node -e '
    const fs = require("node:fs");
    const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    delete pkg.pnpm;
    fs.writeFileSync(process.argv[2], JSON.stringify(pkg, null, 2) + "\n");
  ' "$work/out/context/orange/package.json" "$ORANGE/package.json"
  cp "$work/out/context/orange/pnpm-lock.yaml" "$ORANGE/pnpm-lock.yaml"
  (cd "$ORANGE" && pnpm install --frozen-lockfile --prod --ignore-scripts --reporter=append-only)
  cp "$work/package.full.json" "$ORANGE/package.json"
  rm -f "$ORANGE/pnpm-lock.yaml"
fi

# Replace /app with the build. The runtime keeps the deployment's identity in
# .open-orange, so that one directory belongs to the user the Worker runs as.
cd /
rm -rf "$APP"
mkdir -p "$APP"
cp -a "$work/out/context/worker/." "$APP/"
# cp -a keeps the project's modes, and the Worker runs as openorange, not as
# the files' owner. A file only its owner could read would stop it starting.
chmod -R a+rX,go-w "$APP"
# shellcheck disable=SC1091
workdir="$(. "$STATE/build.sh" && echo "$OPENORANGE_WORKDIR")"
mkdir -p "$workdir/.open-orange"
chown -R openorange:openorange "$workdir/.open-orange"

# The packages installed for the build and the package managers' caches would
# otherwise stay in this layer. None of them is needed to serve the Worker.
rm -rf "${created[@]}" /root/.npm /root/.cache /root/.local/share/pnpm /root/.bun /root/.yarn \
  /usr/local/share/.cache /root/.config/.wrangler

echo "openorange-build: built the Worker into $workdir"
