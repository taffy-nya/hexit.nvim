# Hexit

Hexit is a Neovim 0.12+ binary Hex/ASCII editor implementing the first-stage feature set end to end: asynchronous binary snapshots, bounded virtual Offset/Hex/ASCII viewports, nibble/Byte editing, Visual selection and Fill, a private binary yank register with growing paste, undo/redo, Copy As, exact-Byte/ASCII streaming search, and safe binary saving. It has no runtime third-party dependency, does not shell out to `xxd`, and does not use FFI. Loading below Neovim 0.12 reports an explicit error and registers no commands.

The user documentation lives in `:help hexit` (`:help hexit-commands`, `:help hexit-keys`, `:help hexit-search`, `:help hexit-editing`, `:help hexit-copy-as`, `:help hexit-title`). This README summarizes installation, keys and verification.

## Install

Copy or clone this repository into a `runtimepath` entry; no build step and no dependency is required.

```lua
-- lazy.nvim
{ dir = '/path/to/hexit.nvim' }
-- or plain runtimepath
vim.opt.runtimepath:prepend('/path/to/hexit.nvim')
```

`:Hex` is registered once on plugin load; Hexit never opens a file on its own.

## Load a binary snapshot

Run `:Hex path/to/file.bin`. Run `:Hex` from an unmodified, named ordinary buffer to open that buffer's file. The independent Hexit buffer initially displays loading progress and then viewport rows with Offset, Hex and ASCII columns. Reopening the same path focuses the existing Hex buffer. Opening a file is a snapshot: concurrent source-file changes are not detected; do not modify the file elsewhere while using Hexit.

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

Configuration is validated on setup and applies to subsequent sessions. `:HexCol 8|16|32|auto` changes the current buffer's layout without changing its Byte position. `:HexGoto 0x10` or `:HexGoto 16` moves to 0-based Byte offset 16; invalid and out-of-file offsets fail rather than clamp.
The fixed one-line title has three window-relative parts: the left shows Hexit's logical mode (`NORMAL`, `VISUAL`, `V-LINE`, or `REPLACE`), the middle shows Hex Byte-column numbers aligned to actual Byte cells, and the right shows Visual selection length (for example `12B`, when selected), visible search count, current area (`HEX`/`ASCII`), and the 0-based Byte address. A one-column margin precedes the mode and every data row (including offsets); one blank column follows the right-aligned title address. The right side takes priority when it overlaps the ruler; narrow windows use Neovim's natural clipping with no fallback or shortened fields. There is no ASCII ruler. The title remains visible with `laststatus=0`; Hexit does not set `statusline`, `winbar`, or `laststatus`. Neovim's actual mode remains Normal except during native `/` or `?` input. The title never shows a save/dirty marker: `vim.bo.modified` tracks real binary content, and default statusline/lualine filename markers may reflect both modified and nomodifiable states.
The Hex cursor marks one nibble and the corresponding ASCII Byte. In Normal/Replace the current Hex column and row offset are highlighted; Visual highlights the selected Hex columns and row offsets without separate current-Byte/column/offset coloring. `Tab` switches areas (back to Hex high nibble). `h/j/k/l`, arrows, `w/b/e`, `0/$`, `gg/G`, and `Ctrl-u/d/f/b` navigate; decimal counts prefix motions (`2gg`, `4l`), while `0` with no preceding count means row start. Counts above 2,147,483,647 reject the entire motion; `Esc` or entry into `:` clears pending navigation input. Page keys scroll the logical viewport. Mouse clicks in a Byte cell position the cursor and the wheel scrolls three rows. `Ctrl-e`/`Ctrl-y` stay silent and cannot scroll the title away.
Hex and ASCII Byte text use the theme's `Normal` highlight by default; the Offset and Hex ruler use `LineNr`, current coordinates use `CursorLineNr`, and the opposite area of the current Byte uses `MatchParen` for a more visible corresponding Byte. Unsaved changes default to `DiffText` on dark backgrounds and `DiffChange` on light backgrounds when a colorscheme is applied; changing only `background` may require reapplying the colorscheme to update that link. Customize individual `Hex*` groups with `:highlight` or `nvim_set_hl`; all default links and overlap rules are listed in `:help hexit-title`. Themes that clear user-defined groups require reapplying those overrides after ColorScheme.
The physical local `scrolloff` stays 0 to pin the title, while the viewport maintains the owner's saved user `scrolloff` as a logical margin. Changes to the local setting while in Hex are retained on exit, including inherited global values. This does not promise Neovide pixel-smooth scrolling.

