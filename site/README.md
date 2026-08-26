# The PenAI site

Two things live here, both static and both hostable anywhere that serves files:

- `index.html` - the landing page.
- `docs/` - the documentation, generated from the markdown in `../docs/`.

## Rebuilding the docs

```bash
python3 scripts/build-site.py
```

Edit the markdown in `docs/`, never the HTML in `site/docs/`: the generator
overwrites it. The generator needs nothing but Python 3.

## Hosting it

`.github/workflows/pages.yml` publishes this folder to GitHub Pages on every
push to `main` that touches the docs, the site or the assets. Turn it on under
**Settings → Pages → Source: GitHub Actions**.

Any other static host works too: upload the contents of `site/` as-is. There is
no build step at serve time, no external font and no CDN dependency.

To read it locally:

```bash
python3 -m http.server --directory site 8000
```
