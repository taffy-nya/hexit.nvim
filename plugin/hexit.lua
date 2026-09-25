if vim.g.loaded_hexit then return end
if vim.fn.has('nvim-0.12') ~= 1 then
  error('hexit: Neovim 0.12 or newer is required')
end

vim.api.nvim_create_user_command('Hex', function(command)
  require('hexit').open(command.args ~= '' and command.args or nil)
end, { nargs = '?', complete = 'file' })
vim.g.loaded_hexit = true