Default keys are buffer-local. Core action keys take precedence; a non-core single-key protection preserves existing user mappings and waits for longer mappings such as `<leader>w`. If the leader itself is a core key, remap that core action via `<Plug>(Hexit-{Action})`. A `FileType hexit` buffer-local Plug remap overrides defaults; `mappings=false` installs only Plug mappings, while `r`/`R` still temporarily capture printable input and restore user mappings. Unsupported edit/operator keys use a short native message, not a popup. Hex windows showing one buffer share a cursor/viewport; auto width uses the narrowest window and navigation uses the active window's height.

## Select, edit, copy, save

`v` selects whole Bytes between anchor and cursor; `V` selects complete display rows (the final row ends at EOF). The title shows selection length; selected Hex ruler columns and row offsets use Visual without inheriting the `LineNr` text color, so their labels remain legible. Visual keeps the current Byte's opposite-area `HexCursorMatch` above selection, while the active cell and current column/offset have no separate highlight. `Tab` retains the selection while switching areas; `Esc` exits Visual without hiding completed search results. In Hex, `rF` replaces one nibble (a count replaces consecutive nibble positions); in ASCII, `rA` replaces a printable Byte. Visual `rFF`/ASCII `rA` fills the selection once. `R` overwrites in place without growing the document; `Esc` commits one undo step. Insert/Delete are not available.
During `R`, page keys, the mouse wheel, and mouse clicks do not navigate; press `Esc` before moving elsewhere.
In Hex `r`/`R`, `:` returns to the native command line (and commits an active `R` transaction). In ASCII `r`/`R`, `:` is a literal Byte; press `Esc` before `:` to issue a command.

`y` immediately yanks the current complete Byte (or up to `count` Bytes, truncated at EOF); Visual `y` yanks its selection. `p` inserts the private binary register after the current Byte, `P` before it; either inserts at offset 0 in an empty file. A count repeats the insertion as one undo step. Visual paste is intentionally unsupported. `u` and `Ctrl-r` undo and redo entire edits; saving does not clear history. Dirty highlighting compares current logical offsets to the last saved snapshot: an insertion may highlight the shifted suffix. A successful `:w` writes the binary snapshot via a temporary file then atomically replaces the source where supported; a write failure leaves the source untouched and the buffer dirty. No `:w!`, alternate write path, append, partial write, or `:saveas` is supported. Windows rename failure does not fall back to truncating the source. Concurrent external changes are not detected; do not edit the source in another process while Hexit is open. Undo history can grow with edits.
During `:w`, navigation, area switching, and viewport movement remain available; editing, paste, and undo/redo stay frozen until the save finishes.

`:HexCopyAs [format] [register]` exports the current Byte or the Visual range as text. Formats: `hex`, `compact`, `escaped`, `c`, `cstring`, `python`, `rust`, `ascii` (nonprintable bytes become `.`), `base64`. The default format comes from `default_copy_format`; the default register is the system clipboard `+`, or use `*` / `"`. A missing clipboard provider reports an error. Copy As does not change the private binary yank register. Encoding is asynchronous for large selections, and cancels if the source changes or closes.
Native `:HexCopyAs` completion offers nine formats in the first argument and `+`, `*`, `"` in the second. Use your normal command-line completion key (`Tab` by default); no plugin completion mapping is installed.

## Keys and `<Plug>` mappings

Every supported action has a stable buffer-local `<Plug>(Hexit-{Action})` mapping. Default keys (installed unless `mappings=false`) only forward to those mappings:

