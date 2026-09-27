# Hexit

Hexit is a Neovim 0.12+ hex-editor plugin under staged implementation. This checkout implements phase4.1 of the first-stage plan: binary snapshots, bounded Hex/ASCII navigation, Visual selection, byte editing, yank/paste, undo/redo, Copy As, binary saving, streaming exact-byte/ASCII search, and the pre-release UX corrections. Phase5 performance/CI acceptance remains separate.

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
The fixed one-line title has three window-relative parts: the left shows Hexit's logical mode (`NORMAL`, `VISUAL`, `V-LINE`, or `REPLACE`), the middle shows Hex Byte-column numbers aligned to actual Byte cells, and the right shows Visual selection length (for example `12B`, when selected), visible search count, current area (`HEX`/`ASCII`), and the 0-based Byte address. The right side aligns to the window edge and takes priority when it overlaps the ruler; narrow windows use Neovim's natural clipping with no fallback or shortened fields. There is no ASCII ruler. The title remains visible with `laststatus=0`; Hexit does not set `statusline`, `winbar`, or `laststatus`. Neovim's actual mode remains Normal except during native `/` or `?` input. The title never shows a modified/save marker.
The Hex cursor marks one nibble and the corresponding ASCII Byte. In Normal/Replace the current Hex column and row offset are highlighted; Visual highlights the selected Hex columns and row offsets without separate current-Byte/column/offset coloring. `Tab` switches areas (back to Hex high nibble). `h/j/k/l`, arrows, `w/b/e`, `0/$`, `gg/G`, and `Ctrl-u/d/f/b` navigate; decimal counts prefix motions (`2gg`, `4l`), while `0` with no preceding count means row start. Counts above 2,147,483,647 reject the entire motion; `Esc` or entry into `:` clears pending navigation input. Page keys scroll the logical viewport. Mouse clicks in a Byte cell position the cursor and the wheel scrolls three rows. `Ctrl-e`/`Ctrl-y` stay silent and cannot scroll the title away.
Hex and ASCII Byte text use the theme's `Normal` highlight by default; the Offset and Hex ruler use `LineNr`, current coordinates use `CursorLineNr`, and the opposite area of the current Byte uses `Visual`. Search, unsaved changes, and actual selection keep separate semantic groups. Customize individual `Hex*` groups with `:highlight` or `nvim_set_hl`; all default links and overlap rules are listed in `:help hexit-title`. Themes that clear user-defined groups require reapplying those overrides after ColorScheme.
The physical local `scrolloff` stays 0 to pin the title, while the viewport maintains the owner's saved user `scrolloff` as a logical margin. Changes to the local setting while in Hex are retained on exit, including inherited global values. This does not promise Neovide pixel-smooth scrolling.

Default keys are buffer-local. Core action keys take precedence; a non-core single-key protection preserves existing user mappings and waits for longer mappings such as `<leader>w`. If the leader itself is a core key, remap that core action via `<Plug>(Hexit-{Action})`. A `FileType hexit` buffer-local Plug remap overrides defaults; `mappings=false` installs only Plug mappings, while `r`/`R` still temporarily capture printable input and restore user mappings. Unsupported edit/operator keys use a short native message, not a popup. Hex windows showing one buffer share a cursor/viewport; auto width uses the narrowest window and navigation uses the active window's height.

## Select, edit, copy, save

`v` selects whole Bytes between anchor and cursor; `V` selects complete display rows (the final row ends at EOF). The title shows selection length; the Hex ruler and row offsets highlight selected columns/rows. Visual has no separate current Byte/column/offset highlight. `Tab` retains the selection while switching areas; `Esc` exits Visual without hiding completed search results. In Hex, `rF` replaces one nibble (a count replaces consecutive nibble positions); in ASCII, `rA` replaces a printable Byte. Visual `rFF`/ASCII `rA` fills the selection once. `R` overwrites in place without growing the document; `Esc` commits one undo step. Insert/Delete are not available.
During `R`, page keys, the mouse wheel, and mouse clicks do not navigate; press `Esc` before moving elsewhere.
In Hex `r`/`R`, `:` returns to the native command line (and commits an active `R` transaction). In ASCII `r`/`R`, `:` is a literal Byte; press `Esc` before `:` to issue a command.

`y` immediately yanks the current complete Byte (or up to `count` Bytes, truncated at EOF); Visual `y` yanks its selection. `p` inserts the private binary register after the current Byte, `P` before it; either inserts at offset 0 in an empty file. A count repeats the insertion as one undo step. Visual paste is intentionally unsupported. `u` and `Ctrl-r` undo and redo entire edits; saving does not clear history. Dirty highlighting compares current logical offsets to the last saved snapshot: an insertion may highlight the shifted suffix. A successful `:w` writes the binary snapshot via a temporary file then atomically replaces the source where supported; a write failure leaves the source untouched and the buffer dirty. No `:w!`, alternate write path, append, partial write, or `:saveas` is supported. Windows rename failure does not fall back to truncating the source. Concurrent external changes are not detected; do not edit the source in another process while Hexit is open. Undo history can grow with edits.
During `:w`, navigation, area switching, and viewport movement remain available; editing, paste, and undo/redo stay frozen until the save finishes.

