local M = {}

function M.show(text, level)
  local group = (level == 'wrap' or level == 'ModeMsg') and 'ModeMsg' or 'WarningMsg'
  text = tostring(text or ''):gsub('[\r\n]+', ' ')
  vim.api.nvim_echo({ { 'hexit: ' .. text, group } }, false, {})
end

return M
