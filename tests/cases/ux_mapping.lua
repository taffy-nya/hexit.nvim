local H = require('tests.helpers')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf()), path
end

return {
  { name = 'UX non-core leader prefix executes global save over local protection', run = function()
    local leader = vim.g.mapleader
    vim.g.mapleader = ' '
    vim.keymap.set('n', ' w', '<Cmd>write<CR>')
    local ok, err = xpcall(function()
      local s, path = open('AB')
      keys('rF')
      H.eq(require('hexit.document').read(s.root, 0, 2), string.char(0xF1) .. 'B')
      keys(' w')
      assert(vim.wait(3000, function() return H.read_disk(path) == string.char(0xF1) .. 'B' end, 10))
      H.eq(vim.bo[s.bufnr].modified, false)
    end, debug.traceback)
    vim.keymap.del('n', ' w')
    vim.g.mapleader = leader
    if not ok then error(err) end
  end },
  { name = 'UX slash and comma leaders save through global and buffer-local maps', run = function()
    local leader = vim.g.mapleader
    local cases = { { lhs = '\\w', global = true }, { lhs = ',w', global = false } }
    local ok, err = xpcall(function()
      for _, case in ipairs(cases) do
        vim.g.mapleader = case.lhs:sub(1, 1)
        if case.global then vim.keymap.set('n', case.lhs, '<Cmd>write<CR>') end
        local s, path = open('AB')
        if not case.global then
          vim.keymap.set('n', case.lhs, '<Cmd>write<CR>', { buffer = s.bufnr })
        end
        keys('rF')
        keys(case.lhs)
        assert(vim.wait(3000, function()
          return H.read_disk(path) == string.char(0xF1) .. 'B'
        end, 10), case.lhs)
        H.eq(vim.bo[s.bufnr].modified, false)
      end
    end, debug.traceback)
    pcall(vim.keymap.del, 'n', '\\w')
    vim.g.mapleader = leader
    if not ok then error(err) end
  end },
  { name = 'UX FileType explicit Plug mapping overrides default key after attachment', run = function()
    local group = vim.api.nvim_create_augroup('HexitUXFileTypeTest', { clear = true })
    vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'hexit', callback = function(args)
      vim.keymap.set('n', 'h', '<Plug>(Hexit-SwitchArea)', { buffer = args.buf, remap = true })
    end })
    local ok, err = xpcall(function()
      local s = open('AB')
      keys('h')
      H.eq(s.cursor.area, 'ascii')
      H.eq(s.cursor.offset, 0)
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    if not ok then error(err) end
  end },
  { name = 'UX unsupported operation reports a single native non-history message', run = function()
    local s = open('AB')
    local echo = vim.api.nvim_echo
    local messages = {}
    vim.api.nvim_echo = function(chunks, history, opts)
      messages[#messages + 1] = { chunks[1][1], history }
      return echo(chunks, history, opts)
    end
    local ok, err = xpcall(function() keys('x') end, debug.traceback)
    vim.api.nvim_echo = echo
    if not ok then error(err) end
    H.eq(messages[#messages], { 'hexit: operation not supported yet', false })
    H.eq(require('hexit.document').read(s.root, 0, 2), 'AB')
  end },
}
