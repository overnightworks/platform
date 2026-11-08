# An app's legal files

For whoever writes an app's legal files. It says what an app ships and the form `mise run legal:check <key> <dir>`
accepts; the assembled pages and their link targets are not judged yet.

## What an app ships

- `legal/datenschutz.html` in the app's repository, which every app needs.
- `legal/nutzungsbedingungen.html`, which is optional and is checked when present.

Each is a regular file: a link or a directory in its place is refused, and so is a `<dir>` that is no directory.
`<key>` is the app's key; it is the `h2` id of both files.

## Format

German, UTF-8 without a byte order mark, at most 65,536 bytes, LF line ends, no control character other than LF.

```
fragment := WS h2 WS (block WS)* (section WS)*
h2       := '<h2 id="' KEY '">' TEXT '</h2>'
section  := '<section id="' KEY '-' SLUG '">' WS h3 WS (block WS)+ '</section>'
h3       := '<h3>' TEXT '</h3>'
block    := '<p>' INLINE+ '</p>' | ('<ul>'|'<ol>') WS ('<li>' INLINE+ '</li>' WS)+ ('</ul>'|'</ol>')
INLINE   := TEXT | '<br>' | ('<strong>'|'<em>'|'<code>') TEXT ('</strong>'|'</em>'|'</code>') | '<a href="' HREF '">' TEXT '</a>'
TEXT     := one or more characters; & < > written exactly as &amp; &lt; &gt;; no other character reference
WS       := spaces and LF only (may be empty)
```

Refused: any other element or attribute, a second, duplicate or valueless attribute; comments, doctype, CDATA and
processing instructions; a section in a section, a link in a link, a list in a paragraph or in a list item; an empty
paragraph or list item; text outside a paragraph, list item or heading; an unclosed element, or anything but
whitespace after the last closing tag. Between block tags any run of spaces and line feeds, or none, is free; a tab,
a no-break space or a control character is refused.

## Canonical form

Every token is checked against the grammar and written out again: lowercase tags, ` id="…"` and ` href="…"` with one
space and double quotes, `<br>` without a slash, text escaped as `&amp;`, `&lt;`, `&gt;` only. A file whose rewritten
form differs from its bytes is refused at the first differing line, so a file is published byte for byte or not at
all. Write `ä` or a no-break space as the character, never `&nbsp;`; a literal `"` in text stays valid.

## Ids

The `h2` id is the key. Every other id starts with `<key>-` followed by `[a-z0-9]+(-[a-z0-9]+)*`, and `titel` is
reserved as the last word.

## Links

- `https://` with a host of two or more lowercase labels (no port, user, IP address or `#`), then an optional path
  and query;
- `mailto:name@host` without a query;
- `#id`;
- `/impressum`, `/datenschutz` or `/nutzungsbedingungen`, optionally with `#id`.

A link to these pages written in full on the zone's apex or `www` is refused: write the short form. The zone is the
host of the Ingress in `infrastructure/legal/legal.yaml`.

## The refusal line

`legal: <path relative to dir>: line N: <rule>`, on stderr with exit 1, never quoting the text; it may name the
offending tag or attribute. On success `legal:check: <key> valid: <pages>` and exit 0. The command writes nothing.