| Default key | Action | `<Plug>` name |
|---|---|---|
| `h` `l` `k` `j`, arrows | nibble/Byte, then row motion | `Left`, `Right`, `Up`, `Down` |
| `w` `b` `e` | Byte/word motion | `WordNext`, `WordPrev`, `WordEnd` |
| `g` `g` | first Byte / counted display row | `GPrefix` then `First` |
| `G` | last Byte / counted display row | `Last` |
| `0` `$` | row start / row end | `Digit0` (start), `RowEnd` |
| `<C-u>` `<C-d>` | half page | `HalfUp`, `HalfDown` |
| `<C-b>` `<C-f>` | full page | `PageUp`, `PageDown` |
| `<Tab>` | Hex/ASCII area | `SwitchArea` |
| `v` `V` | Byte / linewise Visual | `Visual`, `VisualLine` |
| `r` `R` | replace nibble/Byte, Replace Mode | `Replace`, `ReplaceMode` |
| `y` | yank to the private binary register | `Yank` |
| `p` `P` | paste after / before | `PasteAfter`, `PasteBefore` |
| `u` `<C-r>` | undo / redo | `Undo`, `Redo` |
| `/` `?` | search forward / backward | `SearchForward`, `SearchBackward` |
| `n` `N` | next / previous match | `SearchNext`, `SearchPrev` |
| `<Esc>` | clear pending input/Visual, hide search | `Escape` |
| `0`–`9` | counts (`0` alone is row start) | `Digit0` … `Digit9` |
| other printable ASCII (`!`–`~`, space) | literal data input for `r`/`R` | `CharXX` (`Char41` for `A`) |
| wheel | scroll three rows | `WheelUp`, `WheelDown` |
| `<C-e>` `<C-y>` | intercepted native scroll | `Unsupported` (silent no-op) |

User mappings win where they exist: Hexit skips a default key when a mapping with the same key is already present, a longer `<leader>`-style mapping is still reachable, and a `FileType hexit` buffer-local mapping to a `<Plug>(Hexit-…)` name replaces the default. With `mappings=false` no default keys are installed at all; `r`/`R` still install their temporary data keys and restore the user's mappings on exit.

## Limitations

- First stage only: no Insert (`i`/`a`/`I`/`A`), no delete (`x`, `d`, Visual `p`), no read-only browsing mode, no external-change detection/reload/force-write UI, no expression offsets, no named-register integration, no automatic binary-file detection, and no text/Hex round-trip mode. Unsupported edit keys report one native message and never touch the rendered buffer.
- Search covers exact Byte sequences and printable ASCII literals only; no wildcards, regex, multi-encoding or search-and-replace, and ignorecase folds ASCII `A`–`Z` only.
- `H`/`M`/`L`, `zt`/`zz`/`zb`, `f`/`F`/`t`/`T`/`;`/`,` and Visual delete are not implemented.
- Multiple windows showing one Hex buffer share a single cursor and viewport; per-window independent scrolling is not supported.
- Copy As writes text out; system-clipboard Paste and Paste From Text belong to the second stage. `:w` only writes the whole document back to the source path (`:w!`, `:w other`, ranges, append, `:saveas` are refused).
- Opening is a snapshot and saving overwrites the target from that snapshot: modify the source file in another process neither while Hexit is open nor before saving.
- Undo history is unbounded and lives in Lua memory, so memory grows with the number of edits. Measured on Windows 10.0.26200/Neovim 0.12.5: after 10,000 single-Byte edits on a 50 MiB document the Lua heap reached ~100 MB and process RSS grew ~1.9 GB, most of it allocator retention rather than live Lua data.

## Search

Press `/` or `?` to enter Neovim's actual search command line with normal editing, history and completion; the plugin aborts the native regex execution before it runs and searches only binary Bytes. The input kind is captured from the Hex/ASCII area at entry; a single unfinished Hex digit stays in the command line without an error. `Esc`/`Ctrl-C` there cancels only the new input, retaining the previous query/results/cursor. Empty Enter repeats the previous query (and sets this entry's direction/count); `:HexSearch hex 00 FF` or `:HexSearch ascii literal text` selects the kind explicitly. Hex accepts compact even digit pairs or whitespace-separated two-digit Bytes (optional `0x` per Byte). ASCII accepts literal printable characters including spaces; `.` and `*` are not regex. Use Hex for NUL/high Bytes. Ignorecase/smartcase are captured when starting an ASCII query; only ASCII letters fold. `n` follows the last query direction, `N` reverses it temporarily; counts can cross the boundary repeatedly but emit only one native single-line wrap message. A completed zero-result query emits `hexit: Pattern not found`. Normal `Esc` hides all search highlights/count (and cancels work), but retains the last query for `n`/`N`; Visual `Esc` only exits Visual. Edits/undo/redo rebuild a visible query without a new navigation message. The title's right side shows the visible query count as described below. Search stores counts by 64KiB block, not a per-hit list. Hexit does not sync native `@/`, native `n/N`, `searchcount()` or regex/incsearch binary previews. During Hexit input, incsearch/hlsearch are temporarily suppressed and restored afterward.

