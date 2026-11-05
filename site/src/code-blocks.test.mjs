import assert from "node:assert/strict";
import { test } from "node:test";
import { markdownToHtml } from "satteri";
import { codeBlocks } from "./code-blocks.mjs";

test("code controls are rendered once in the HTML without changing code text", () => {
  const source = 'const message = "Hi <there> & friends";';
  const { html } = markdownToHtml("\`\`\`zig\n" + source + "\n\`\`\`", { hastPlugins: [codeBlocks] });
  assert.equal([...html.matchAll(/class="code-block"/g)].length, 1);
  assert.equal([...html.matchAll(/class="copy-code"/g)].length, 1);
  assert.match(html, /aria-label="Copy Zig code"/);
  assert.match(html, /Hi &lt;there&gt; (?:&amp;|&) friends/);
  assert.ok(html.indexOf('class="code-toolbar"') < html.indexOf("<pre"));
});

test("plain code blocks retain their text and get a text label", () => {
  const { html } = markdownToHtml("    plain code", { hastPlugins: [codeBlocks] });
  assert.match(html, /aria-label="Copy Text code"/);
  assert.match(html, /plain code/);
});
