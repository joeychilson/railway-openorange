# OpenOrange on Railway

[![Release](https://img.shields.io/github/v/release/joeychilson/railway-openorange)](https://github.com/joeychilson/railway-openorange/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Railway template for running [OpenOrange](https://openorange.dev), which
runs Cloudflare Workers and Durable Objects on Node.js. Each Durable Object is
a Rivet Actor on a self-hosted [Rivet Engine](https://rivet.dev/docs/deploy/self-host/control-plane/),
so the Worker scales out with Railway replicas while every object keeps one
home and its own SQLite database.

Rivet describes a single Engine instance on Railway as a way to try Rivet, and
recommends three or more instances on Kubernetes or VMs for production. Read
[Backup and restore](#backup-and-restore) before you store data you can't lose.

## Deploy

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/openorange-for-railway?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

The template creates:

- `openorange`: the `ghcr.io/joeychilson/railway-openorange` image for amd64
  and arm64, serving a starter Worker on a public domain at port `8080`.
- `rivet-engine`: the `rivetdev/engine` image on the private network only, with
  a volume at `/var/lib/rivet/log`.
- A Railway Bucket, where the Engine keeps the durable copy of every Durable
  Object.

```text
            ┌──────────────┐  private network  ┌──────────────┐     ┌────────┐
 HTTPS ───▶ │  openorange  │ ────────────────▶ │ rivet-engine │ ──▶ │ Bucket │
            │  replicas    │       :6420       │ + volume     │     └────────┘
            └──────────────┘                   └──────────────┘
```

Each replica of `openorange` is a node of the Engine. The Engine runs each
Durable Object on one node at a time and routes calls to it from any replica.
A write is acknowledged once it is on the Engine's volume and reaches the
Bucket shortly after. The starter page counts visits in one Durable Object, so
you can add replicas and watch them all count in the same place.

## Usage

### Deploy your Worker

Copy [`examples/Dockerfile`](examples/Dockerfile) and
[`examples/.dockerignore`](examples/.dockerignore) next to your
`wrangler.jsonc`, `wrangler.json`, or `wrangler.toml`. The `.dockerignore`
keeps `node_modules` and local secrets such as `.dev.vars` out of `/src`,
which stays in the image:

```dockerfile
FROM ghcr.io/joeychilson/railway-openorange:1.0
COPY . .
RUN openorange-build
```

Then point the `openorange` service at your code. Either connect your GitHub
repo, and every push builds and deploys:

```text
railway link
railway service source connect --repo <owner>/<repo> --service openorange
```

Or deploy from your machine. Disconnect the starter image once first: while
the service's source is the image, Railway deploys the image again on the next
variable change or image update, replacing your Worker with the starter.

```text
railway link
railway service source disconnect --service openorange
railway up --service openorange
```

Once the service builds from your code, image auto-updates no longer apply to
it. The `X.Y` tag in `FROM` moves to each patch release, so every build picks
up the newest one.

### What `openorange-build` does

1. Installs the project's packages with the package manager its lockfile
   names: npm, pnpm, Yarn, or Bun. Without a lockfile it uses the
   `packageManager` field of `package.json`, then npm.
2. Runs the Wrangler `build.command`, if there is one.
3. Bundles the Worker and its packages with `orange deploy --dry-run`, the
   build `orange deploy` uses for its own images, into `/app`. `node_modules`,
   `.git`, `.env`, `.env.*`, `.dev.vars*`, `.wrangler`, `.rivet`, and
   `.open-orange` stay out of it.
4. Installs the extra OpenOrange packages a Sandbox or Worker Loader binding
   needs. They add about 600 MB to the image, so the base image leaves them
   out.
5. Removes the `node_modules` it installed, and stamps the build with a new
   node version, so new Durable Objects start on the newest deploy.

| Option | Purpose |
|---|---|
| `-e, --env <name>` | Build a Wrangler environment, as `wrangler deploy -e` does |
| `-c, --config <path>` | Use a Wrangler configuration file other than the default |
| `--no-install` | Skip the install, for a monorepo whose packages you install yourself |
| `[directory]` | Build a project other than the working directory, `/src` |

Copy the project to `/src`, the image's working directory, as the example
does. `/app` holds the built Worker, and `openorange-build` refuses a project
there.

### Variables and secrets

Wrangler `vars` are built in. To give the Worker one of the service's
variables, add its name to `ORANGE_WORKER_VARS`, or to
`ORANGE_WORKER_SECRETS` for a secret, as a comma-separated list:

```text
railway variables --service openorange \
  --set API_KEY=... \
  --set ORANGE_WORKER_SECRETS=API_KEY
```

Of the service's variables, only the listed ones reach the Worker's `env` and
`process.env`. OpenOrange removes `RIVET_TOKEN` from both, but the Worker runs
in the node's own process, so its code can still read the token from
`/proc/self/environ`. See [Security](#security).

## Configuration

The template configures these variables on `openorange`:

| Variable | Value | Purpose |
|---|---|---|
| `RIVET_ENDPOINT` | `http://${{rivet-engine.RAILWAY_PRIVATE_DOMAIN}}:6420` | The Engine, over the private network |
| `RIVET_TOKEN` | `${{rivet-engine.RIVET__AUTH__ADMIN_TOKEN}}` | The Engine's token |
| `RIVET_NAMESPACE` | `default` | The Engine namespace for this app's Durable Objects |
| `PORT` | `8080` | Public Worker listener |
| `ORANGE_WORKER_VARS` | `RAILWAY_REPLICA_ID,RAILWAY_REPLICA_REGION` | Service variables the Worker gets in `env` |
| `ORANGE_WORKER_SECRETS` | | Service variables the Worker gets in `env` as secrets |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Time a node gets to put its Durable Objects to sleep |
| `RAILWAY_DEPLOYMENT_OVERLAP_SECONDS` | `10` | Time old and new nodes serve together on a deploy |

And these on `rivet-engine`:

| Variable | Value | Purpose |
|---|---|---|
| `RIVET__AUTH__ADMIN_TOKEN` | 64 random hex characters | The token nodes and the Engine API use |
| `RIVET__STORAGE__LOG_DIRECTORY` | `/var/lib/rivet/log` | The volume, for recent writes and the instance's identity |
| `RIVET__STORAGE__AUTO_PROVISION_PARTITIONS` | `1` | Storage for one instance |
| `RIVET__STORAGE__BALANCING__ENABLED` | `false` | No balancing with one instance |
| `RIVET__OBJECT_STORAGE__PRIMARY__S3__BUCKET` | `${{Bucket.BUCKET}}` | Railway Bucket |
| `RIVET__OBJECT_STORAGE__PRIMARY__S3__ENDPOINT` | `${{Bucket.ENDPOINT}}` | Railway Bucket |
| `RIVET__OBJECT_STORAGE__PRIMARY__S3__REGION` | `${{Bucket.REGION}}` | Railway Bucket |
| `RIVET__OBJECT_STORAGE__PRIMARY__S3__ACCESS_KEY_ID` | `${{Bucket.ACCESS_KEY_ID}}` | Bucket credentials |
| `RIVET__OBJECT_STORAGE__PRIMARY__S3__SECRET_ACCESS_KEY` | `${{Bucket.SECRET_ACCESS_KEY}}` | Bucket credentials |
| `RIVET__OBJECT_STORAGE__READ_FIRST_ATTEMPT_MS` | `1000` | Retry a slow Bucket read after 1 second instead of 250 ms |
| `PORT` | `6420` | The port Railway's healthcheck calls |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `30` | Time the Engine gets to stop |

The Engine sends crash reports to Rivet unless `RIVET__TELEMETRY__ENABLED` is
`false`. Every Engine setting can be set as a `RIVET__` variable; see the
[Engine configuration](https://rivet.dev/docs/deploy/self-host/control-plane/configuration/).

For a manual Railway deployment, use these service settings:

- `openorange`: a public domain on port `8080`, healthcheck path
  `/cdn-cgi/railway/health` with a 300-second timeout, restart policy
  `Always`, and Serverless sleeping off.
- `rivet-engine`: one replica, no public domain, a volume at
  `/var/lib/rivet/log`, healthcheck path `/health` with a 300-second timeout,
  restart policy `Always`, and Serverless sleeping off.

## Operations

### Scaling

Nodes are interchangeable. Add replicas, in one region or several:

```text
railway scale --service openorange us-east=3
railway scale --service openorange us-east=2 eu-west=2
```

New replicas connect to the Engine and take Durable Objects. Remove replicas
a few at a time: each one drains for up to a minute. Railway doesn't autoscale
on load, so size the count for peak traffic. Don't turn on Serverless sleeping
for either service. A node only connects out to the Engine, so no request
would ever wake it.

The Engine runs as one replica, since a volume belongs to one instance. Give it
more CPU and memory as the app grows, and keep it and the Bucket in the same
region.

### Deploys

Each build stamps the node version, `RIVET_NODE_VERSION`. On a deploy, new
nodes connect and take new and waking Durable Objects. Railway then stops the
old nodes, which put their objects to sleep within the draining time, and the
objects wake on the new nodes at their next request.

A Durable Object belongs to its Worker's `name` and Wrangler environment, not
to a build, so new code reaches the same objects and their data. Renaming the
Worker, or building another environment with `--env`, gives its classes new
objects: the old ones keep their data in the Engine, but the Worker no longer
reaches them.

### Several apps on one Engine

Several `openorange` services can share one Engine. Their Durable Objects stay
apart as long as their Workers have different names. Two services whose
Workers have the same name, such as two copies of one Worker, need their own
`RIVET_NAMESPACE`, or they would share objects. A Railway environment, such as
staging, has its own Engine already.

A node creates its namespace when it doesn't exist. Names are DNS labels of up
to 63 lowercase letters, digits, and hyphens, and a name is never reused once
archived.

### Health

`openorange` answers `/cdn-cgi/railway/health` itself, without reaching the
Worker: `200` once the Worker is loaded and the Engine answers, `503` while
the Engine doesn't. Cloudflare reserves `/cdn-cgi/`, so no Worker uses the
path. Railway checks it only during deploys, so monitor it separately for
production.

A node starts only after the Engine answers. It waits up to three minutes,
then exits with an error. It also exits at once when `RIVET_TOKEN` is wrong,
`RIVET_NAMESPACE` is not a valid name, or the Engine is older than the RivetKit
release in the image.

For a few seconds after a node starts, OpenOrange logs `The actor does
not exist or was destroyed` warnings, and each Durable Object with SQLite logs
`SQLite transaction is unnamed`. Both are harmless.

### Backup and restore

The Engine keeps data in two places:

- The volume holds the Engine's identity and recent writes, including
  acknowledged writes that have not reached the Bucket. Turn on Railway
  volume backups for `rivet-engine`, and never delete the volume.
- The Bucket holds the durable copy of every Durable Object. Railway volume
  backups don't include it.

To copy the Bucket, install the Railway and AWS CLIs locally and run:

```text
mkdir rivet-backup-YYYYMMDD
cd rivet-backup-YYYYMMDD
railway run --service rivet-engine -- sh -c '
  AWS_ACCESS_KEY_ID="$RIVET__OBJECT_STORAGE__PRIMARY__S3__ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$RIVET__OBJECT_STORAGE__PRIMARY__S3__SECRET_ACCESS_KEY" \
  aws s3 sync "s3://$RIVET__OBJECT_STORAGE__PRIMARY__S3__BUCKET" . \
    --endpoint-url "$RIVET__OBJECT_STORAGE__PRIMARY__S3__ENDPOINT" \
    --region "$RIVET__OBJECT_STORAGE__PRIMARY__S3__REGION" --no-progress'
```

The copy holds what had reached the Bucket, not the writes still on the
volume. Rivet has not yet validated restoring a Bucket into a new Engine for
this release, so keep the original Bucket and volume until a restore is
verified, and never start a second Engine on a Bucket the first still uses.
See Rivet's [backup guide](https://rivet.dev/docs/deploy/self-host/control-plane/backups/).

### Security

- Keep `rivet-engine` off the public internet. Its API, with the token,
  controls every Durable Object in every namespace.
- `RIVET_TOKEN` is the Engine's admin token. OpenOrange removes it from the
  Worker's `env` and `process.env`, but the Worker's code, and every package it
  bundles, runs in the same process and can read it from `/proc`. Deploy only
  code you trust. Apps that share an Engine can reach each other's Durable
  Objects through the token, so give an app you don't trust an Engine of its
  own.
- The Bucket's credentials are only on `rivet-engine`.
- Authenticate requests in the Worker when the application needs it.

## Updates

Each release is published as `ghcr.io/joeychilson/railway-openorange:X.Y.Z`
and moves the `X.Y` tag to it. The template deploys `X.Y` with patch
auto-updates on, so a deployment that keeps that setting picks up patch
releases in Railway's nightly update window. A minor or major release starts a
new `X.Y` tag, and its release notes say what to change before you move to it.

The template deploys the Engine as `rivetdev/engine:X.Y.Z` with patch
auto-updates on too. The Engine stops before its update starts, since its
volume belongs to one instance, so requests fail for the few seconds it takes,
and nodes reconnect on their own.

Upgrade the Engine before the nodes. A node refuses an Engine whose `X.Y` is
older than the RivetKit release it runs, and warns when the Engine is older
than the release this image is tested with. Every release of one major version
runs on the same oldest Engine, `RIVET_ENGINE_MINIMUM` in the Dockerfile,
whose build fails when an OpenOrange update needs a newer one. Only a new
major version raises it, and its release notes say so: change the
`rivet-engine` image first, then the `openorange` one.

[Renovate](https://docs.renovatebot.com) bumps OpenOrange, the Engine, and
Node.js in the Dockerfile. Patch updates merge after the smoke test passes on
amd64 and arm64 and publish a patch release. A minor or major OpenOrange
update can need a newer Engine, so it waits for review and releases as a new
major by default. A minor or major Engine update also waits for review, since
the template's Engine image changes with it. Renovate also moves the image tag
in `examples/Dockerfile` and the docs to each new `X.Y`; a minor or major
release PR changes the starter page's tag by hand, since the starter is part
of the image. The release policy for all of these templates is in
[railway-templates](https://github.com/joeychilson/railway-templates#releases).

## Development

```text
docker build -t railway-openorange:test .
./test/smoke-test.sh railway-openorange:test
```

The smoke test runs the image against the Engine release the Dockerfile pins,
on a private Docker network. It checks the version pin, the configuration and
Engine checks, health, the starter's Durable Object across a restart and an
Engine outage, a new build reaching the same Durable Objects, Worker
variables, namespaces, the node pool and version, the non-root runtime, and
graceful shutdown. It also builds the Workers in
`test/fixtures` with `openorange-build`, one of them from
`examples/Dockerfile`.

## License

[MIT](LICENSE). OpenOrange and the Rivet Engine are licensed under Apache-2.0
by Rivet Gaming, Inc.
