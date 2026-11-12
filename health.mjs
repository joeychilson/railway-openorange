// Preloaded into every Node.js process of `orange serve` through NODE_OPTIONS.
// The HTTP server listening on PORT answers /cdn-cgi/railway/health itself, so
// Railway's healthcheck never reaches the Worker. Cloudflare reserves
// /cdn-cgi/, so no Worker brought over from it uses the path.
//
// The server listens only after the Worker has loaded, so an answer means the
// node can serve. It answers 200 while the Rivet Engine answers too, and 503
// when it doesn't, because a node without its Engine can't reach a Durable
// Object.
import http from "node:http";
import https from "node:https";

const path = "/cdn-cgi/railway/health";
const port = Number(process.env.PORT || 8080);

let engineHealth;
try {
  const url = new URL(process.env.RIVET_ENDPOINT ?? "");
  url.username = "";
  url.password = "";
  engineHealth = new URL("health", url.href.endsWith("/") ? url.href : `${url.href}/`);
} catch {
  engineHealth = undefined;
}

// One check at a time, and its answer reused for a second.
let checked = 0;
let pending;
let engineOk = false;
function checkEngine() {
  if (engineHealth === undefined) return Promise.resolve(false);
  if (Date.now() - checked < 1000) return Promise.resolve(engineOk);
  pending ??= new Promise((resolve) => {
    const client = engineHealth.protocol === "https:" ? https : http;
    const request = client.get(engineHealth, { timeout: 3000 }, (response) => {
      response.resume();
      resolve(response.statusCode === 200);
    });
    request.on("timeout", () => request.destroy());
    request.on("error", () => resolve(false));
  }).then((ok) => {
    engineOk = ok;
    checked = Date.now();
    pending = undefined;
    return ok;
  });
  return pending;
}

function answer(response, ok) {
  const body = JSON.stringify(ok ? { status: "ok" } : { status: "error", error: "Rivet Engine unreachable" });
  response.writeHead(ok ? 200 : 503, {
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(body),
    "content-type": "application/json",
  });
  response.end(body);
}

const emit = http.Server.prototype.emit;
http.Server.prototype.emit = function (event, request, response) {
  if (event === "request" && (request.url === path || request.url?.startsWith(`${path}?`))) {
    const address = this.address();
    if (address !== null && typeof address === "object" && address.port === port) {
      checkEngine().then((ok) => answer(response, ok));
      return true;
    }
  }
  return emit.apply(this, arguments);
};
