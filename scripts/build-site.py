#!/usr/bin/env python3
"""
Render docs/*.md into the static documentation site under site/docs/.

Deliberately not a markdown library: the site has to be buildable on a machine
that has nothing installed but Python, which is the same argument the project
makes about the pendrive itself. The converter handles exactly the subset the
docs use -- headings, paragraphs, nested lists, fenced code, tables, block
quotes, rules and inline code/bold/links -- and nothing else.

Usage: python3 scripts/build-site.py
"""

from __future__ import annotations

import html
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, 'docs')
OUT = os.path.join(ROOT, 'site', 'docs')

# Order of the sidebar. Anything in docs/ that is missing here is still built,
# and gets appended to the end of the nav.
NAV = [
    ('Start here', ['STATUS.md', 'OVERVIEW.md', 'REQUIREMENTS.md']),
    ('Build a drive', ['MODELS.md', 'PENDRIVE.md', 'BUILD.md', 'DEVELOPMENT.md']),
    ('Live with it', ['USAGE.md', 'TROUBLESHOOTING.md', 'LIMITATIONS.md', 'PRIVACY.md']),
    ('Deeper', ['ARCHITECTURE.md', 'TESTING.md']),
]

TITLES = {
    'STATUS.md': 'Status',
    'OVERVIEW.md': 'Overview',
    'REQUIREMENTS.md': 'Requirements',
    'MODELS.md': 'Model setup',
    'PENDRIVE.md': 'Preparing the pendrive',
    'BUILD.md': 'Building a release',
    'DEVELOPMENT.md': 'Development setup',
    'USAGE.md': 'Running PenAI',
    'TROUBLESHOOTING.md': 'Troubleshooting',
    'LIMITATIONS.md': 'Known limitations',
    'PRIVACY.md': 'Privacy and security',
    'ARCHITECTURE.md': 'Architecture',
    'TESTING.md': 'Testing',
}

INLINE_CODE = re.compile(r'`([^`]+)`')
BOLD = re.compile(r'\*\*([^*]+)\*\*')
LINK = re.compile(r'\[([^\]]+)\]\(([^)]+)\)')


def slug(text: str) -> str:
    s = re.sub(r'`', '', text).strip().lower()
    s = re.sub(r'[^a-z0-9 \-]', '', s)
    return re.sub(r'\s+', '-', s)


def href(target: str) -> str:
    """Rewrite a repo-relative markdown link for the generated site."""
    if target.startswith(('http://', 'https://', 'mailto:', '#')):
        return target
    path, _, anchor = target.partition('#')
    anchor = f'#{anchor}' if anchor else ''
    if path == 'README.md':
        return f'index.html{anchor}'
    if path == '../README.md':
        return f'../index.html{anchor}'
    if path.endswith('.md'):
        return os.path.basename(path)[:-3] + '.html' + anchor
    # Anything else lives in the repository, not on the site.
    return 'https://github.com/' + path.lstrip('./') + anchor


def inline(text: str) -> str:
    """Escape, then re-introduce the inline markup we support."""
    out = html.escape(text, quote=False)
    codes: list[str] = []

    def stash(m: re.Match[str]) -> str:
        codes.append(m.group(1))
        return f'\x00{len(codes) - 1}\x00'

    out = INLINE_CODE.sub(stash, out)
    out = BOLD.sub(r'<strong>\1</strong>', out)
    out = LINK.sub(lambda m: f'<a href="{html.escape(href(m.group(2)), quote=True)}">{m.group(1)}</a>', out)
    for i, c in enumerate(codes):
        out = out.replace(f'\x00{i}\x00', f'<code>{c}</code>')
    return out


