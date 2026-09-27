if vim.g.loaded_hexit then return end
if vim.fn.has('nvim-0.12') ~= 1 then
  error('hexit: Neovim 0.12 or newer is required')
end

vim.api.nvim_create_user_command('Hex', function(command)
  require('hexit').open(command.args ~= '' and command.args or nil)
end, { nargs = '?', complete = 'file' })
vim.api.nvim_create_user_command('HexGoto', function(command)
  require('hexit.commands').goto_offset(command.args)
end, { nargs = 1 })
vim.api.nvim_create_user_command('HexBytesPerRow', function(command)
  require('hexit.commands').bytes_per_row(command.args)
end, { nargs = 1, complete = function() return { '8', '16', '32', 'auto' } end })
vim.api.nvim_create_user_command('HexCopyAs', function(command)
  require('hexit.commands').copy_as(command.args)
end, {
  nargs = '*',
  complete = function(arglead, cmdline, cursorpos)
    return require('hexit.commands').complete_copy_as(arglead, cmdline, cursorpos)
  end,
})
vim.api.nvim_create_user_command('HexSearch', function(command)
  require('hexit.commands').search(command.args)
end, { nargs = '+', complete = function() return { 'hex', 'ascii' } end })
require('hexit.highlight').setup()
vim.g.loaded_hexit = true
