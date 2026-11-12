# Builds your Worker on the OpenOrange image. Put this file and .dockerignore
# next to your wrangler.jsonc, wrangler.json, or wrangler.toml, then deploy with
# `railway up` or from your GitHub repo.
FROM ghcr.io/joeychilson/railway-openorange:1.0

# The image's working directory, /src, is empty for your project.
COPY . .

# Installs your packages, runs your build.command, and bundles the Worker into
# /app. Add --env <name> to build a Wrangler environment, or --config <path>.
RUN openorange-build
