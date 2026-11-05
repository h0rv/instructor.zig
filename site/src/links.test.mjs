import assert from "node:assert/strict";
import { test } from "node:test";
import { pagePath, rewriteLink, withBase } from "./links.mjs";

test("root and project hosting paths preserve trailing slashes", () => {
  assert.equal(withBase(""), "/");
  assert.equal(withBase("", "/instructor.zig/"), "/instructor.zig/");
  assert.equal(withBase("api/", "/instructor.zig/"), "/instructor.zig/api/");
  assert.equal(withBase("missing.css", "/instructor.zig/"), "/instructor.zig/missing.css");
});

test("existing Markdown guides map to site pages without moving source", () => {
  assert.equal(pagePath("README.md"), "");
  assert.equal(pagePath("docs/decisions.md"), "guides/decisions/");
  assert.equal(pagePath("docs/cookbook/product.md"), "guides/cookbook/product/");
  assert.equal(rewriteLink("../client.md", "docs/cookbook/product.md"), "/guides/client/");
  assert.equal(rewriteLink("../../examples/client.zig", "docs/cookbook/product.md"), "https://github.com/h0rv/instructor.zig/blob/main/examples/client.zig");
  assert.equal(pagePath("examples/client.zig"), null);
  assert.equal(rewriteLink("docs/decisions.md#supported-types", "README.md"), "/guides/decisions/#supported-types");
  assert.equal(rewriteLink("client.md#request-extras", "docs/decisions.md"), "/guides/client/#request-extras");
  assert.equal(rewriteLink("../README.md", "docs/client.md"), "/");
  assert.equal(rewriteLink("transport.md", "docs/client.md", "/instructor.zig/"), "/instructor.zig/guides/transport/");
});

test("example files point to GitHub and public URLs and anchors stay unchanged", () => {
  assert.equal(rewriteLink("../examples/decisions.zig", "docs/decisions.md"), "https://github.com/h0rv/instructor.zig/blob/main/examples/decisions.zig");
  for (const href of ["https://example.com/docs", "//example.com", "#memory", "mailto:help@example.com"])
    assert.equal(rewriteLink(href, "README.md", "/instructor.zig/"), href);
});
