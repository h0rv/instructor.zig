const status = document.getElementById("copy-status");

for (const button of document.querySelectorAll(".copy-code")) {
  const code = button.closest(".code-block")?.querySelector("pre code");
  if (!code) continue;
  const buttonLabel = button.querySelector("span");

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
