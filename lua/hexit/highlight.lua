local M = {}

local links = {
  HexOffset = 'LineNr', HexOffsetCurrent = 'CursorLineNr', HexOffsetSelection = 'Visual',
  HexHeader = 'LineNr', HexHeaderCurrent = 'CursorLineNr', HexHeaderSelection = 'Visual',
  HexHeaderMode = 'ModeMsg', HexHeaderStatus = 'Normal',
  HexByte = 'Normal', HexAscii = 'Normal',
  HexCursor = 'Cursor', HexCursorMatch = 'MatchParen',
  HexModified = 'DiffText', HexSearch = 'Search',
  HexSearchCurrent = 'CurSearch', HexSelection = 'Visual',
}

function M.apply()
  for name, target in pairs(links) do
    if name == 'HexModified' and vim.o.background == 'light' then target = 'DiffChange' end
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
