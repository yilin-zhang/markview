# markview.el

A read-only Markdown preview for Emacs, inspired by
[markview.nvim](https://github.com/OXY2DEV/markview.nvim).

Uses **tree-sitter** for robust block-level parsing and **overlays** for
rendering.  The preview lives in an indirect buffer — your source buffer
is never modified.

## Requirements

- Emacs 29.1+ (native tree-sitter)
- Tree-sitter `markdown` grammar
- A Nerd Font for callout/image icons (optional but recommended)

Install the grammar with:

```
M-x treesit-install-language-grammar RET markdown RET
```

When prompted for the repository URL, use:
`https://github.com/tree-sitter-grammars/tree-sitter-markdown`
with subdirectory `tree-sitter-markdown/src`.

## Usage

```elisp
(require 'markview)

;; Split-view: source on the left, preview on the right
M-x markview-open

;; Full-window: preview only (q to return to source)
C-u M-x markview-open

;; Close the preview
M-x markview-close

;; Toggle
M-x markview-toggle
```

### Preview Buffer Keybindings

| Key     | Action                                  |
|---------|-----------------------------------------|
| `q`     | Close preview (return to source)        |
| `RET`   | Open link at point                      |
| mouse-1 | Open link under mouse                   |

## Features

### Block-Level Rendering

- **ATX headings** (h1–h6) with decorative bullets and scaled sizes
- **Setext headings** with underline hidden
- **Fenced code blocks** with box-drawing borders and preserved syntax highlighting
- **Pipe tables** with box-drawing borders, column alignment, and accurate
  width measurement via `string-pixel-width` (handles CJK and icon glyphs)
- **Block quotes** with left border bar
- **Callouts** (`> [!NOTE]`, `> [!WARNING]`, etc.) with Nerd Font icons and titles
- **Lists** (unordered with depth-dependent bullets, ordered with styled numbers)
- **Checkboxes** (`☑` / `☐` replacement)
- **Horizontal rules** rendered as a line of dashes

### Inline Rendering

- **Links** — clickable in paragraphs (RET / mouse-1 to open)
- **Images** — Nerd Font icon + alt-text display
- **Bold**, *italic*, ~~strikethrough~~
- `Inline code` spans
- Autolinks (`<https://...>`)

## Customization

| Variable                   | Default | Description                      |
|----------------------------|---------|----------------------------------|
| `markview-window-size`     | 0.5     | Preview window width (fraction)  |
| `markview-refresh-delay`   | 0.08    | Idle delay before refresh (secs) |
| `markview-heading-bullets` | `["◉" "○" "✦" "◆" "▸" "·"]` | Bullets for h1–h6 |
| `markview-list-bullets`    | `["●" "○" "◆" "◇" "▸" "▹"]` | Bullets for list depth 0–5 |
| `markview-callout-labels`  | …       | Display names for callout types  |
| `markview-callout-icons`   | …       | Nerd Font icons for callout types|

All faces are named `markview-*-face` and use `:inherit` for theme
compatibility.

## Architecture

- **Parser**: tree-sitter `markdown` grammar in the source buffer
- **Rendering**: overlay-based, dispatched per block type
- **Sync**: `post-command-hook` mirrors point/scroll between buffers;
  `after-change-functions` triggers debounced re-render
- **Preview buffer**: read-only indirect buffer, displayed as a side window
  (default) or full-window (`C-u`)
