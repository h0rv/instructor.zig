const icon = '<svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4"/></svg>';
const status = document.getElementById("copy-status");

for (const pre of document.querySelectorAll("article pre")) {
  const code = pre.querySelector("code");
  if (!code) continue;
  const block = document.createElement("div");
  block.className = "code-block";
  pre.before(block);
  block.append(pre);

  const language = pre.dataset.language || "text";
  const name = { zig: "Zig", sh: "Shell", bash: "Shell", json: "JSON", text: "Text" }[language] || language;
  const toolbar = document.createElement("div");
  toolbar.className = "code-toolbar";
  const label = document.createElement("span");
  label.textContent = name;
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-code";
  button.setAttribute("aria-label", `Copy ${name} code`);
  button.innerHTML = icon + "<span>Copy</span>";
  const buttonLabel = button.querySelector("span");
  toolbar.append(label, button);
  block.prepend(toolbar);

  button.addEventListener("click", async () => {
    button.disabled = true;
    try {
      await navigator.clipboard.writeText(code.textContent || "");
      buttonLabel.textContent = "Copied";
      button.dataset.copied = "true";
      status.textContent = "Code copied to clipboard.";
    } catch {
      const range = document.createRange();
      range.selectNodeContents(code);
      const selection = window.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
      buttonLabel.textContent = "Selected";
      status.textContent = "Clipboard unavailable. Code selected for manual copying.";
    } finally {
      button.disabled = false;
      window.setTimeout(() => {
        buttonLabel.textContent = "Copy";
        delete button.dataset.copied;
      }, 2000);
    }
  });
}
