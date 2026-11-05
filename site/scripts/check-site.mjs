import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../dist/", import.meta.url));
const base = (process.env.DOCS_BASE || "/").replace(/\/?$/, "/");
const origin = "https://docs.invalid";
let checked = 0;

function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
}

for (const file of walk(root).filter((path) => path.endsWith(".html"))) {
  const page = relative(root, file).replaceAll("\\", "/");
  const html = readFileSync(file, "utf8");
  for (const match of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    const url = new URL(match[1].replaceAll("&amp;", "&"), origin + base + page);
    if (url.origin !== origin) continue;
    assert.ok(url.pathname.startsWith(base), `Link escapes deployment base: ${url}`);
    const path = join(root, decodeURIComponent(url.pathname.slice(base.length)));
    const target = url.pathname.endsWith("/") ? join(path, "index.html") : path;
    assert.ok(existsSync(target) && statSync(target).isFile(), `Missing target in ${page}: ${url}`);
    if (url.hash && target.endsWith(".html") && !url.pathname.startsWith(base + "api/")) {
      const id = decodeURIComponent(url.hash.slice(1));
      assert.ok(readFileSync(target, "utf8").includes(`id="${id}"`), `Missing anchor in ${page}: ${url}`);
    }
    checked++;
  }
}
for (const asset of ["api/index.html", "api/main.js", "api/main.wasm", "api/sources.tar", "missing.css", "missing.LICENSE"]) {
  assert.ok(existsSync(join(root, asset)), `Missing published asset: ${asset}`);
}
console.log(`Checked ${checked} local links and assets.`);
