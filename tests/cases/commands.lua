local H = require('tests.helpers')
local sessions = require('hexit.session')
local io_module = require('hexit.io')

local function expect_failure(command, fragment)
  local ok, err = pcall(vim.cmd, command)
  assert(not ok, command .. ' unexpectedly succeeded')
  local message = tostring(err)
  assert(message:find(fragment, 1, true), ('%s: %s'):format(command, message))
  return message
end

local function open(path)
  local session = require('hexit').open(path)
  H.wait_ready(session.bufnr)
  return session
end

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

return {
  {
    name = 'COMMANDS require a Hexit buffer and reject the loading phase',
    run = function()
      vim.cmd('enew!')
      for _, command in ipairs({ 'HexGoto 0', 'HexCol 8', 'HexSearch hex 00', 'HexCopyAs hex "' }) do
        expect_failure(command, 'command requires a Hexit buffer')
      end

      -- open() publishes the buffer before the asynchronous snapshot lands.
      local session = require('hexit').open(H.temp_file('AB'))
      H.eq(session.phase, 'loading')
      for _, command in ipairs({ 'HexGoto 0', 'HexCol 8', 'HexSearch hex 41', 'HexCopyAs hex "' }) do
        expect_failure(command, 'binary snapshot is not ready')
      end
      H.eq(session.cursor.offset, 0)
      H.eq(session.bytes_per_row, 16)

      H.wait_ready(session.bufnr)
      vim.cmd('HexGoto 1')
      H.eq(session.cursor.offset, 1)
      vim.cmd('HexCol 8')
      H.eq(session.bytes_per_row, 8)
    end,
  },
  {
    name = 'COMMANDS freeze model changes while a save is in flight',
    run = function()
      local path = H.temp_file('AB')
      local session = open(path)
      keys('rF')
      local old_save = io_module.save
      local seen
      io_module.save = function(root, target, token, callback)
        vim.schedule(function()
          local ok, err = xpcall(function()
            H.eq(session.phase, 'saving')
            -- Read-only navigation and layout stay available during :w.
            vim.cmd('HexGoto 1')
            H.eq(session.cursor.offset, 1)
            vim.cmd('HexCol 8')
            H.eq(session.bytes_per_row, 8)
            -- Model-changing commands and exports are rejected.
            expect_failure('HexSearch hex 41', 'binary snapshot is not ready')
            expect_failure('HexCopyAs hex "', 'binary snapshot is not ready')
          end, debug.traceback)
          seen = { ok, err }
        end)
        vim.defer_fn(function() old_save(root, target, token, callback) end, 50)
      end
      local ok, err = pcall(vim.cmd, 'write')
      io_module.save = old_save
      assert(ok, err)
      assert(seen and seen[1], seen and seen[2] or 'save did not service the guard checks')
      H.eq(session.phase, 'ready')
      H.eq(H.read_disk(path), string.char(0xF1) .. 'B')
    end,
  },
  {
    name = 'COMMANDS empty documents reject goto and copy but keep layout and search',
    run = function()
      local session = open(H.temp_file(''))
      H.eq(session.root.size, 0)
      expect_failure('HexGoto 0', 'empty file has no Byte to navigate to')
      expect_failure('HexCopyAs hex "', 'no Byte to copy')
      vim.cmd('HexCol 32')
      H.eq(session.bytes_per_row, 32)
      vim.cmd('HexSearch ascii a')
      assert(vim.wait(5000, function()
        return session.search and session.search.total ~= nil
      end, 10))
      H.eq(session.search.total, 0)
      H.eq(vim.api.nvim_get_current_buf(), session.bufnr)
    end,
  },
  {
    name = 'UI window close and re-entry keep one session per path per document',
    run = function()
      local first_path = H.temp_file('AAAA', 'commands first.bin')
      local second_path = H.temp_file('BBBB', 'commands second.bin')
      local first = open(first_path)
      local first_win = vim.api.nvim_get_current_win()
      vim.cmd('vsplit')
      local second_win = vim.api.nvim_get_current_win()
      local second = open(second_path)
      H.eq(vim.api.nvim_win_get_buf(second_win), second.bufnr)
      H.eq(first.bufnr == second.bufnr, false)

      -- Independent cursors and viewports per document.
      vim.cmd('HexGoto 3')
      H.eq(second.cursor.offset, 3)
      H.eq(first.cursor.offset, 0)
      vim.api.nvim_set_current_win(first_win)
      vim.cmd('HexGoto 2')
      H.eq(first.cursor.offset, 2)
      H.eq(second.cursor.offset, 3)

      -- Closing the last window of a document does not close the session.
      vim.api.nvim_set_current_win(second_win)
      vim.api.nvim_win_close(second_win, true)
      H.eq(sessions.get(second.bufnr), second)
      H.eq(sessions.find(second_path), second)
      H.eq(second.phase, 'ready')
      H.eq(second.cursor.offset, 3)

      -- Reopening a path focuses the existing buffer instead of reloading.
      vim.cmd('Hex ' .. vim.fn.fnameescape(first_path))
      H.eq(vim.api.nvim_get_current_buf(), first.bufnr)
      H.eq(sessions.get(first.bufnr), first)
      H.eq(first.cursor.offset, 2)

      -- Wiping one session leaves the other document untouched.
      vim.api.nvim_buf_delete(first.bufnr, { force = true })
      H.eq(sessions.get(first.bufnr), nil)
      H.eq(sessions.find(first_path), nil)
      H.eq(sessions.get(second.bufnr), second)

      -- Re-entry after a wipe starts a fresh, independent session.
      local reopened = open(first_path)
      H.eq(reopened.bufnr == first.bufnr, false)
      H.eq(reopened.bufnr == second.bufnr, false)
      H.eq(reopened.cursor.offset, 0)
      H.eq(reopened.revision, 0)
      H.eq(reopened.phase, 'ready')
      H.eq(second.cursor.offset, 3)
      H.eq(require('hexit.document').read(reopened.root, 0, 4), 'AAAA')
    end,
  },
}