def convert(md: str) -> tuple[str, str]:
    """Return (page title, body html)."""
    lines = md.split('\n')
    out: list[str] = []
    title = ''
    i = 0
    # (kind, indent) for every list currently open, outermost first.
    stack: list[tuple[str, int]] = []

    def close_lists(to_indent: int = -1) -> None:
        while stack and stack[-1][1] > to_indent:
            kind, _ = stack.pop()
            out.append(f'</{kind}>')

    while i < len(lines):
        line = lines[i]

        if line.startswith('```'):
            lang = line[3:].strip()
            close_lists()
            body: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                body.append(lines[i])
                i += 1
            i += 1
            cls = f' class="lang-{html.escape(lang, quote=True)}"' if lang else ''
            out.append(f'<pre><code{cls}>{html.escape(chr(10).join(body), quote=False)}</code></pre>')
            continue

        if not line.strip():
            close_lists()
            i += 1
            continue

        m = re.match(r'^(#{1,6}) (.*)$', line)
        if m:
            close_lists()
            level = len(m.group(1))
            text = m.group(2).strip()
            if level == 1 and not title:
                title = re.sub(r'`', '', text)
                out.append(f'<h1>{inline(text)}</h1>')
            else:
                out.append(f'<h{level} id="{slug(text)}">{inline(text)}</h{level}>')
            i += 1
            continue

        if re.match(r'^(-{3,}|\*{3,})\s*$', line):
            close_lists()
            out.append('<hr>')
            i += 1
            continue

        # Table: a header row followed by a |---|---| separator.
        if line.lstrip().startswith('|') and i + 1 < len(lines) and re.match(
            r'^\s*\|[\s:|-]+\|\s*$', lines[i + 1]
        ):
            close_lists()
            def cells(row: str) -> list[str]:
                return [c.strip() for c in row.strip().strip('|').split('|')]

            head = cells(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith('|'):
                rows.append(cells(lines[i]))
                i += 1
            out.append('<div class="tablewrap"><table><thead><tr>')
            out.extend(f'<th>{inline(c)}</th>' for c in head)
            out.append('</tr></thead><tbody>')
            for r in rows:
                out.append('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>')
            out.append('</tbody></table></div>')
            continue

        if line.lstrip().startswith('>'):
            close_lists()
            quote: list[str] = []
            while i < len(lines) and lines[i].lstrip().startswith('>'):
                quote.append(lines[i].lstrip()[1:].lstrip())
                i += 1
            # A quote can carry its own heading -- the format warning does.
            out.append('<blockquote>')
            para: list[str] = []

            def flush() -> None:
                if para:
                    out.append(f'<p>{inline(" ".join(para))}</p>')
                    para.clear()

            for q in quote:
                h = re.match(r'^(#{1,6}) (.*)$', q)
                if h:
                    flush()
                    out.append(f'<p class="kicker">{inline(h.group(2))}</p>')
                elif q:
                    para.append(q)
                else:
                    flush()
            flush()
            out.append('</blockquote>')
            continue

        m = re.match(r'^(\s*)([-*]|\d+\.) (.*)$', line)
        if m:
            indent = len(m.group(1))
            kind = 'ul' if m.group(2) in ('-', '*') else 'ol'
            close_lists(indent)
            if not stack or stack[-1][1] < indent:
                out.append(f'<{kind}>')
                stack.append((kind, indent))
            item = [m.group(3)]
            i += 1
            # Continuation lines belong to the item they are indented under.
            while i < len(lines) and lines[i].strip() and not re.match(
                r'^\s*([-*]|\d+\.) ', lines[i]
            ) and lines[i].startswith(' ' * (indent + 2)):
                item.append(lines[i].strip())
                i += 1
            out.append(f'<li>{inline(" ".join(item))}</li>')
            continue

        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(
            r'^(#{1,6} |```|\||> |\s*([-*]|\d+\.) |-{3,})', lines[i]
        ):
            para.append(lines[i].strip())
            i += 1
        close_lists()
        out.append(f'<p>{inline(" ".join(para))}</p>')

    close_lists()
    return title or 'PenAI', '\n'.join(out)


def nav_html(current: str) -> str:
    known = {f for _, files in NAV for f in files}
    extra = sorted(
        f for f in os.listdir(DOCS)
        if f.endswith('.md') and f != 'README.md' and f not in known
    )
    groups = list(NAV) + ([('More', extra)] if extra else [])
    parts = ['<nav class="docnav">',
             f'<a href="index.html"{" class=\"current\"" if current == "README.md" else ""}>All documentation</a>']
    for label, files in groups:
        parts.append(f'<span class="kicker">{label}</span>')
        for f in files:
            if not os.path.exists(os.path.join(DOCS, f)):
                continue
            cls = ' class="current"' if f == current else ''
            name = TITLES.get(f, f[:-3].title())
            parts.append(f'<a href="{f[:-3]}.html"{cls}>{name}</a>')
    parts.append('</nav>')
    return '\n'.join(parts)


SHELL = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} - PenAI docs</title>
<meta name="description" content="{desc}">
<link rel="icon" href="../assets/mark.svg">
<link rel="stylesheet" href="../style.css">
</head>
<body>
<header class="topbar">
  <div class="topbar-in">
    <a href="../index.html"><img src="../assets/wordmark.svg" alt="PenAI"></a>
    <nav>
      <a href="../index.html">Home</a>
      <a href="index.html">Docs</a>
      <a class="btn btn-ghost" href="https://github.com/">Source</a>
    </nav>
  </div>
</header>
<div class="docs">
{nav}
<article class="doc">
{body}
<p class="doc-foot">Part of the PenAI documentation. Everything here also
reads as plain markdown in the repository under <code>docs/</code>.</p>
</article>
</div>
</body>
</html>
"""


def main() -> int:
    if not os.path.isdir(DOCS):
        print('docs/ not found', file=sys.stderr)
        return 1
    os.makedirs(OUT, exist_ok=True)

    sources = sorted(f for f in os.listdir(DOCS) if f.endswith('.md'))
    for f in sources:
        md = open(os.path.join(DOCS, f), encoding='utf-8').read()
        title, body = convert(md)
        # The nav already says where you are, so drop the breadcrumb line the
        # markdown carries for GitHub readers.
        body = re.sub(r'<p><a href="index\.html">[^<]*</a>[^<]*<a href="\.\./index\.html">[^<]*</a></p>\n?', '', body, count=1)
        desc = re.sub(r'<[^>]+>', '', body.split('</p>')[0])[:160].strip()
        name = 'index' if f == 'README.md' else f[:-3]
        page = SHELL.format(
            title=html.escape(title, quote=True),
            desc=html.escape(desc, quote=True),
            nav=nav_html(f),
            body=body,
        )
        open(os.path.join(OUT, name + '.html'), 'w', encoding='utf-8').write(page)
        print(f'  site/docs/{name}.html')

    images = os.path.join(DOCS, 'images')
    if os.path.isdir(images):
        shutil.copytree(images, os.path.join(OUT, 'images'), dirs_exist_ok=True)

    print(f'built {len(sources)} pages into site/docs/')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
