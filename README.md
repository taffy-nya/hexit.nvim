# Hexit

Hexit is a Neovim 0.12+ hex-editor plugin under staged implementation. This checkout currently implements **phase1 of the first-stage plan**: a binary snapshot model, asynchronous file loading, and internal safe snapshot saving. It does **not** yet provide hex rows, navigation, editing, search, or user-facing `:w` support. Do not use it to edit files yet.

## Load a binary snapshot

Add this directory to `runtimepath` (or install it as a normal Neovim plugin), then run `:Hex path/to/file.bin`. Run `:Hex` from an unmodified, named ordinary buffer to open that buffer's file. The new buffer shows a temporary loading summary with byte progress, followed by a ready/error summary; it never contains a text conversion of the binary file. Reopening the same path focuses the existing Hex buffer. Opening a file is a snapshot: concurrent source-file changes are not detected; do not modify the file elsewhere while working in Hexit.

Optional setup before opening:

```lua
require('hexit').setup({ bytes_per_row = 16, byte_group_size = 1 })
```

Configuration is validated on setup and applies to subsequent sessions. Display and editing configuration takes effect when the later implementation phases provide those features; the complete phase-one-to-five plan is in `.agent/impl-plan/`.

## Development verification

From the repository root:

```sh
nvim --headless -u tests/minimal_init.lua -i NONE -l tests/run.lua
```

The phase1 suite exercises the binary model, real-file asynchronous load and internal safe save. User-facing editing, saving, and TUI acceptance belong to later phases; they are not claimed by this README.
