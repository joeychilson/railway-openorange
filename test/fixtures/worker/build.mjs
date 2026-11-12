// The Worker imports what this writes, so its bundle fails unless
// build.command ran first.
import { writeFileSync } from "node:fs";

writeFileSync("src/built.js", `export const built = ${JSON.stringify("by build.command")};\n`);