## Title and status API

The title's right side shows a search count only while results are visible: `?/?` while counting, `0/0` when there are no matches, `k/total` at a current match, or `?/total` when counting is complete without a current match. A Visual selection contributes its Byte length as `NB`; the current area and address follow. Nonempty fields are separated by two spaces. The mode stays on the left even when `show_offset=false`, and right-side information remains available when `show_ascii=false`. Overlay text replaces underlying highlights; if the left and right sides overlap, the right side wins. If a window is too narrow, Neovim clips the text naturally; Hexit does not shorten, hide fields, or wrap it.

Hexit never takes over the native statusline or winbar and never changes `laststatus`; top feedback therefore remains visible even when `laststatus=0`. Lualine is optional and is not a dependency or required configuration. Neovim 0.12.5's default statusline `%m` shows `[+-]` when a buffer is both modified and nomodifiable, and `[-]` after a successful save. In a lualine filename component, `[+]` means modified and `[-]` means nomodifiable or readonly (both can appear); `[-]` is not a saved-state marker.

`require('hexit').get_status(bufnr)` remains an optional external API. It returns a fresh read-only-by-convention snapshot, or `nil` for a non-Hexit/closed buffer; omitted/0 means current buffer. Fields: `bufnr`, `phase`, `mode`, `mode_text`, `area`, `nibble`, `size`, `offset`, `bytes_per_row`, `selection` (`start`, `stop`, `length`), `search` (`kind`, `direction`, `visible`, `pending`, `ordinal`, `total`), `input_kind`, `position_text`, `selection_text`, `range_text`, `area_text`, `search_text`. Offsets are zero-based Bytes and selections are half-open; `range_text` displays an inclusive end. Unloaded position is `--`, empty position is `(empty)`.

The `User HexitStatusChanged` event remains available to external consumers and is coalesced per event-loop turn with `data = { bufnr = N }`. Reading the snapshot does not emit the event. Hexit itself uses the title for default feedback; it does not require statusline components or plugin-specific setup.

## Verification

From the repository root:

```sh
# full suite (real Neovim, no external test dependency)
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run.lua

# 50 MiB performance and memory report (writes tmp/perf.json)
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/perf.lua

# help tags
nvim --headless -u tests/minimal_init.lua -i NONE "+helptags doc" +qa
```

`tests/run.lua` covers the binary model and bounds, asynchronous I/O and write failure injection, layout/hit testing, navigation and counts, splits and option restoration, selection/editing/history, Copy As goldens, streaming search races, command error paths, session lifecycle, and the UX state machine. `tests/perf.lua` generates its own 50 MiB fixtures, enforces the plan thresholds locally, and asserts the deterministic parts (exact match totals, bounded viewport, block-based dense index) everywhere; `HEXIT_PERF_CI=1` makes wall-clock numbers report-only for shared runners and `HEXIT_PERF_OUT` selects the JSON path.

Measured on Windows 10.0.26200 x64 / Neovim 0.12.5 with warm cache: 50 MiB open to ready 79 ms (threshold 2000 ms), navigation and single-nibble edits p95 16 ms / max 23 ms (50/100 ms), exact `DEADBEEF` count 234 ms and ASCII ignorecase count 1.3 s (15000 ms), 50 MiB of zeros indexed in 3.1 ms with 800 block counters and exact total 52,428,800, 1 MiB fill + undo/redo each under 4 ms (300 ms), and 10,000 single-Byte edits at p95 6 ms with the piece table staying at 51 pieces. The JSON report is written to `tmp/perf.json`.

`.github/workflows/test.yml` runs the suite on `ubuntu-latest` and `windows-latest` against Neovim `v0.12.5` and the current `stable`, installs Neovim from the official release and fails if the detected version is below 0.12, and uploads the Linux performance JSON as an artifact. The workflow itself has not been executed here; the YAML was parsed locally.
