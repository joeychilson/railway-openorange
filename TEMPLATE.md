# Deploy and Host OpenOrange with Railway

OpenOrange runs Cloudflare Workers and Durable Objects on Node.js, with each
Durable Object as a Rivet Actor on a self-hosted Rivet Engine. This template
runs your Worker as a service you can scale with replicas, a private Rivet
Engine to place and store your Durable Objects, and a Railway Bucket for their
durable copy, with every variable configured for you and a starter Worker to
try it.

## About Hosting OpenOrange

OpenOrange needs a Rivet Engine, and the Engine needs local disk for recent
writes plus S3-compatible object storage for the durable copy of every Durable
Object. The template runs the Engine on Railway's private network with a
volume at `/var/lib/rivet/log` and a Railway Bucket, and generates the token
that the Worker's nodes use to reach it. The `openorange` service serves the
Worker on a public domain. Each replica is a node of the Engine, which runs
every Durable Object on one node at a time and routes calls to it from any
replica. Nodes create their namespace and node pool on first start, drain on
every deploy, and keep their Durable Objects' data across deploys. Patch
releases of both images install automatically during Railway's nightly update
window.

## Common Use Cases

- Self-hosting Cloudflare Workers and Durable Objects
- Moving a Worker off Cloudflare, starting from its Wrangler configuration
- Stateful applications with one SQLite database per object
- Chat rooms, counters, coordinators, and WebSocket services

## Dependencies for OpenOrange Hosting

- A Rivet Engine, which the template runs as the `rivet-engine` service
- A Railway volume for the Engine's recent writes and identity
- A Railway Bucket for the durable copy of your Durable Objects
- A Wrangler project and the Railway CLI or a GitHub repo to deploy your Worker

### Deployment Dependencies

- [OpenOrange documentation](https://openorange.dev/docs/)
- [OpenOrange source code](https://github.com/rivet-dev/open-orange)
- [Self-hosting the Rivet Engine](https://rivet.dev/docs/deploy/self-host/control-plane/)
- [Template source and full README](https://github.com/joeychilson/railway-openorange)

### Implementation Details

Add this `Dockerfile` next to your `wrangler.jsonc`, with the
[`.dockerignore`](https://github.com/joeychilson/railway-openorange/blob/main/examples/.dockerignore)
from the template's repo so local secrets stay out of the image:

```dockerfile
FROM ghcr.io/joeychilson/railway-openorange:1.0
COPY . .
RUN openorange-build
```

`openorange-build` installs your packages, runs your `build.command`, and
bundles the Worker. Deploy it to the `openorange` service, disconnecting the
starter image once first so Railway doesn't deploy it again over your Worker:

```bash
railway link
railway service source disconnect --service openorange
railway up --service openorange
```

Or connect your GitHub repo to the service, and every push deploys. Scale
with `railway scale --service openorange us-east=2 eu-west=2`. Keep
`rivet-engine` at one replica and off the public internet.

### Why Deploy OpenOrange on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will
host your infrastructure so you don't have to deal with configuration, while
allowing you to vertically and horizontally scale it.

By deploying OpenOrange on Railway, you are one step closer to supporting a
complete full-stack application with minimal burden. Host your servers,
databases, AI agents, and more on Railway.
