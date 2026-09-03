-- ============================================================
-- <leader>fy: SONiC 代码中从 RESTCONF path 查找 YANG annot + Go transformer
-- ============================================================
--
-- 适用于 SONiC mgmt-framework 代码库 (src/sonic-mgmt-framework + src/sonic-mgmt-common)
-- 光标在 cc.Path("/restconf/data/openconfig-system:system/ntp/servers/server") 行
-- 按 <leader>fy → 弹窗显示 annot 映射 + Go xfmr 函数，<CR> 跳转源码
--
-- 链路:
--   RESTCONF path → module name (openconfig-system)
--     → SONiC annot .yang (openconfig-system-annot.yang) 中 rg 搜 deviation 块
--     → 提取 subtree-transformer / key-transformer / field-transformer 函数名
--     → rg 搜 SONiC Go 代码 XlateFuncBind 注册 + var/func 定义
--     → floating window 展示，<CR> 跳转，q/Esc 关闭
--
-- 关键点:
--   - 仅适用于 SONiC 代码库 (自动检测 src/sonic-mgmt-common 目录)
--   - augmentation: RESTCONF path 中非首段可能带扩展模块前缀 (openconfig-qos-rdma-ext:buffer-pools)
--     goyang 合并后 xpath 去掉该前缀，annot 中 deviation 路径也不含它
--     → 用关键词 (去掉 module: 前缀的路径段) 在 deviation 路径中做包含匹配
--   - rg 单文件输出 "行号:内容"，目录输出 "文件:行号:内容"，解析方式不同
--   - Go xfmr 定义形式为 "var FuncName = func(...)" 而非 "func FuncName(...)"

local M = {}

local annot_dir, xfmr_dir

-- 工具函数 ------------------------------------------------------------

local function rg(pattern, path, ignore_case)
  local cmd = { "rg", "--line-number", "--no-heading", "--color", "never" }
  if ignore_case then table.insert(cmd, "-i") end
  table.insert(cmd, pattern)
  table.insert(cmd, path)
  local r = vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0 and r or {}
end

-- rg 输出行解析: 目录搜索 "file:line:content"，单文件搜索 "line:content"
local function parse_line(line, single, file)
  if single then
    local n, c = line:match("^(%d+):(.*)")
    return file, n and tonumber(n), c
  end
  local f, n, c = line:match("^([^:]+):(%d+):(.*)")
  return f, n and tonumber(n), c
end

local function extract_path(line)
  local p = line:match("/restconf/data/([^\"'%s]+)")
  if not p then return end
  p = p:gsub("/$", "")
  return p:sub(1, 1) == "/" and p or "/" .. p
end

local function get_module(path)
  return (path:match("^/([^/:]+)"))
end

local function get_keywords(path)
  local kw = {}
  for seg in path:gmatch("[^/]+") do
    table.insert(kw, seg:match(":(.+)$") or seg)
  end
  if #kw > 1 then table.remove(kw, 1) end
  return kw
end

local function detect_repo()
  if annot_dir then return true end
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
  for _ = 1, 20 do
    if vim.fn.isdirectory(dir .. "/src/sonic-mgmt-common") == 1 then
      annot_dir = dir .. "/src/sonic-mgmt-common/models/yang/annotations"
      xfmr_dir = dir .. "/src/sonic-mgmt-common/translib/transformer"
      return true
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
end

-- annot .yang 搜索 ----------------------------------------------------

local XFMR_PATTERNS = {
  "subtree%-transformer", "key%-transformer", "field%-transformer",
  "field%-name", "table%-name",
}

