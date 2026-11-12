# OpenOrange for Railway: the OpenOrange runtime that serves a Cloudflare Worker
# as a node of a Rivet Engine, with a starter Worker built in. It is also the
# base image for your own Worker, as in examples/Dockerfile:
#
#   FROM ghcr.io/joeychilson/railway-openorange:X.Y
#   COPY . .
#   RUN openorange-build
#
# Layout:
#   /opt/openorange          the open-orange package and its runtime dependencies
#   /opt/railway-openorange  the entrypoint's helpers and what openorange-build
#                            recorded about the Worker
#   /src                     the working directory, empty, for your project
#   /app                     the built Worker: the starter, or yours

# renovate: datasource=docker packageName=node depName=Node.js depType=tool
ARG NODE_VERSION=24.22.3-trixie-slim@sha256:af02d57b57719b9657a45199a79264a9437940cd55b3c7b3fc99615654f124a0

# The open-orange package from npm, with the full dependency tree from the
# lockfile it ships (dist/image/pnpm-lock.yaml), which is the tree its releases
# are tested with. This stage only runs `orange deploy --dry-run` on the
# starter to learn which of those dependencies a Worker without Sandbox or
# Worker Loader bindings needs; the final stage installs just those, as the
# images `orange deploy` builds do.
FROM node:${NODE_VERSION} AS package

# renovate: datasource=npm packageName=open-orange depName=OpenOrange
ARG OPEN_ORANGE_VERSION=1.0.1

WORKDIR /opt/openorange
RUN npm pack --silent "open-orange@${OPEN_ORANGE_VERSION}" \
    && tar -xzf "open-orange-${OPEN_ORANGE_VERSION}.tgz" --strip-components=1 --no-same-owner \
    && rm "open-orange-${OPEN_ORANGE_VERSION}.tgz" \
    && node -e ' \
      const fs = require("node:fs"); \
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8")); \
      const keep = ["name", "version", "type", "packageManager", "engines", "bin", "license", "dependencies"]; \
      fs.writeFileSync("package.json", JSON.stringify(Object.fromEntries(keep.filter((k) => k in pkg).map((k) => [k, pkg[k]])), null, 2) + "\n"); \
    ' \
    && cp dist/image/pnpm-lock.yaml pnpm-lock.yaml \
    && npm install --global --no-audit --no-fund --loglevel=error "$(node -p 'require("./package.json").packageManager')" \
    && pnpm install --frozen-lockfile --prod --ignore-scripts --reporter=append-only \
    && ln -s /opt/openorange/dist/bin.js /usr/local/bin/orange \
    && orange --version | grep -F "${OPEN_ORANGE_VERSION}"

COPY starter/ /tmp/starter/
RUN cd /tmp/starter && orange deploy --dry-run --outdir /tmp/deploy >/dev/null

FROM node:${NODE_VERSION}

# The Rivet Engine release this image is tested against, and the one the
# template deploys. The entrypoint refuses an Engine whose X.Y is older than
# the RivetKit that OpenOrange uses.
# renovate: datasource=docker packageName=rivetdev/engine depName=rivet-engine versioning=semver
ARG RIVET_ENGINE_VERSION=3.1.1
# The oldest Engine X.Y that every release of this major version runs on.
# Deployments get patch releases of both images automatically, so their Engine
# stays on one X.Y. An OpenOrange whose RivetKit needs a newer Engine fails
# this build until this is raised by hand, in a new major release.
ARG RIVET_ENGINE_MINIMUM=3.1

# tini reaps the processes OpenOrange starts and passes SIGTERM on, so nodes
# drain on every deploy. setpriv, from util-linux, drops root at startup.
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 openorange \
    && useradd --uid 10001 --gid 10001 --create-home --home-dir /home/openorange \
         --shell /usr/sbin/nologin openorange

# Install the dependencies the dry run picked, without the lockfile's x64-only
# filter, so arm64 gets its own native builds. package.json then goes back to
# the full list, which openorange-build compares against a Worker's needs.
COPY --from=package /tmp/deploy/context/orange/package.json /tmp/deploy/context/orange/pnpm-lock.yaml /opt/openorange/
WORKDIR /opt/openorange
RUN node -e ' \
      const fs = require("node:fs"); \
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8")); \
      delete pkg.pnpm; \
      fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n"); \
    ' \
    && npm install --global --no-audit --no-fund --loglevel=error "$(node -p 'require("./package.json").packageManager')" \
    && pnpm install --frozen-lockfile --prod --ignore-scripts --reporter=append-only \
    && rm pnpm-lock.yaml \
    && npm cache clean --force \
    && rm -rf /root/.cache /root/.local/share/pnpm
COPY --from=package /opt/openorange/package.json /opt/openorange/package.json
COPY --from=package /opt/openorange/dist /opt/openorange/dist
COPY --from=package /opt/openorange/LICENSE /opt/openorange/README.md /opt/openorange/
RUN ln -s /opt/openorange/dist/bin.js /usr/local/bin/orange \
    && orange --version

COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-openorange-entrypoint
COPY --chmod=755 openorange-build.sh /usr/local/bin/openorange-build
COPY bootstrap.mjs health.mjs /opt/railway-openorange/
RUN echo "${RIVET_ENGINE_VERSION}" > /opt/railway-openorange/tested-engine-version \
    && node -e ' \
      const [minimum, tested] = process.argv.slice(1); \
      const rivetkit = require("/opt/openorange/node_modules/rivetkit/package.json").version; \
      const xy = (version) => version.split(".").slice(0, 2).map(Number); \
      const newer = (a, b) => a[0] - b[0] || a[1] - b[1]; \
      if (newer(xy(rivetkit), xy(minimum)) > 0) { \
        console.error(`RivetKit ${rivetkit} needs Rivet Engine ${xy(rivetkit).join(".")}, newer than RIVET_ENGINE_MINIMUM ${minimum}. Raising it is a breaking change: release it as a new major version.`); \
        process.exit(1); \
      } \
      if (newer(xy(tested), xy(minimum)) < 0) { \
        console.error(`RIVET_ENGINE_VERSION ${tested} is older than RIVET_ENGINE_MINIMUM ${minimum}.`); \
        process.exit(1); \
      } \
    ' "${RIVET_ENGINE_MINIMUM}" "${RIVET_ENGINE_VERSION}"

ENV NODE_ENV=production \
    PORT=8080

# The starter goes through the same build as your Worker, from outside /src,
# so /src is empty for your project and /app holds only the built starter.
# (Railway's builder takes no bind mounts, so the source is copied in.)
WORKDIR /src
COPY starter/ /tmp/starter/
RUN openorange-build /tmp/starter && rm -rf /tmp/starter

EXPOSE 8080

# The template sets Railway's healthcheck to this path too. The image answers
# it itself, so it never reaches the Worker.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["node", "-e", "fetch(`http://127.0.0.1:${process.env.PORT || 8080}/cdn-cgi/railway/health`).then((r) => process.exit(r.ok ? 0 : 1), () => process.exit(1))"]

ENTRYPOINT ["/usr/local/bin/railway-openorange-entrypoint"]
