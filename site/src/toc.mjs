export function buildToc(headings) {
  const roots = [];
  const stack = [];
  for (const heading of headings) {
    if (heading.depth < 2 || heading.depth > 4) continue;
    const item = { ...heading, children: [] };
    while (stack.length && stack.at(-1).depth >= item.depth) stack.pop();
    if (stack.length) stack.at(-1).children.push(item);
    else roots.push(item);
    stack.push(item);
  }
  return roots;
}
