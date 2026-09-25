local H = require('tests.helpers')
local sessions = require('hexit.session')

return {
  {
    name = 'ENTRY Hex loads binary and reuses session',
    run = function()
      local path = H.temp_file(H.bytes(0, 10, 13, 127, 128, 255), 'space name.bin')
      vim.cmd('Hex ' .. vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      local session = H.wait_ready(buf)
      H.eq(require('hexit.document').read(session.root, 0, 6), H.bytes(0, 10, 13, 127, 128, 255))
      H.eq(vim.bo[buf].buftype, 'acwrite')
      H.eq(vim.bo[buf].modifiable, false)
      H.eq(vim.bo[buf].modified, false)
      H.eq(#vim.api.nvim_buf_get_lines(buf, 0, -1, false), 1)
      vim.cmd('Hex ' .. vim.fn.fnameescape(path))
      H.eq(vim.api.nvim_get_current_buf(), buf)
      vim.api.nvim_buf_delete(buf, { force = true })
      H.eq(sessions.get(buf), nil)
      H.eq(sessions.find(path), nil)
    end,
  },
  {
    name = 'ENTRY unnamed and modified source are rejected',
    run = function()
      local path = H.temp_file('hello')
      vim.cmd('enew!')
      local ok = pcall(require('hexit').open)
      H.eq(ok, false)
      vim.api.nvim_buf_set_name(0, path)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'changed' })
      ok = pcall(require('hexit').open)
      H.eq(ok, false)
      H.eq(sessions.find(path), nil)
    end,
  },
  {
    name = 'ENTRY missing file reports error without ready root',
    run = function()
      local path = H.temp_file('temporary')
      assert(vim.uv.fs_unlink(path))
      local session = require('hexit').open(path)
      local completed = vim.wait(5000, function() return session.phase ~= 'loading' end, 10)
      assert(completed)
      H.eq(session.phase, 'error')
      H.eq(session.root, nil)
      assert(vim.api.nvim_buf_get_lines(session.bufnr, 0, 1, false)[1]:find('error', 1, true))
    end,
  },
  {
    name = 'ENTRY strict configuration affects only new sessions',
    run = function()
      local hexit = require('hexit')
      H.eq(pcall(hexit.setup, { bytes_per_row = 12 }), false)
      H.eq(pcall(hexit.setup, { imaginary = true }), false)
      H.eq(pcall(hexit.setup, { search_ignorecase = 'yes' }), false)
      hexit.setup({ bytes_per_row = 8, byte_group_size = 2 })
      local first = hexit.open(H.temp_file('first'))
      H.wait_ready(first.bufnr)
      hexit.setup({ bytes_per_row = 32 })
      local second = hexit.open(H.temp_file('second'))
      H.wait_ready(second.bufnr)
      H.eq(first.bytes_per_row, 8)
      H.eq(second.bytes_per_row, 32)
      hexit.setup()
    end,
  },
  {
    name = 'ENTRY wiping during load cannot restore a closed buffer',
    run = function()
      local path = H.temp_file(string.rep(string.char(0, 255), 4 * 1024 * 1024))
      local session = require('hexit').open(path)
      local buf = session.bufnr
      vim.api.nvim_buf_delete(buf, { force = true })
      H.eq(session.phase, 'closed')
      assert(vim.wait(200, function() return not vim.api.nvim_buf_is_valid(buf) end, 10))
      H.eq(sessions.get(buf), nil)
      H.eq(sessions.find(path), nil)
      H.eq(session.root, nil)
    end,
  },
}
