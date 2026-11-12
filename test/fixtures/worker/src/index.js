import ms from "ms";
import { built } from "./built.js";

export default {
  async fetch(request, env) {
    return Response.json({
      built,
      greeting: env.GREETING,
      dependency: ms("2 days"),
      secret: env.SMOKE_SECRET === "smoke-secret-value",
      // OpenOrange removes the Engine's token from env and process.env. It is
      // still in /proc/self/environ: see the README's Security section.
      engineToken: env.RIVET_TOKEN !== undefined || globalThis.process?.env?.RIVET_TOKEN !== undefined,
    });
  },
};