local function search_annot(yang_path)
  local module = get_module(yang_path)
  if not module then return end
  local annot_file = annot_dir .. "/" .. module .. "-annot.yang"
  if vim.fn.filereadable(annot_file) ~= 1 then return end

  local kw = get_keywords(yang_path)
  if #kw == 0 then return end

  local results = {}
  for _, line in ipairs(rg(kw[#kw], annot_file, true)) do
    local dev_path = line:match("deviation%s+/(.-)%s*{")
    if dev_path then
      local all = true
      for _, k in ipairs(kw) do
        if not dev_path:lower():find(k:lower(), 1, true) then all = false break end
      end
      if all then
        local lnum = tonumber(line:match("^(%d+):"))
        local block = lnum and vim.fn.systemlist(string.format(
          "sed -n '%d,%dp' %s", lnum, lnum + 30, vim.fn.shellescape(annot_file))) or {}

        local xfmrs = {}
        for _, bl in ipairs(block) do
          if bl:match("^%s*deviation%s") and #xfmrs > 0 then break end
          for _, pat in ipairs(XFMR_PATTERNS) do
            local val = bl:match(pat .. '%s+"([^"]+)"')
            if val then
              local tname = pat:gsub("%-", "%%-")
              local t = pat:gsub("transformer", ""):gsub("name", ""):gsub("%-$", ""):gsub("^%-$", "")
              -- 提取类型名: subtree-transformer → subtree-transformer, field-name → field-name
              local type_name = pat:gsub("%%%-", "-")
              table.insert(xfmrs, { type = type_name, name = val })
              break
            end
          end
        end

        table.insert(results, {
          deviation = dev_path, xfmrs = xfmrs,
          file = annot_file, line = lnum,
        })
      end
    end
  end
  return results
end

-- Go 代码搜索 ---------------------------------------------------------

local function search_go(xfmr_names)
  local results = {}
  for _, x in ipairs(xfmr_names) do
    local t = x.type
    if t == "subtree-transformer" or t == "key-transformer" or t == "field-transformer" then
      local bound = {}
      for _, line in ipairs(rg("XlateFuncBind.*" .. x.name, xfmr_dir)) do
        local f, n, c = parse_line(line, false)
        if f then
          local impl = c:match('XlateFuncBind%(%s*"[^"]+"%s*,%s*([%w_]+)%s*%)')
          table.insert(results, { kind = "bind", file = f, lnum = n, content = c, xfmr = x.name })
          if impl then table.insert(bound, impl) end
        end
      end
      for _, impl in ipairs(bound) do
        for _, line in ipairs(rg(impl, xfmr_dir)) do
          local f, n, c = parse_line(line, false)
          if f and (c:match("var " .. impl) or c:match("func " .. impl)) then
            table.insert(results, { kind = "definition", file = f, lnum = n, content = c, xfmr = x.name })
          end
        end
      end
    end
  end
  return results
end

-- floating window ------------------------------------------------------

local function show_results(yang_path, annot_results, go_results)
  if not annot_results or #annot_results == 0 then
    vim.notify("No annot match found for: " .. yang_path, vim.log.levels.WARN)
    return
  end

  local lines, jumps = {}, {}

  for _, annot in ipairs(annot_results) do
    table.insert(lines, " deviation: /" .. annot.deviation)
    table.insert(jumps, { file = annot.file, lnum = annot.line })
    for _, x in ipairs(annot.xfmrs) do
      table.insert(lines, "   " .. x.type .. ": " .. x.name)
      table.insert(jumps, { file = annot.file, lnum = annot.line })
    end
    table.insert(lines, "")
    table.insert(jumps, nil)
  end

  if go_results and #go_results > 0 then
    table.insert(lines, "=== Go Transformer Code ===")
    table.insert(jumps, nil)
    for _, r in ipairs(go_results) do
      local icon = r.kind == "bind" and "  bind  " or "  func  "
      local sf = r.file:match("([^/]+/[^/]+)$") or r.file
      table.insert(lines, string.format("%s %s:%d  %s", icon, sf, r.lnum, r.content))
      table.insert(jumps, { file = r.file, lnum = r.lnum })
    end
  end

  while #lines > 0 and lines[#lines] == "" do table.remove(lines) table.remove(jumps) end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "yaml"
  vim.bo[bufnr].buftype = "nofile"

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end
  width = math.min(width + 4, vim.o.columns - 4)
  local height = math.min(#lines + 1, vim.o.lines - 10)
  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor", row = math.floor((vim.o.lines - height) / 2), col = math.floor((vim.o.columns - width) / 2),
    width = width, height = height, style = "minimal", border = "rounded",
    title = " YANG xfmr: " .. yang_path, title_pos = "center",
  })

  local function close() vim.api.nvim_win_close(winnr, true) end
  local function jump()
    local j = jumps[vim.api.nvim_win_get_cursor(winnr)[1]]
    if j then close(); vim.cmd("edit " .. vim.fn.fnameescape(j.file)); vim.api.nvim_win_set_cursor(0, { j.lnum, 0 }); vim.cmd("normal! zz") end
  end

  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "<CR>", jump, { buffer = bufnr, silent = true, nowait = true, desc = "jump to source" })
end

-- 入口 ----------------------------------------------------------------

function M.find_yang_info()
  local yang_path = extract_path(vim.api.nvim_get_current_line())
  if not yang_path then
    vim.notify("No /restconf/data/ path found on current line", vim.log.levels.WARN)
    return
  end
  if not detect_repo() then
    vim.notify("Cannot detect SONiC repo root (src/sonic-mgmt-common not found)", vim.log.levels.ERROR)
    return
  end

  local annot_results = search_annot(yang_path)
  if not annot_results then
    vim.notify("No annot file found for path: " .. yang_path, vim.log.levels.WARN)
    return
  end

  local xfmr_names = {}
  for _, annot in ipairs(annot_results) do
    for _, x in ipairs(annot.xfmrs) do
      if x.type ~= "field-name" and x.type ~= "table-name" then
        table.insert(xfmr_names, x)
      end
    end
  end

  show_results(yang_path, annot_results, search_go(xfmr_names))
end

return M
