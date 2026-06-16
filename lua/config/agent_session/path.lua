---codeflicker projects 目录名 <-> 真实 cwd 的双向转换
local M = {}

---把 cwd 转成 codeflicker 的 project 目录名
---例如 /Users/yintao/Work/code/github/dhcp -> users-yintao-work-code-github-dhcp
function M.encode(cwd)
  local s = (cwd or ""):lower()
  s = s:gsub("[/_.]", "-")
  s = s:gsub("%-+", "-")
  s = s:gsub("^%-+", "")
  s = s:gsub("%-+$", "")
  return s
end

---从 jsonl 内容中扫出所有绝对路径, 找到与 project_dir 编码匹配且本地真实存在的目录.
---能正确处理 "B1-B2/C" 这类带连字符目录的歧义 (内容里就是真实 path).
---@param jsonl_path string
---@param project_dir string
---@return string|nil
function M.resolve_from_jsonl(jsonl_path, project_dir)
  local fd = io.open(jsonl_path, "r")
  if not fd then
    return nil
  end

  local candidates = {}
  local function add(p)
    if type(p) == "string" and p:sub(1, 1) == "/" then
      candidates[p] = true
    end
  end

  local function walk(v)
    if type(v) == "string" then
      if v:sub(1, 1) == "/" and not v:find("\n") then
        add(v)
      else
        for d in v:gmatch("Directory:%s*(/[%w%-_./]+)") do
          add(d)
        end
      end
    elseif type(v) == "table" then
      for _, vv in pairs(v) do
        walk(vv)
      end
    end
  end

  for raw in fd:lines() do
    local ok, o = pcall(vim.json.decode, raw)
    if ok and type(o) == "table" then
      walk(o)
    end
  end
  fd:close()

  local best
  for path in pairs(candidates) do
    local p = path
    while p and p ~= "" and p ~= "/" do
      if M.encode(p) == project_dir then
        if vim.fn.isdirectory(p) == 1 and (not best or #p > #best) then
          best = p
        end
        break
      end
      p = p:match("^(.+)/[^/]*$") or ""
    end
  end

  return best
end

---fallback: 按 "-" 切分 + 文件系统校验做回溯, 处理目录名本身带 "-" 的歧义,
---并尝试常见变体: 原样 / 首字母大写(macOS) / "." 前缀(隐藏目录).
---@param project_dir string
---@return string|nil
function M.bruteforce_decode(project_dir)
  local segs = vim.split(project_dir, "-", { plain = true })
  if #segs == 0 then
    return nil
  end

  local function recurse(prefix, idx)
    if idx > #segs then
      return prefix
    end
    for k = 1, #segs - idx + 1 do
      local piece = table.concat(segs, "-", idx, idx + k - 1)
      local variants = {
        piece,
        piece:sub(1, 1):upper() .. piece:sub(2),
        "." .. piece,
      }
      for _, name in ipairs(variants) do
        local cand = prefix .. (prefix:sub(-1) == "/" and "" or "/") .. name
        if vim.fn.isdirectory(cand) == 1 then
          local r = recurse(cand, idx + k)
          if r and M.encode(r) == project_dir then
            return r
          end
        end
      end
    end
    return nil
  end

  return recurse("/", 1)
end

---综合策略: 先看 jsonl 内容, 拿不到再回溯. 都失败返回 nil.
function M.resolve(jsonl_path, project_dir)
  return M.resolve_from_jsonl(jsonl_path, project_dir) or M.bruteforce_decode(project_dir)
end

return M
