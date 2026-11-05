import assert from "node:assert/strict";
import { test } from "node:test";
import { buildToc } from "./toc.mjs";

test("contents form an indented tree with nested subheadings and sibling sections", () => {
  const heading = (depth, text) => ({ depth, text, slug: text.toLowerCase() });
  const tree = buildToc([
    heading(1, "Title"), heading(2, "Client"), heading(3, "Create"),
    heading(4, "Options"), heading(3, "Parse"), heading(2, "Decisions"),
  ]);
  assert.deepEqual(tree.map((entry) => entry.text), ["Client", "Decisions"]);
  assert.deepEqual(tree[0].children.map((entry) => entry.text), ["Create", "Parse"]);
  assert.equal(tree[0].children[0].children[0].text, "Options");
  assert.deepEqual(buildToc([heading(1, "Only title")]), []);
});
