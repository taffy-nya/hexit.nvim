local H = require('tests.helpers')
local document = require('hexit.document')

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf())
end
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function wait_reg(expected)
  assert(vim.wait(3000, function() return vim.fn.getreg('"') == expected end, 10),
    'Copy As output did not reach unnamed register')
end

return {
  {
    name = 'COPY command selects Byte or Visual range without changing binary yank',
    run = function()
      local s = open(H.bytes(0, 65, 127, 255))
      local binary_before = require('hexit.actions').register()
      vim.fn.setreg('"', 'old', 'v')
      vim.cmd('HexCopyAs hex "')
      wait_reg('00')
      keys('v6l')
      H.eq(s.mode, 'visual')
      vim.cmd('HexCopyAs base64 "')
      wait_reg('AEF//w==')
      H.eq(s.mode, 'visual')
      H.eq(s.cursor.offset, 3)
      H.eq(require('hexit.actions').register(), binary_before)
      H.eq(pcall(vim.cmd, 'HexCopyAs invalid "'), false)
      vim.fn.setreg('"', '', 'v')
    end,
  },
  {
    name = 'COPY async export cancels on edited source and does not commit old output',
    run = function()
      local s = open(string.rep('A', 200000))
      keys('V')
      vim.cmd('HexGoto 199999')
      vim.fn.setreg('"', 'untouched', 'v')
      vim.cmd('HexCopyAs compact "')
      require('hexit.actions').begin(s)
      require('hexit.actions').apply(s, 0, 1, document.from_chunks({ 'B' }))
      require('hexit.actions').commit(s)
      vim.wait(100, function() return false end, 10)
      H.eq(vim.fn.getreg('"'), 'untouched')
      vim.fn.setreg('"', '', 'v')
    end,
  },
  {
    name = 'COPY large command export streams Base64 across a 64KiB boundary',
    run = function()
      local data = string.rep(H.bytes(0, 65, 127, 255), 20000)
      local s = open(data)
      keys('v')
      vim.cmd('HexGoto ' .. (#data - 1))
      vim.fn.setreg('"', 'old', 'v')
      vim.cmd('HexCopyAs base64 "')
      local expected = vim.base64.encode(data)
      assert(vim.wait(5000, function() return vim.fn.getreg('"') == expected end, 10))
      H.eq(s.mode, 'visual')
      H.eq(s.cursor.offset, #data - 1)
      vim.fn.setreg('"', '', 'v')
    end,
  },
  {
    name = 'COPY system provider receives exact text and linewise register type',
    run = function()
      local old = vim.g.clipboard
      local received
      vim.g.clipboard = {
        name = 'hexit-copy-test',
        copy = {
          ['+'] = function(lines, regtype) received = { lines, regtype } end,
          ['*'] = function(lines, regtype) received = { lines, regtype } end,
        },
        paste = { ['+'] = function() return {}, 'v' end, ['*'] = function() return {}, 'v' end },
        cache_enabled = 0,
      }
      local ok, err = xpcall(function()
        local s = open(H.bytes(0, 65, 127, 255))
        vim.cmd('HexCopyAs hex +')
        assert(vim.wait(2000, function() return received ~= nil end, 10))
        H.eq(received, { { '00' }, 'v' })
        received = nil
        keys('v6l')
        vim.cmd('HexCopyAs base64 *')
        assert(vim.wait(2000, function() return received ~= nil end, 10))
        H.eq(received, { { 'AEF//w==' }, 'v' })
        H.eq(s.mode, 'visual')
      end, debug.traceback)
      vim.g.clipboard = old
      if not ok then error(err) end
    end,
  },
  {
    name = 'COPY missing system provider refuses output but unnamed text register works',
    run = function()
      local command = { vim.v.progpath, '--headless', '-u', 'tests/minimal_init.lua',
        '-i', 'NONE', '-l', 'tests/no_clipboard.lua' }
      local result = vim.system(command, { text = true }):wait(10000)
      H.eq(result.code, 0)
    end,
  },
}
