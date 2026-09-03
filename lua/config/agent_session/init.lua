---<leader>fA: 在所有 codeflicker AI agent 会话间检索
---子模块:
---  config.agent_session.path   ↔ project 目录名 / 真实 cwd 互转
---  config.agent_session.render ↔ jsonl 解析 + 渲染 + 搜索文本抽取
local M = {}

local uv = vim.uv or vim.loop
local PROJECTS_ROOT = vim.fn.expand("~/.codeflicker/projects")

local path_util = require("config.agent_session.path")
local render_util = require("config.agent_session.render")

---默认配置: 选中 entry 后在新建 terminal 中执行的命令
---占位符: {session} = 会话 ID (jsonl 文件名去掉 .jsonl)
---         {path}    = jsonl 完整路径
---         {project} = 项目目录名
---兼容其他 agent CLI 时可在 init.lua 中调用:
---   require("config.agent_session").setup({ command = "opencode -s {session}" })
M.config = {
  command = "m --resume {session}",
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

local function build_command(entry)
  local session = entry.file:gsub("%.jsonl$", "")
  return ((M.config.command or "")
    :gsub("{session}", session)
    :gsub("{path}", entry.path)
    :gsub("{project}", entry.project))
end

---扫描 ~/.codeflicker/projects/*/*.jsonl
---@return table[] entries
local function scan_sessions()
  local current_project = path_util.encode(uv.cwd() or "")
  local entries = {}

  local root = uv.fs_scandir(PROJECTS_ROOT)
  if not root then
    return entries
  end

  while true do
    local proj, ptype = uv.fs_scandir_next(root)
    if not proj then
      break
    end
    if ptype == "directory" or ptype == "link" then
      local proj_path = PROJECTS_ROOT .. "/" .. proj
      local sub = uv.fs_scandir(proj_path)
      while sub do
        local fname, ftype = uv.fs_scandir_next(sub)
        if not fname then
          break
        end
        if (ftype == "file" or ftype == "link") and fname:match("%.jsonl$") then
          local fpath = proj_path .. "/" .. fname
          local stat = uv.fs_stat(fpath)
          entries[#entries + 1] = {
            path = fpath,
            project = proj,
            file = fname,
            mtime = stat and stat.mtime.sec or 0,
            is_current = proj == current_project,
          }
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.is_current ~= b.is_current then
      return a.is_current
    end
    return a.mtime > b.mtime
  end)

  return entries
end

-- ordinal 双段分隔符: <name> \x1f <content>
local SEP = "\31"

---把 prompt 按 ";;" 拆成 (name_query, content_query)
local function split_prompt(p)
  p = p or ""
  local i, j = p:find(";;", 1, true)
  if not i then
    return vim.trim(p), ""
  end
  return vim.trim(p:sub(1, i - 1)), vim.trim(p:sub(j + 1))
end

---所有空格 token 都要在 hay_lower 中出现
local function all_tokens_match(query, hay_lower)
  if query == "" then
    return true
  end
  for token in query:lower():gmatch("%S+") do
    if not hay_lower:find(token, 1, true) then
      return false
    end
  end
  return true
end

local function make_dual_sorter()
  local sorters = require("telescope.sorters")
  return sorters.Sorter:new({
    scoring_function = function(_, prompt, line)
      local nq, cq = split_prompt(prompt)
      if nq == "" and cq == "" then
        return 1
      end
      local sep_at = line:find(SEP, 1, true)
      local name_part = sep_at and line:sub(1, sep_at - 1) or line
      local content_part = sep_at and line:sub(sep_at + 1) or ""
      if not all_tokens_match(nq, name_part:lower()) then
        return -1
      end
      if not all_tokens_match(cq, content_part:lower()) then
        return -1
      end
      return 1
    end,
    -- display 上只能高亮 name 命中
    highlighter = function(_, prompt, display)
      local hls = {}
      local nq = (split_prompt(prompt))
      if nq == "" then
        return hls
      end
      local ld = display:lower()
      for token in nq:lower():gmatch("%S+") do
        local s, e = ld:find(token, 1, true)
        if s then
          hls[#hls + 1] = { start = s, finish = e }
        end
      end
      return hls
    end,
  })
end

local function on_select(entry)
  local cmd = build_command(entry)
  if cmd == "" then
    vim.notify("agent_session.config.command 为空", vim.log.levels.WARN)
    return
  end
  local target_dir = path_util.resolve(entry.path, entry.project)
  local full_cmd
  if target_dir then
    full_cmd = string.format("cd %s && %s", vim.fn.shellescape(target_dir), cmd)
  else
    full_cmd = cmd
    vim.notify("无法定位 session 真实目录, 直接执行: " .. cmd, vim.log.levels.WARN)
  end
  local ok, term = pcall(require, "config.terminal")
  if not ok or type(term.run_in_new_terminal) ~= "function" then
    vim.notify("config.terminal.run_in_new_terminal 不可用", vim.log.levels.ERROR)
    return
  end
  term.run_in_new_terminal(full_cmd)
end

---@param opts? { default_text?: string }
function M.find(opts)
  opts = opts or {}
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.notify("telescope 未安装", vim.log.levels.ERROR)
    return
  end
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local entries = scan_sessions()
  if #entries == 0 then
    vim.notify("未找到 agent session: " .. PROJECTS_ROOT, vim.log.levels.WARN)
    return
  end
  for _, e in ipairs(entries) do
    e.searchable = e.searchable or render_util.extract_searchable(e.path)
  end

  local current_project = path_util.encode(uv.cwd() or "")

  local function entry_maker(e)
    local prefix = e.is_current and "★ " or "  "
    local display = string.format("%s%s  %s", prefix, e.file:gsub("%.jsonl$", ""), e.project)
    local name_part = (e.is_current and "0_" or "1_") .. e.project .. " " .. e.file
    local ordinal = name_part .. SEP .. (e.searchable or "")
    return { value = e, ordinal = ordinal, display = display, path = e.path }
  end

  local function build_finder()
    return finders.new_table({ results = entries, entry_maker = entry_maker })
  end

  pickers
    .new({}, {
      prompt_title = ("Agent Sessions  <name> ;; <content>   <C-x> 删除  <C-o> 打开md"),
      prompt_prefix = "> ",
      default_text = opts.default_text,
      finder = build_finder(),
      sorter = make_dual_sorter(),
      previewer = previewers.new_buffer_previewer({
        title = "Agent Session",
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, render_util.render_session(entry.value.path))
          vim.bo[self.state.bufnr].filetype = "markdown"
        end,
      }),
      attach_mappings = function(_, map)
        actions.select_default:replace(function(prompt_bufnr)
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel and sel.value then
            on_select(sel.value)
          end
        end)

        -- <C-x>: 删除选中 entry 对应的 jsonl 文件 (支持 <Tab> 多选)
        local function delete_selected(prompt_bufnr)
          local picker = action_state.get_current_picker(prompt_bufnr)
          local selections = picker:get_multi_selection()
          if #selections == 0 then
            local sel = action_state.get_selected_entry()
            if sel then
              selections = { sel }
            end
          end
          if #selections == 0 then
            return
          end

          local prompt
          if #selections == 1 then
            prompt = "删除 " .. selections[1].value.project .. "/" .. selections[1].value.file .. " ?"
          else
            prompt = ("删除 %d 个会话?"):format(#selections)
          end
          if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
            return
          end

          local removed_paths, failed = {}, {}
          for _, sel in ipairs(selections) do
            local target = sel.value
            local ok, err
            if uv.fs_unlink then
              ok, err = uv.fs_unlink(target.path)
            else
              ok, err = os.remove(target.path)
            end
            if ok then
              removed_paths[target.path] = true
            else
              failed[#failed + 1] = target.file .. " (" .. tostring(err) .. ")"
            end
          end

          -- 反向遍历, 一次性剔除所有已删除项
          for i = #entries, 1, -1 do
            if removed_paths[entries[i].path] then
              table.remove(entries, i)
            end
          end
          picker:refresh(build_finder(), { reset_prompt = false })

          local removed_n = vim.tbl_count(removed_paths)
          if #failed > 0 then
            vim.notify(
              ("已删除 %d 个; 失败 %d 个: %s"):format(removed_n, #failed, table.concat(failed, ", ")),
              vim.log.levels.WARN
            )
          else
            vim.notify(("已删除 %d 个会话"):format(removed_n))
          end
        end
        map("i", "<C-x>", delete_selected)
        map("n", "<C-x>", delete_selected)

        -- <C-o>: 将选中 session 渲染内容写入 /tmp/<session>.md, 并在新 tab 打开
        local function open_as_markdown(prompt_bufnr)
          local sel = action_state.get_selected_entry()
          if not (sel and sel.value) then
            return
          end
          local e = sel.value
          local session = e.file:gsub("%.jsonl$", "")
          local lines = render_util.render_session(e.path)
          local fpath = "/tmp/" .. session .. ".md"
          local fd, err = io.open(fpath, "w")
          if not fd then
            vim.notify("无法写入 " .. fpath .. ": " .. tostring(err), vim.log.levels.ERROR)
            return
          end
          fd:write(table.concat(lines, "\n"))
          fd:close()
          actions.close(prompt_bufnr)
          vim.cmd("tabnew " .. vim.fn.fnameescape(fpath))

          -- 折叠所有 🤖 ASSISTANT 块, 只展开 👤 USER 提问
          -- 注意: 不改 foldlevel(保持全局默认 99), 否则会泄漏到同窗口后续打开的文件,
          -- 导致其它代码的 treesitter 折叠被全部闭合; 这里改为逐个 foldclose
          local buf = vim.api.nvim_get_current_buf()
          local win = vim.api.nvim_get_current_win()
          local levels = {}
          local heads = {}
          local in_assistant = false
          for i, l in ipairs(lines) do
            if vim.startswith(l, "─") then
              in_assistant = false
              levels[i] = "0"
            elseif vim.startswith(l, "🤖") then
              in_assistant = true
              levels[i] = ">1"
              heads[#heads + 1] = i
            elseif vim.startswith(l, "👤") then
              in_assistant = false
              levels[i] = "0"
            else
              levels[i] = in_assistant and "1" or "0"
            end
          end
          vim.b[buf].agent_fold_levels = levels
          vim.schedule(function()
            if not vim.api.nvim_win_is_valid(win) then
              return
            end
            vim.api.nvim_win_call(win, function()
              vim.wo.foldmethod = "expr"
              vim.wo.foldexpr = "v:lua.require'config.agent_session'.foldexpr(v:lnum)"
              vim.wo.foldenable = true
              for _, h in ipairs(heads) do
                pcall(vim.cmd, h .. "foldclose")
              end
              vim.cmd("normal! gg")
            end)
          end)
        end
        map("i", "<C-o>", open_as_markdown)
        map("n", "<C-o>", open_as_markdown)

        return true
      end,
    })
    :find()
end

---foldexpr: 供 <C-o> 打开的渲染 md 使用, 折叠 ASSISTANT 块
function M.foldexpr(lnum)
  local levels = vim.b.agent_fold_levels
  if not levels then
    return "0"
  end
  return levels[lnum] or "0"
end

-- 便于外部测试 / 调用的转发
M.render_session = render_util.render_session
M.resolve_session_cwd = path_util.resolve_from_jsonl
M.bruteforce_decode = path_util.bruteforce_decode

return M