`:HexCopyAs [format] [register]` exports the current Byte or the Visual range as text. Formats: `hex`, `compact`, `escaped`, `c`, `cstring`, `python`, `rust`, `ascii` (nonprintable bytes become `.`), `base64`. The default format comes from `default_copy_format`; the default register is the system clipboard `+`, or use `*` / `"`. A missing clipboard provider reports an error. Copy As does not change the private binary yank register. Encoding is asynchronous for large selections, and cancels if the source changes or closes.
Native `:HexCopyAs` completion offers nine formats in the first argument and `+`, `*`, `"` in the second. Use your normal command-line completion key (`Tab` by default); no plugin completion mapping is installed.

## Search

Press `/` or `?` to enter Neovim's actual search command line with normal editing, history and completion; the plugin aborts the native regex execution before it runs and searches only binary Bytes. The input kind is captured from the Hex/ASCII area at entry; a single unfinished Hex digit stays in the command line without an error. `Esc`/`Ctrl-C` there cancels only the new input, retaining the previous query/results/cursor. Empty Enter repeats the previous query (and sets this entry's direction/count); `:HexSearch hex 00 FF` or `:HexSearch ascii literal text` selects the kind explicitly. Hex accepts compact even digit pairs or whitespace-separated two-digit Bytes (optional `0x` per Byte). ASCII accepts literal printable characters including spaces; `.` and `*` are not regex. Use Hex for NUL/high Bytes. Ignorecase/smartcase are captured when starting an ASCII query; only ASCII letters fold. `n` follows the last query direction, `N` reverses it temporarily; counts can cross the boundary repeatedly but emit only one native single-line wrap message. A completed zero-result query emits `hexit: Pattern not found`. Normal `Esc` hides all search highlights/count (and cancels work), but retains the last query for `n`/`N`; Visual `Esc` only exits Visual. Edits/undo/redo rebuild a visible query without a new navigation message. The title's right side shows the visible query count as described below. Search stores counts by 64KiB block, not a per-hit list. Hexit does not sync native `@/`, native `n/N`, `searchcount()` or regex/incsearch binary previews. During Hexit input, incsearch/hlsearch are temporarily suppressed and restored afterward.

## Title and status API

The title's right side shows a search count only while results are visible: `?/?` while counting, `0/0` when there are no matches, `k/total` at a current match, or `?/total` when counting is complete without a current match. A Visual selection contributes its Byte length as `NB`; the current area and address follow. Nonempty fields are separated by two spaces. The mode stays on the left even when `show_offset=false`, and right-side information remains available when `show_ascii=false`. Overlay text replaces underlying highlights; if the left and right sides overlap, the right side wins. If a window is too narrow, Neovim clips the text naturally; Hexit does not shorten, hide fields, or wrap it.

Hexit never takes over the native statusline or winbar and never changes `laststatus`; top feedback therefore remains visible even when `laststatus=0`. Lualine is optional and is not a dependency or required configuration. Neovim 0.12.5's default statusline `%m` shows `[+-]` when a buffer is both modified and nomodifiable, and `[-]` after a successful save. In a lualine filename component, `[+]` means modified and `[-]` means nomodifiable or readonly (both can appear); `[-]` is not a saved-state marker.

`require('hexit').get_status(bufnr)` remains an optional external API. It returns a fresh read-only-by-convention snapshot, or `nil` for a non-Hexit/closed buffer; omitted/0 means current buffer. Fields: `bufnr`, `phase`, `mode`, `mode_text`, `area`, `nibble`, `size`, `offset`, `bytes_per_row`, `selection` (`start`, `stop`, `length`), `search` (`kind`, `direction`, `visible`, `pending`, `ordinal`, `total`), `input_kind`, `position_text`, `selection_text`, `range_text`, `area_text`, `search_text`. Offsets are zero-based Bytes and selections are half-open; `range_text` displays an inclusive end. Unloaded position is `--`, empty position is `(empty)`.

The `User HexitStatusChanged` event remains available to external consumers and is coalesced per event-loop turn with `data = { bufnr = N }`. Reading the snapshot does not emit the event. Hexit itself uses the title for default feedback; it does not require statusline components or plugin-specific setup.

## Development verification

From the repository root:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run.lua
```

The phase4.1 suite exercises the binary model, I/O, navigation, selection/editing, Copy As, search and UX state. Final performance/CI acceptance belongs to phase5.
