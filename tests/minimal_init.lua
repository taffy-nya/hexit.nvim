local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
vim.o.columns = 80
vim.o.lines = 24
vim.cmd('runtime plugin/hexit.lua')
