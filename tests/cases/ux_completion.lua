local H = require('tests.helpers')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

return {
  { name = 'UX native command-line completion expands format without exporting', run = function()
    local path = H.temp_file('A')
    vim.cmd('Hex ' .. vim.fn.fnameescape(path))
    local s = H.wait_ready(vim.api.nvim_get_current_buf())
    local seen = {}
    local group = vim.api.nvim_create_augroup('HexitUXCompletionTest', { clear = true })
    vim.api.nvim_create_autocmd('CmdlineChanged', { group = group, callback = function()
      if vim.fn.getcmdtype() == ':' then seen[#seen + 1] = vim.fn.getcmdline() end
    end })
    local ok, err = xpcall(function()
      keys(':HexCopyAs base<Tab><Esc>')
      assert(vim.tbl_contains(seen, 'HexCopyAs base64'), vim.inspect(seen))
      H.eq(require('hexit.document').read(s.root, 0, 1), 'A')
      local candidates = vim.fn.getcompletion('HexCopyAs ', 'cmdline')
      H.eq(candidates, { 'hex', 'compact', 'escaped', 'c', 'cstring', 'python', 'rust', 'ascii', 'base64' })
      H.eq(vim.fn.getcompletion('HexCopyAs hex ', 'cmdline'), { '+', '*', '"' })
      H.eq(vim.fn.getcompletion('HexCopyAs hex + ', 'cmdline'), {})
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    if not ok then error(err) end
  end },
  { name = 'UX completion respects editing position, literal register and Ex modifier', run = function()
    local complete = require('hexit.commands').complete_copy_as
    H.eq(complete('c', ':silent HexCopyAs c +', #':silent HexCopyAs c'), { 'compact', 'c', 'cstring' })
    H.eq(complete('*', ':HexCopyAs hex *', #':HexCopyAs hex *'), { '*' })
    H.eq(complete('+', ':HexCopyAs hex +', #':HexCopyAs hex +'), { '+' })
    H.eq(complete('"', ':HexCopyAs hex "', #':HexCopyAs hex "'), { '"' })
  end },
  { name = 'UX user wildchar completes through native command line', run = function()
    local old_wildchar, old_wildmode = vim.o.wildchar, vim.o.wildmode
    local seen = {}
    local group = vim.api.nvim_create_augroup('HexitUXWildcharTest', { clear = true })
    vim.api.nvim_create_autocmd('CmdlineChanged', { group = group, callback = function()
      if vim.fn.getcmdtype() == ':' then seen[#seen + 1] = vim.fn.getcmdline() end
    end })
    local ok, err = xpcall(function()
      vim.cmd('set wildchar=<C-L>')
      keys(':HexCopyAs pyt<C-L><Esc>')
      assert(vim.tbl_contains(seen, 'HexCopyAs python'), vim.inspect(seen))
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    vim.o.wildchar, vim.o.wildmode = old_wildchar, old_wildmode
    if not ok then error(err) end
  end },
}
