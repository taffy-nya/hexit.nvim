# Hexit

Hexit is a Neovim 0.12+ hex-editor plugin under staged implementation. This checkout implements **phase4 of the first-stage plan**: binary snapshots, bounded Hex/ASCII navigation, Visual selection, byte editing, yank/paste, undo/redo, Copy As, binary saving, and streaming exact-byte/ASCII search.

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
  default_copy_format = 'hex',
  search_ignorecase = nil, -- nil reads vim.o.ignorecase when starting a query
  search_smartcase = nil,  -- nil reads vim.o.smartcase when starting a query
  mappings = true,
})
```

Configuration is validated on setup and applies to subsequent sessions. `:HexBytesPerRow 8|16|32|auto` changes the current buffer's layout without changing its Byte position. `:HexGoto 0x10` or `:HexGoto 16` moves to 0-based Byte offset 16; invalid and out-of-file offsets fail rather than clamp.
The fixed one-line title is followed by viewport data rows. The Hex cursor marks one nibble; the corresponding ASCII Byte is highlighted as well. `Tab` switches areas (back to Hex high nibble). `h/j/k/l`, arrows, `w/b/e`, `0/$`, `gg/G`, and `Ctrl-u/d/f/b` navigate; decimal counts prefix motions (`2gg`, `4l`), while `0` with no preceding count means row start. Counts above 2,147,483,647 reject the entire motion; `Esc` or entry into `:` clears pending navigation input. In Hex, horizontal movement is nibble-based; in ASCII, word movement uses ASCII word/whitespace/punctuation classes. Page keys scroll the logical viewport. Mouse clicks in a Byte cell position the cursor and the wheel scrolls three rows. Default `Ctrl-e`/`Ctrl-y` are blocked rather than scrolling the rendered text.

Default keys are buffer-local. `mappings=false` leaves stable `<Plug>(Hexit-{Action})` mappings for custom keys but disables the default capture layer; `r`/`R` temporarily capture printable input and restore your mappings on exit. Unsupported edit/operator keys show a warning instead of modifying viewport text. Windows showing the same Hexit buffer share a logical cursor and viewport; auto row width uses the narrowest visible window. The tallest window determines how many rows are rendered, but navigation and the visible cursor follow the active window's height. When a short window owns the viewport near EOF, a taller window may show blank rows after the final Byte. The viewport never stores a full-file Hex conversion.
Hex uses a temporary window-local `scrolloff=0` to keep the title visible. Leaving Hex restores the previous local setting, including inheritance from the global `scrolloff` value.

## Select, edit, copy, save

`v` selects whole Bytes between anchor and cursor; `V` selects complete display rows (the final row ends at EOF). The title shows the selection length. `Tab` retains the selection while switching areas; `Esc` exits. In Hex, `rF` replaces one nibble (a count replaces that many nibble positions with the same digit); in ASCII, `rA` replaces one Byte (a count repeats the printable character). With Visual active, `rFF` or ASCII `rA` fills the selection once and exits. An incomplete or invalid replacement never writes. `R` overwrites as you type, crossing Byte/row boundaries without growing the file; `Esc` commits all its edits as one undo step. At EOF, further characters are rejected. Hex input accepts digits 0–9/A–F; ASCII input accepts printable single-byte ASCII, including space. Insert and Delete are not available in this phase.
During `R`, page keys, the mouse wheel, and mouse clicks do not navigate; press `Esc` before moving elsewhere.
When the viewport is wide enough, the title keeps the full mode and Visual Byte count at its left edge; a long status may cover the first column-number labels, but never the data rows.
In Hex `r`/`R`, `:` returns to the native command line (and commits an active `R` transaction). In ASCII `r`/`R`, `:` is a literal Byte; press `Esc` before `:` to issue a command.

`y` immediately yanks the current complete Byte (or up to `count` Bytes, truncated at EOF); Visual `y` yanks its selection. `p` inserts the private binary register after the current Byte, `P` before it; either inserts at offset 0 in an empty file. A count repeats the insertion as one undo step. Visual paste is intentionally unsupported. `u` and `Ctrl-r` undo and redo entire edits; saving does not clear history. Dirty highlighting compares current logical offsets to the last saved snapshot: an insertion may highlight the shifted suffix. A successful `:w` writes the binary snapshot via a temporary file then atomically replaces the source where supported; a write failure leaves the source untouched and the buffer dirty. No `:w!`, alternate write path, append, partial write, or `:saveas` is supported. Windows rename failure does not fall back to truncating the source. Concurrent external changes are not detected; do not edit the source in another process while Hexit is open. Undo history can grow with edits.
During `:w`, navigation, area switching, and viewport movement remain available; editing, paste, and undo/redo stay frozen until the save finishes.

`:HexCopyAs [format] [register]` exports the current Byte or the Visual range as text. Formats: `hex`, `compact`, `escaped`, `c`, `cstring`, `python`, `rust`, `ascii` (nonprintable bytes become `.`), `base64`. The default format comes from `default_copy_format`; the default register is the system clipboard `+`, or use `*` / `\"`. A missing clipboard provider reports an error. Copy As does not change the private binary yank register. Encoding is asynchronous for large selections, and cancels if the source changes or closes.

## Search

Press `/` or `?` for a forward or backward prompt in the current Hex/ASCII area; `:HexSearch hex 00 FF` or `:HexSearch ascii literal text` selects the kind explicitly. Hex accepts compact even digit pairs or whitespace-separated two-digit Bytes (optional `0x` per Byte). ASCII accepts literal printable characters including spaces; `.` and `*` are not regex. Use Hex for NUL/high Bytes. Ignorecase and smartcase are captured when starting an ASCII query; only ASCII letters fold. `n` follows the last query direction, `N` reverses it temporarily, and counts wrap through overlapping matches. `Esc` cancels an in-progress navigation; edits/undo/redo rescan the changed snapshot. The title shows the current ordinal/total or `searching…` while scanning; both Byte areas highlight visible matches, with the current match distinct. Search stores counts by 64KiB block rather than a per-hit list.

## Development verification

From the repository root:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run.lua
```

The phase4 suite exercises the binary model, snapshot I/O, navigation, selection, editing, history, binary saving, Copy As, streaming search, and search UI. Final TUI acceptance belongs to phase5.
