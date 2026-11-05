// Token colors from https://ziglang.org/documentation/master/.
// Shiki supplies the grammar; these themes follow Zig's light and dark palettes.
function theme(name, type, palette) {
  return {
    name, type,
    colors: { "editor.foreground": palette.text, "editor.background": palette.background },
    tokenColors: [
      { scope: ["keyword", "storage"], settings: { foreground: palette.keyword, fontStyle: "bold" } },
      { scope: ["keyword.operator", "punctuation"], settings: { foreground: palette.text, fontStyle: "" } },
      { scope: ["string"], settings: { foreground: palette.string } },
      { scope: ["comment"], settings: { foreground: palette.comment, fontStyle: "italic" } },
      { scope: ["entity.name.function"], settings: { foreground: palette.function, fontStyle: "bold" } },
      { scope: ["support.function.builtin"], settings: { foreground: palette.builtin, fontStyle: "" } },
      { scope: ["constant", "keyword.constant"], settings: { foreground: palette.number, fontStyle: "" } },
      { scope: ["entity.name.type", "keyword.type", "support.type"], settings: { foreground: palette.type, fontStyle: "bold" } },
    ],
  };
}

export const zigLight = theme("zig-light", "light", {
  text: "#000000", background: "#f8f8f8", keyword: "#333333",
  string: "#dd1144", builtin: "#005c7a", comment: "#545454",
  function: "#990000", number: "#005c5c", type: "#445588",
});
export const zigDark = theme("zig-dark", "dark", {
  text: "#cccccc", background: "#222222", keyword: "#eeeeee",
  string: "#22ee55", builtin: "#ff894c", comment: "#aaaa77",
  function: "#b1a0f8", number: "#ff8080", type: "#6688ff",
});
