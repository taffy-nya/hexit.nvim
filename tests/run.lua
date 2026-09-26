local helpers = require('tests.helpers')
local modules = {
  'tests.cases.doc',
  'tests.cases.io',
  'tests.cases.entry',
  'tests.cases.layout',
  'tests.cases.motion',
  'tests.cases.navigation',
  'tests.cases.edit',
  'tests.cases.format',
  'tests.cases.copy',
  'tests.cases.write',
}
local failed, total = 0, 0

for _, module_name in ipairs(modules) do
  local cases = require(module_name)
  for _, case in ipairs(cases) do
    total = total + 1
    helpers.begin_case()
    local ok, err = xpcall(case.run, debug.traceback)
    local cleaned, cleanup_err = xpcall(helpers.end_case, debug.traceback)
    if not cleaned then ok, err = false, (err or '') .. '\ncleanup: ' .. cleanup_err end
    if ok then
      print('PASS ' .. case.name)
    else
      failed = failed + 1
      print('FAIL ' .. case.name .. '\n' .. err)
    end
  end
end
print(('%d/%d passed'):format(total - failed, total))
if failed > 0 then vim.cmd('cquit 1') else vim.cmd('qa!') end
