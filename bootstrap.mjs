// Runs before `orange serve`. It waits for the Rivet Engine in RIVET_ENDPOINT,
// refuses an Engine older than the RivetKit this image runs, and creates the
// namespace and node pool when they don't exist. An existing pool keeps its
// settings.
import { readFileSync } from "node:fs";

const waitMs = 180_000;
const started = Date.now();

const fail = (message) => {
  console.error(`ERROR: ${message}`);
  process.exit(1);
};
const log = (message) => console.log(`entrypoint: ${message}`);

let endpoint;
try {
  endpoint = new URL(process.env.RIVET_ENDPOINT);
} catch {
  // Left undefined, and refused below.
}
// new URL() also takes "rivet-engine.railway.internal:6420", with
// "rivet-engine.railway.internal:" as its scheme, so check the scheme too.
if (!["http:", "https:"].includes(endpoint?.protocol)) {
  fail(
    `RIVET_ENDPOINT is not an http or https URL: ${JSON.stringify(process.env.RIVET_ENDPOINT)}. Use one such as http://\${{rivet-engine.RAILWAY_PRIVATE_DOMAIN}}:6420.`,
  );
}
// The same precedence as `orange serve`: credentials in the URL, then the
// variables.
const token = decodeURIComponent(endpoint.password) || process.env.RIVET_TOKEN || "";
const namespace = decodeURIComponent(endpoint.username) || process.env.RIVET_NAMESPACE || "default";
// `orange serve` joins every Worker to this pool, whatever RIVET_POOL says.
const pool = "default";
endpoint.username = "";
endpoint.password = "";
const base = endpoint.href.replace(/\/+$/, "");
if (token === "") {
  fail("RIVET_TOKEN is not set. Set it to the Rivet Engine's RIVET__AUTH__ADMIN_TOKEN.");
}

const rivetkit = JSON.parse(readFileSync("/opt/openorange/node_modules/rivetkit/package.json", "utf8")).version;
const tested = readFileSync("/opt/railway-openorange/tested-engine-version", "utf8").trim();

// [major, minor, patch] of a version such as 3.1.2-rc.1.
const parse = (version) => (/^(\d+)\.(\d+)\.(\d+)/.exec(version) ?? []).slice(1).map(Number);
const compare = (left, right, parts) => {
  for (let i = 0; i < parts; i += 1) {
    if (left[i] !== right[i]) return left[i] - right[i];
  }
  return 0;
};

