import { fileURLToPath } from "node:url";
import { posix } from "node:path";

export const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));
export const repositoryURL = "https://github.com/h0rv/instructor.zig";

export function pagePath(source) {
  if (source === "README.md") return "";
  if (/^docs\/.+\.md$/.test(source)) return `guides/${source.slice(5, -3)}/`;
  return null;
}

export function withBase(path, base = "/") {
  const prefix = base.replace(/^\/+|\/+$/g, "");
  return `/${prefix ? prefix + "/" : ""}${path.replace(/^\/+/, "")}`;
}

export function rewriteLink(href, source, base = "/") {
  if (/^(?:[a-z][a-z\d+.-]*:|\/|#)/i.test(href)) return href;
  const split = href.search(/[?#]/);
  const path = split < 0 ? href : href.slice(0, split);
  const suffix = split < 0 ? "" : href.slice(split);
  if (!path) return href;
  const target = posix.normalize(posix.join(posix.dirname(source.replaceAll("\\", "/")), path));
  const page = pagePath(target);
  return page === null ? `${repositoryURL}/blob/main/${target}${suffix}` : withBase(page, base) + suffix;
}
