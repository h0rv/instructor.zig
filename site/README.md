# Documentation site

The site uses the existing repository Markdown and Zig's generated API documentation. It is static HTML with local missing.css. Code-copy buttons are rendered in the initial HTML. A small script handles clipboard clicks without moving the content. Navigation works without JavaScript.

Use Node 24 or later and Zig 0.17.0.

```sh
cd site
npm ci
npm run dev
```

Open http://localhost:4321. The API reference is at /api/.

Run `npm run build` to generate `site/dist`, or `npm test` to check Markdown link rewriting. Set `ZIG` if the Zig executable is not on your path. Set `DOCS_BASE=/instructor.zig/` when building for GitHub Pages.

Edit `README.md` or `docs/*.md` in the repository. There is no second copy of the guides. Restart the preview after changing Zig source to regenerate the API reference.

missing.css 1.3.0 is bundled in `public/missing.css`. Its BSD license is in `public/missing.LICENSE`. The GitHub icon is from Octicons, with its MIT license in `public/octicons.LICENSE`.
