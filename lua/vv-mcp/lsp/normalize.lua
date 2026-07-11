---统一 MCP 与 LSP 之间的路径及坐标表示
local M = {}

---将路径转换为跨平台传输格式，Windows 反斜杠统一为斜杠
---@param path string 本地路径
---@return string wire_path
function M.wire_path(path)
  return path:gsub('\\', '/')
end

---接受原生绝对路径或 file URI，并转换为当前平台的规范路径
---@param input string MCP 传入路径
---@return string path
function M.input_path(input)
  local path = input:sub(1, 7) == 'file://'
      and vim.uri_to_fname(input)
      or input
  return vim.fs.normalize(path)
end

---递归规范化 LSP 结果：URI 转为原生路径，0-based 坐标转为 1-based
---此函数会原地修改 table，避免复制大型 LSP 结果
---@param value any LSP 原始结果
---@return any normalized
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
