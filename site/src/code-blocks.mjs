import { defineHastPlugin } from "satteri";

const element = (tagName, properties, children = []) => ({ type: "element", tagName, properties, children });
const text = (value) => ({ type: "text", value });

export const codeBlocks = defineHastPlugin({
  name: "static-code-controls",
  element: {
    filter: ["pre"],
    visit(node) {
      if (node.properties["data-copy-ready"]) return;
      const code = node.children.find((child) => child.type === "element" && child.tagName === "code");
      if (!code) return;
      const classes = code.properties.className || [];
      const language = node.properties["data-language"] || node.properties.dataLanguage ||
        (Array.isArray(classes) ? classes.find((name) => name.startsWith("language-"))?.slice(9) : null) || "text";
      const name = { zig: "Zig", sh: "Shell", bash: "Shell", json: "JSON", text: "Text" }[language] || language;
      const copy = element("pre", { ...node.properties, "data-copy-ready": true }, [...node.children]);
      const icon = element("svg", {
        "aria-hidden": "true", width: 14, height: 14, viewBox: "0 0 24 24",
        fill: "none", stroke: "currentColor", "stroke-width": 1.8,
      }, [
        element("rect", { x: 8, y: 8, width: 12, height: 12, rx: 2 }),
        element("path", { d: "M16 8V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4" }),
      ]);
      const button = element("button", {
        type: "button", className: ["copy-code"], "aria-label": `Copy ${name} code`,
      }, [icon, element("span", {}, [text("Copy")])]);
      const toolbar = element("div", { className: ["code-toolbar"] }, [
        element("span", {}, [text(name)]), button,
      ]);
      return element("div", { className: ["code-block"] }, [toolbar, copy]);
    },
  },
});
