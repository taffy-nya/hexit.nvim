# hexit.nvim

A lightweight hex editor for Neovim, written in Lua.

Inspired by [hexview.nvim](https://github.com/DamianVCechov/hexview.nvim).

## Highlights

- Hex and ASCII views with synchronized cursor and selection.
- Vim-style navigation with nibble-level Hex editing.
- Search, replace, undo/redo, binary-safe yank/paste, and Copy As.
- Configurable row width, grouping, and highlights.
- Designed to stay responsive on large files without expanding them into a full text buffer.

## Requirements

- Neovim 0.12+

## Installation

### `vim.pack`

```lua
vim.pack.add({
  "https://github.com/taffy-nya/hexit.nvim",
})
```

### `lazy.nvim`

```lua
{
  "taffy-nya/hexit.nvim",
  opts = {},
}
```

Hexit does not open files automatically. Use `:Hex` to open the current file,
or `:Hex path/to/file.bin` to open another file.

## Configuration

Default options:

```lua
require("hexit").setup({
  bytes_per_row = 16,      -- 8, 16, 32, or "auto"
  byte_group_size = 1,     -- 1, 2, or 4; display only
  uppercase_hex = true,
  show_ascii = true,
  show_offset = true,
  default_copy_format = "hex",
  search_ignorecase = nil, -- nil uses vim.o.ignorecase
  search_smartcase = nil,  -- nil uses vim.o.smartcase
  mappings = true,         -- true: defaults; false or table also supported
})
```

## Usage

```vim
:Hex
:Hex path/to/file.bin
```

Opening the same path again focuses its existing Hexit buffer.

Hexit reads files as snapshots. External changes are not detected; `:write`
writes the current document back to the source file.

## Commands

| Command | Description |
| --- | --- |
| `:Hex [path]` | Open a file in Hexit. |
| `:HexGoto {offset}` | Go to a 0-based decimal or `0x` offset. |
| `:HexCol {8\|16\|32\|auto}` | Change the number of bytes per row. |
| `:HexSearch {hex\|ascii} {pattern}` | Search without using `/`. |
| `:HexCopyAs [format] [register]` | Copy the current byte or Visual selection in another format. |
| `:write` | Save changes to the source file. |

## Default keymaps

Default mappings are buffer-local. Customize them in `setup()`:

```lua
require("hexit").setup({
  mappings = {
    -- defaults = false,          -- use only the bindings below
    ["<leader>a"] = "SwitchArea",  -- bind an action
    ["<Tab>"] = false,            -- allow user mappings / native behavior
  },
})
```

See `:help hexit-keys` for the full configuration rules.

| Key | Action |
| --- | --- |
| `h` `l` `k` `j`, arrows | Move by nibble/byte or row. |
| `w` `b` `e` | Byte/word motion. |
| `gg` `G` | Go to the first/last byte, or a counted display row. |
| `0` `$` | Go to the start/end of the row. |
| `<C-u>` `<C-d>` | Scroll half a page. |
| `<C-b>` `<C-f>` | Scroll a full page. |
| `<Tab>` | Switch between Hex and ASCII areas. |
| `v` `V` | Byte / whole-row Visual selection. |
| `r` `R` | Replace a nibble/byte / enter Replace mode. |
| `y` `p` `P` | Yank / paste the private binary register. |
| `u` `<C-r>` | Undo / redo. |
| `/` `?` | Search forward / backward. |
| `n` `N` | Go to the next / previous match. |

Every action also has a stable `<Plug>(Hexit-{Action})` mapping, so the defaults
can be replaced without depending on Hexit's internal mappings.

## Help

See:

```vim
:help hexit
:help hexit-keys
```

for editing, search, Copy As, highlights, and the complete keymap reference.

