# Fork notes

Personal fork of [neurocyte/flow](https://github.com/neurocyte/flow).
Upstream is tracked but this fork is not intended to be merged back.

## Local changes

| Commit | Area | What |
| --- | --- | --- |
| `3b968c8` | `src/tui/info_view.zig` | Render LSP markdown documentation: tree-sitter highlighted code fences, horizontal rules, paragraph breaks, headings, inline emphasis stripping |

### Why the markdown patch exists

Language servers such as [ols](https://github.com/DanielGavin/ols) reply with
`MarkupKind.markdown` even though flow advertises `documentationFormat` and
`contentFormat` as `plaintext`. Upstream `src/tui` has no markdown handling at
all, so raw ` ```odin ` fences, `---` rules and `**emphasis**` markers were
printed verbatim into the completion and hover info boxes.

`append_content` now parses the documentation instead of passing it through:

- fenced code blocks are highlighted with tree-sitter, using the fence language
  tag to look up a static file type, and are left unreflowed so that capture
  column offsets stay valid
- captures are stored per line as scope spans and resolved against the active
  theme at render time through `find_scope_style`, so the info box follows
  whatever theme is loaded
- `---` draws as a horizontal rule
- blank lines are preserved (runs collapsed) so paragraphs separate
- headings lose their `#` markers and take the `keyword` scope
- inline `**` and backticks are stripped; underscores are left alone because
  they are far more likely to be part of an identifier

Every failure path (unknown language tag, parser creation, allocation) falls
back to plain text rather than erroring.

Known trade-offs:

- a tree-sitter parser is created and destroyed per info box render, which is
  fine for doc snippets but is not cached
- long lines inside code blocks are clipped rather than wrapped, deliberately:
  wrapping would invalidate the column offsets the highlighting depends on

## Toolchain

Requires **Zig 0.16.0** (upstream `master` targets it; the 0.7.2 release was
built with 0.15.2). Installed at `D:\zig-0.16.0`.

## Rebuild and install

```powershell
.\rebuild.ps1
```

Quit any running `flow` first, or the script will rename the locked binary out
of the way (Windows will not overwrite a running executable).

## Syncing with upstream

```powershell
git fetch upstream
git rebase upstream/master
.\rebuild.ps1
```

If `src/tui/info_view.zig` conflicts, upstream has touched the info box.
Re-apply the change against their version rather than taking either side
wholesale — the anchor points are `append_content`, `render` and the `lines`
field, which this fork changes from `[]const u8` to a `Line` struct.

## Related upstream issues worth watching

- ols ignoring the client's declared `documentationFormat`
- flow having no markdown renderer for LSP content
