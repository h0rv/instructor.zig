import { spawnSync } from "node:child_process";
import { cpSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = new URL("../../", import.meta.url);
const result = spawnSync(process.env.ZIG || "zig", ["build", "docs"], {
  cwd: fileURLToPath(root),
  stdio: "inherit",
});
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);

const destination = new URL("../public/api/", import.meta.url);
rmSync(destination, { recursive: true, force: true });
cpSync(new URL("zig-out/docs/", root), destination, { recursive: true });
// Let the browser choose its initial canvas color before Autodoc loads.
const index = new URL("index.html", destination);
const html = readFileSync(index, "utf8");
writeFileSync(index, html.replace("<head>", '<head><meta name="color-scheme" content="light dark">'));
