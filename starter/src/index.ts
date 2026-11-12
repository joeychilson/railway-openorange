import { DurableObject } from "cloudflare:workers";

interface Env {
	COUNTER: DurableObjectNamespace<Counter>;
	// Railway sets these on every replica, and the template passes them to the
	// Worker through ORANGE_WORKER_VARS.
	RAILWAY_REPLICA_ID?: string;
	RAILWAY_REPLICA_REGION?: string;
}

// One Counter for the whole app, with its own SQLite database. Every replica
// reaches the same one, wherever the Rivet Engine runs it.
export class Counter extends DurableObject<Env> {
	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS visits (visited_at INTEGER NOT NULL)");
	}

	visit(): number {
		const sql = this.ctx.storage.sql;
		sql.exec("INSERT INTO visits (visited_at) VALUES (?)", Date.now());
		return sql.exec<{ visits: number }>("SELECT count(*) AS visits FROM visits").one().visits;
	}
}

export default {
	async fetch(request, env): Promise<Response> {
		const { pathname } = new URL(request.url);
		if (pathname !== "/" && pathname !== "/api/visit") {
			return new Response("Not found\n", { status: 404 });
		}
		const visit = {
			visits: await env.COUNTER.getByName("starter").visit(),
			replica: env.RAILWAY_REPLICA_ID ?? "local",
			region: env.RAILWAY_REPLICA_REGION ?? "local",
		};
		if (pathname === "/api/visit") return Response.json(visit);
		return new Response(page(visit), { headers: { "content-type": "text/html; charset=utf-8" } });
	},
} satisfies ExportedHandler<Env>;

const escape = (text: string): string =>
	text.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`);

// Renovate doesn't update the image tag on this page, since the starter is part
// of the image: change it by hand in each minor or major release PR.
function page({ visits, replica, region }: { visits: number; replica: string; region: string }): string {
	return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>OpenOrange on Railway</title>
    <style>
      :root { color-scheme: light; }
      * { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        background: #fbf1e6;
        color: #1d140b;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
        font-size: 15px;
        line-height: 1.6;
        padding: 4rem 1.5rem;
        display: flex;
        justify-content: center;
      }
      main { max-width: 580px; width: 100%; display: flex; flex-direction: column; gap: 1.5rem; }
      h1 { font-size: 1.75rem; font-weight: 600; letter-spacing: -0.02em; }
      h1 .on { font-weight: 400; color: #8a7360; }
      h1 .railway { color: #6c3fe7; }
      p { color: #5a4636; }
      .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 0.75rem; }
      .stat { background: #fff; border: 1px solid #ecd9c4; border-radius: 6px; padding: 0.75rem 1rem; }
      .stat span { display: block; font-size: 12px; color: #8a7360; }
      .stat strong { font-size: 1.25rem; font-weight: 600; font-variant-numeric: tabular-nums; word-break: break-all; }
      pre { background: #1d140b; border-radius: 6px; padding: 1rem; overflow-x: auto; }
      code { font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace; font-size: 13px; color: #fbeee0; line-height: 1.5; }
      p code { background: #f3e1cd; color: #1d140b; padding: 0.15em 0.35em; border-radius: 4px; }
      .links { display: flex; flex-wrap: wrap; gap: 1.25rem; margin-top: 0.5rem; }
      a { color: #c2410c; text-decoration: none; }
      a:hover { text-decoration: underline; }
      @media (max-width: 480px) { .stats { grid-template-columns: 1fr; } }
    </style>
  </head>
  <body>
    <main>
      <h1>OpenOrange <span class="on">on</span> <span class="railway">Railway</span></h1>

      <p>
        This Cloudflare Worker runs on OpenOrange, with its Durable Objects on
        the Rivet Engine and their data in a Railway Bucket.
      </p>

      <div class="stats">
        <div class="stat"><span>Visits</span><strong>${visits}</strong></div>
        <div class="stat"><span>Replica</span><strong>${escape(replica.slice(0, 8))}</strong></div>
        <div class="stat"><span>Region</span><strong>${escape(region)}</strong></div>
      </div>

      <p>
        The count lives in one Durable Object with its own SQLite database. Add
        replicas to the <code>openorange</code> service and reload: each request
        can land on a different replica, and every one counts in the same place.
      </p>

      <p>
        To serve your own Worker, add this <code>Dockerfile</code> next to its
        <code>wrangler.jsonc</code>, with the template's
        <a href="https://github.com/joeychilson/railway-openorange/blob/main/examples/.dockerignore"><code>.dockerignore</code></a>
        so local secrets stay out of the image, and deploy it to the
        <code>openorange</code> service:
      </p>

      <pre><code>FROM ghcr.io/joeychilson/railway-openorange:1.0
COPY . .
RUN openorange-build</code></pre>

      <pre><code>railway link
# Once, so Railway stops redeploying this starter image over yours:
railway service source disconnect --service openorange
railway up --service openorange</code></pre>

      <p>
        Or connect your GitHub repo to the service, and every push deploys.
      </p>

      <nav class="links">
        <a href="https://openorange.dev/docs/">OpenOrange docs &rarr;</a>
        <a href="https://github.com/rivet-dev/open-orange">OpenOrange GitHub &rarr;</a>
        <a href="https://github.com/joeychilson/railway-openorange">Railway template &rarr;</a>
      </nav>
    </main>
  </body>
</html>
`;
}