// Retries until the deadline, so a node that starts with the Engine waits for
// it instead of crashing. `request` returns a value to stop, or undefined to
// try again after `reason`.
async function retry(what, request) {
  let lastLog = 0;
  for (;;) {
    let reason;
    try {
      const result = await request((why) => {
        reason = why;
      });
      if (result !== undefined) return result;
    } catch (error) {
      reason = error.cause?.code ?? error.cause?.message ?? error.message;
    }
    const elapsed = Date.now() - started;
    if (elapsed > waitMs) fail(`gave up ${what} after ${Math.round(elapsed / 1000)} s: ${reason}`);
    if (Date.now() - lastLog > 10_000) {
      log(`${what}: ${reason}. Retrying.`);
      lastLog = Date.now();
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
}

// Fails on an answer that a retry can't change, and otherwise returns why to
// retry. A fresh Engine answers 400 "overloaded" for about a second after its
// /health is ok, so a 400 or 422 is final only with another code.
async function refused(response, what) {
  const text = await response.text();
  let body = {};
  try {
    body = JSON.parse(text);
  } catch {
    // Not JSON, such as a proxy's error page.
  }
  const detail = `${response.status} ${text}`;
  if (response.status === 401 || response.status === 403) {
    fail(`the Rivet Engine refused RIVET_TOKEN (${detail}). Set it to the Engine's RIVET__AUTH__ADMIN_TOKEN.`);
  }
  const passing = body.code === "overloaded" || body.metadata?.retry_after_ms !== undefined;
  if ((response.status === 400 || response.status === 422) && !passing) {
    fail(`the Rivet Engine refused ${what}: ${detail}`);
  }
  return detail;
}

const call = (path, init = {}) =>
  fetch(`${base}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...init.headers },
    signal: AbortSignal.timeout(10_000),
  });

const health = await retry(`waiting for the Rivet Engine at ${base}`, async (retryBecause) => {
  const response = await call("/health");
  const body = await response.json().catch(() => ({}));
  if (response.ok && body.status === "ok") return body;
  retryBecause(`/health answered ${response.status} ${JSON.stringify(body)}`);
});

const engine = health.version ?? "unknown";
if (parse(engine).length === 0) {
  log(`WARNING: the Rivet Engine didn't report a version, so this image can't check it. It needs ${tested}.`);
} else if (compare(parse(engine), parse(rivetkit), 2) < 0) {
  fail(
    `the Rivet Engine is ${engine}, older than RivetKit ${rivetkit} in this image, which needs Engine ${parse(rivetkit).slice(0, 2).join(".")} or newer. Upgrade the Engine first: this image is tested with ${tested}.`,
  );
}
log(`Rivet Engine ${engine} at ${base}, RivetKit ${rivetkit}, node version ${process.env.RIVET_NODE_VERSION}`);
if (compare(parse(engine), parse(tested), 3) < 0) {
  log(`WARNING: this image is tested with Rivet Engine ${tested}. Upgrade the Engine when you can.`);
}

// The namespace holds this app's Durable Objects. The Engine starts with
// "default". Any other name is created, so several apps can share one Engine,
// each in a namespace of its own.
await retry(`checking namespace ${namespace}`, async (retryBecause) => {
  const listed = await call(`/namespaces?name=${encodeURIComponent(namespace)}`);
  if (!listed.ok) {
    retryBecause(await refused(listed, `namespace ${namespace}`));
    return undefined;
  }
  const found = (await listed.json()).namespaces?.find((entry) => entry.name === namespace);
  if (found?.status === "live") return true;
  if (found !== undefined) {
    if (["archiving", "archived", "failed"].includes(found.status)) {
      fail(`namespace ${namespace} is ${found.status}, and the Engine never reuses a name. Set RIVET_NAMESPACE to a new one.`);
    }
    retryBecause(`it is ${found.status}`);
    return undefined;
  }
  // Two nodes that start together may both try. The loser gets 409, and its
  // next check finds the namespace. Engine 3.1 takes only `name`, not the
  // `display_name` its API reference lists.
  const created = await call("/namespaces", { method: "POST", body: JSON.stringify({ name: namespace }) });
  if (!created.ok) {
    retryBecause(`creating it answered ${await refused(created, `namespace ${namespace}`)}`);
    return undefined;
  }
  log(`created namespace ${namespace}`);
  if ((await created.json().catch(() => ({}))).namespace?.status === "live") return true;
  retryBecause("it is still being created");
  return undefined;
});

const poolPath = `/pools/${encodeURIComponent(pool)}?namespace=${encodeURIComponent(namespace)}`;
await retry(`checking node pool ${pool} in namespace ${namespace}`, async (retryBecause) => {
  const existing = await call(poolPath);
  if (existing.ok) return true;
  if (existing.status !== 404) {
    retryBecause(await refused(existing, `pool ${pool} in namespace ${namespace}`));
    return undefined;
  }
  // Two nodes that start together may both create it. PUT is an upsert, and
  // both send the same defaults.
  const created = await call(poolPath, { method: "PUT", body: "{}" });
  if (!created.ok) {
    retryBecause(`creating it answered ${await refused(created, `pool ${pool} in namespace ${namespace}`)}`);
    return undefined;
  }
  log(`created node pool ${pool} in namespace ${namespace}`);
  return true;
});
