# Hexit

Hexit is a Neovim 0.12+ hex-editor plugin under staged implementation. This checkout implements **phase2 of the first-stage plan**: binary snapshots, a bounded Hex/ASCII viewport, and read-only navigation. Editing, search, and user-facing `:w` are not available yet; do not use it to edit files.

## Load a binary snapshot

Add this directory to `runtimepath` (or install it as a normal Neovim plugin), then run `:Hex path/to/file.bin`. Run `:Hex` from an unmodified, named ordinary buffer to open that buffer's file. The independent Hexit buffer initially displays loading progress and then viewport rows with Offset, Hex and ASCII columns. Reopening the same path focuses the existing Hex buffer. Opening a file is a snapshot: concurrent source-file changes are not detected; do not modify the file elsewhere while using Hexit.

Optional setup before opening:

```lua
require('hexit').setup({
  bytes_per_row = 16,     -- 8, 16, 32, or 'auto' (largest fitting width)
  byte_group_size = 1,    -- 1, 2, or 4
  uppercase_hex = true,
  show_ascii = true,
  show_offset = true,
  mappings = true,
})
```

Configuration is validated on setup and applies to subsequent sessions. `:HexBytesPerRow 8|16|32|auto` changes the current buffer's layout without changing its Byte position. `:HexGoto 0x10` or `:HexGoto 16` moves to 0-based Byte offset 16; invalid and out-of-file offsets fail rather than clamp.
The fixed one-line title is followed by viewport data rows. The Hex cursor marks one nibble; the corresponding ASCII Byte is highlighted as well. `Tab` switches areas (back to Hex high nibble). `h/j/k/l`, arrows, `w/b/e`, `0/$`, `gg/G`, and `Ctrl-u/d/f/b` navigate; decimal counts prefix motions (`2gg`, `4l`), while `0` with no preceding count means row start. Counts above 2,147,483,647 reject the entire motion; `Esc` or entry into `:` clears pending navigation input. In Hex, horizontal movement is nibble-based; in ASCII, word movement uses ASCII word/whitespace/punctuation classes. Page keys scroll the logical viewport. Mouse clicks in a Byte cell position the cursor and the wheel scrolls three rows. Default `Ctrl-e`/`Ctrl-y` are blocked rather than scrolling the rendered text.

Default keys are buffer-local. `mappings=false` leaves stable `<Plug>(Hexit-{Action})` mappings for custom keys but disables the default capture layer. Unsupported edit/operator keys show a warning instead of modifying viewport text. Windows showing the same Hexit buffer share a logical cursor and viewport; auto row width uses the narrowest visible window. The tallest window determines how many rows are rendered, but navigation and the visible cursor follow the active window's height. When a short window owns the viewport near EOF, a taller window may show blank rows after the final Byte. The viewport never stores a full-file Hex conversion. Snapshot saving is currently an internal API only; do not expect `:w` to save binary changes in this phase.
Hex uses a temporary window-local `scrolloff=0` to keep the title visible. Leaving Hex restores the previous local setting, including inheritance from the global `scrolloff` value.

## Development verification

From the repository root:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run.lua
```

The phase2 suite exercises the binary model, snapshot I/O, layout, logical navigation, and real `:Hex`/key-mapping integration. Editing, saving, search, and final TUI acceptance belong to later phases.
