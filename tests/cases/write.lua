local document = require('hexit.document')
local io_module = require('hexit.io')
local sessions = require('hexit.session')
local H = require('tests.helpers')
local uv = vim.uv

local function open(path)
  local session = require('hexit').open(path)
  H.wait_ready(session.bufnr)
  return session
end

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function value(session)
  return document.read(session.root, 0, session.root.size)
end

local function expect_error(command)
  local ok, err = pcall(vim.cmd, command)
  assert(not ok, command .. ' unexpectedly succeeded')
  local message = tostring(err)
  assert(message:find('hexit:', 1, true) or message:find('E13: File exists', 1, true)
    or message:find('E140: Use ! to write partial buffer', 1, true),
    command .. ' did not report a write refusal: ' .. message)
  return message
end

return {
  {
    name = 'WRITE :w saves binary document and updates saved root',
    run = function()
      local original = string.char(0, 10, 13, 127, 128, 255) .. 'tail'
      local path = H.temp_file(original, 'save binary.bin')
      local session = open(path)
      local expected = string.char(0xF0) .. original:sub(2)
      keys('rF')
      H.eq(value(session), expected)

      vim.cmd('write')
      H.eq(H.read_disk(path), expected)
      H.eq(session.saved_root, session.root)
      H.eq(vim.bo[session.bufnr].modified, false)
      H.eq(session.phase, 'ready')

      -- A full rendered-buffer range is still a whole-document write.
      vim.cmd('1,$write')
      H.eq(H.read_disk(path), expected)
      H.eq(session.saved_root, session.root)
    end,
  },
  {
    name = 'WRITE alternate targets bang ranges append and rename are rejected',
    run = function()
      local original = string.char(0, 65, 255) .. 'source'
      local alternate = 'must remain untouched'
      local path = H.temp_file(original, 'write source.bin')
      local other = H.temp_file(alternate, 'write alternate.bin')
      local session = open(path)
      local buf = session.bufnr
      local name = vim.api.nvim_buf_get_name(buf)
      local saved_root = session.saved_root
      keys('rF')

      expect_error('write!')
      expect_error('write ' .. vim.fn.fnameescape(other))
      expect_error('1,2write')
      expect_error('1,2write ' .. vim.fn.fnameescape(other))
      expect_error('write >> ' .. vim.fn.fnameescape(other))
      expect_error('saveas ' .. vim.fn.fnameescape(other))
      expect_error('file ' .. vim.fn.fnameescape(other))

      H.eq(H.read_disk(path), original)
      H.eq(H.read_disk(other), alternate)
      H.eq(vim.api.nvim_buf_get_name(buf), name)
      H.eq(session.saved_root, saved_root)
      H.eq(session.phase, 'ready')
      H.eq(vim.bo[buf].modified, true)
    end,
  },
  {
    name = 'WRITE failed :wq preserves disk dirty state and real undo history',
    run = function()
      local original = string.char(0, 13, 255) .. 'before'
      local path = H.temp_file(original, 'failed wq.bin')
      local session = open(path)
      local buf = session.bufnr
      local saved_root = session.saved_root
      keys('rF')
      local edited = value(session)
      H.eq(#session.undo, 1)

      local failing_io = io_module.new({
        fs_rename = function(_, _, callback)
          callback('EIO: injected rename failure')
        end,
      })
      local old_save = io_module.save
      io_module.save = function(root, target, token, callback)
        return failing_io.save(root, target, token, callback)
      end
      local ok, err = pcall(vim.cmd, 'wq')
      io_module.save = old_save

      assert(not ok, ':wq unexpectedly succeeded after the save failed')
      assert(tostring(err):find('fs_rename', 1, true), 'the rename error did not reach :wq')
      H.eq(vim.api.nvim_buf_is_valid(buf), true)
      H.eq(vim.api.nvim_get_current_buf(), buf)
      H.eq(sessions.get(buf), session)
      H.eq(session.phase, 'ready')
      H.eq(session.saved_root, saved_root)
      H.eq(value(session), edited)
      H.eq(vim.bo[buf].modified, true)
      H.eq(H.read_disk(path), original)

      keys('u')
      H.eq(value(session), original)
      keys('<C-r>')
      H.eq(value(session), edited)
    end,
  },
  {
    name = 'WRITE failed :wq in child process remains live after error',
    run = function()
      local args = { vim.v.progpath, '--headless', '-u', 'tests/minimal_init.lua',
        '-i', 'NONE', '-l', 'tests/write_failure.lua' }
      local result = vim.system(args, { text = true }):wait(10000)
      H.eq(result.code, 0)
      local output = (result.stdout or '') .. (result.stderr or '')
      assert(output:find('WRITE_FAILURE_CHILD', 1, true), output)
    end,
  },
  {
    name = 'WRITE successful :wq saves and exits its real buffer window',
    run = function()
      local original = string.char(0, 10, 255) .. 'write and quit'
      local path = H.temp_file(original, 'successful wq.bin')
      local session = open(path)
      local buf = session.bufnr
      keys('rF')
      local expected = string.char(0xF0) .. original:sub(2)

      local hex_win = vim.api.nvim_get_current_win()
      vim.cmd('vsplit')
      vim.cmd('enew')
      local scratch_buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_set_current_win(hex_win)
      vim.cmd('wq')

      H.eq(H.read_disk(path), expected)
      H.eq(vim.bo[buf].modified, false)
      H.eq(vim.api.nvim_win_is_valid(hex_win), false)
      H.eq(vim.api.nvim_get_current_buf(), scratch_buf)
    end,
  },
  {
    name = 'WRITE saves source when the virtual buffer name is in use',
    run = function()
      local original = string.char(0, 65, 255) .. 'virtual name'
      local path = H.temp_file(original, 'occupied source name.bin')
      local source = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(source, path)
      vim.bo[source].buftype = ''
      vim.bo[source].modified = false

      local session = open(path)
      local virtual_name = vim.api.nvim_buf_get_name(session.bufnr)
      assert(virtual_name:find('^hexit://'), 'expected a virtual name because an ordinary buffer owns the path')
      keys('rF')
      local expected = string.char(0xF0) .. original:sub(2)
      vim.cmd('write')

      H.eq(vim.api.nvim_buf_get_name(session.bufnr), virtual_name)
      H.eq(H.read_disk(path), expected)
      H.eq(session.saved_root, session.root)
      H.eq(vim.bo[session.bufnr].modified, false)
    end,
  },
  {
    name = 'WRITE opens and saves a non-ASCII filename with spaces',
    run = function()
      local path = H.temp_file(string.char(0, 255), '文件 名称.bin')
      local session = open(path)
      keys('rA')
      vim.cmd('write')
      H.eq(H.read_disk(path), string.char(0xA0, 255))
      H.eq(vim.bo[session.bufnr].modified, false)
    end,
  },
  {
    name = 'WRITE wipe cancels in-flight save without reviving session',
    run = function()
      local original = 'cancel before commit'
      local path = H.temp_file(original, 'wipe during save.bin')
      local session = open(path)
      local buf = session.bufnr
      keys('rF')
      local delayed_io = io_module.new({
        fs_stat = function(target, callback)
          vim.schedule(function() uv.fs_stat(target, callback) end)
        end,
      })
      local old_save = io_module.save
      io_module.save = function(root, target, token, callback)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end)
        return delayed_io.save(root, target, token, callback)
      end
      pcall(vim.cmd, 'write')
      io_module.save = old_save

      H.eq(session.phase, 'closed')
      H.eq(session.token.cancelled, true)
      H.eq(session.root, nil)
      H.eq(session.saved_root, nil)
      H.eq(H.read_disk(path), original)
    end,
  },
  {
    name = 'WRITE delayed save permits navigation but freezes edits and undo',
    run = function()
      local original = string.rep('A', 128)
      local path = H.temp_file(original)
      local s = open(path)
      keys('rF')
      local snapshot = value(s)
      local saved = s.saved_root
      local old_save = io_module.save
      local seen
      io_module.save = function(root, target, token, callback)
        vim.schedule(function()
          local ok, err = pcall(function()
            H.eq(s.phase, 'saving')
            keys('2l')
            H.eq(s.cursor.offset, 1)
            vim.cmd('HexGoto 24')
            vim.cmd('HexBytesPerRow 8')
            keys('l')
            H.eq({ s.cursor.offset, s.cursor.nibble, s.bytes_per_row }, { 24, 1, 8 })
            keys('rFu')
            H.eq(value(s), snapshot)
            H.eq(s.saved_root, saved)
            H.eq(#s.undo, 1)
          end)
          seen = { ok, err }
        end)
        vim.defer_fn(function() old_save(root, target, token, callback) end, 50)
      end
      local ok, err = pcall(vim.cmd, 'write')
      io_module.save = old_save
      assert(ok, err)
      assert(seen and seen[1], seen and seen[2] or 'save did not service navigation')
      H.eq(H.read_disk(path), snapshot)
      H.eq(s.cursor.offset, 24)
      H.eq(s.phase, 'ready')
      H.eq(vim.bo[s.bufnr].modified, false)
    end,
  },
}
