local M = {}

---@param path string
---@return string
function M.wire_path(path)
  return path:gsub('\\', '/')
end

---@param input string
---@return string
function M.input_path(input)
  local path = input:sub(1, 7) == 'file://'
      and vim.uri_to_fname(input)
      or input
  return vim.fs.normalize(path)
end

---@param value any
---@return any
function M.result(value)
  if type(value) ~= 'table' then return value end

  if value.uri then value.uri = M.wire_path(vim.uri_to_fname(value.uri)) end
  if value.targetUri then value.targetUri = M.wire_path(vim.uri_to_fname(value.targetUri)) end

  for key, child in pairs(value) do
    if key == 'line' or key == 'character' then
      value[key] = child + 1
    elseif type(child) == 'table' then
      M.result(child)
    end
  end

  return value
end

return M
