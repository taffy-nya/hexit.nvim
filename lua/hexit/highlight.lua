local M = {}

local links = {
  HexOffset = 'Comment', HexOffsetCurrent = 'CursorLineNr', HexOffsetSelection = 'Visual',
  HexHeader = 'Comment', HexHeaderCurrent = 'IncSearch', HexHeaderSelection = 'Visual',
  HexHeaderMode = 'ModeMsg', HexHeaderStatus = 'Normal',
  HexByte = 'Normal', HexAscii = 'String',
  HexCursor = 'Cursor', HexCursorMatch = 'IncSearch',
  HexModified = 'DiffChange', HexSearch = 'Search',
  HexSearchCurrent = 'CurSearch', HexSelection = 'Visual',
}

function M.apply()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = target })
  end
end

function M.setup()
  M.apply()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('HexitHighlights', { clear = true }),
    callback = M.apply,
  })
end

return M
