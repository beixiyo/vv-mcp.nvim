---处理 hover、signature help 等代码理解请求
local Navigation = require('vv-mcp.lsp.navigation')

local M = {}

---复用通用的位置请求与多客户端聚合流程
---@param context VVMcpLspContext 请求上下文
---@param operation VVMcpLspOperation 操作定义
---@return table result
function M.request(context, operation)
  return Navigation.request(context, operation)
end

return M
