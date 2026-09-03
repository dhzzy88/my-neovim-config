---解析 codeflicker jsonl 会话, 渲染为人眼可读的对话流, 同时提供搜索文本抽取
local M = {}

local function fmt_ts(ts)
  if not ts or ts == "" then
    return ""
  end
  return (ts:gsub("T", " "):gsub("%..*", ""):gsub("Z$", ""))
end

local function split_lines(s)
  return vim.split(s or "", "\n", { plain = true })
end

---把 text 按行追加进 lines, 每行加 prefix; 超过 max_lines 截断
local function append_block(lines, text, prefix, max_lines)
  if text == nil or text == "" then
    return
  end
  local parts = split_lines(tostring(text))
  while #parts > 0 and parts[#parts] == "" do
    parts[#parts] = nil
  end
  local n = #parts
  local limit = (max_lines and n > max_lines) and max_lines or n
  for i = 1, limit do
    lines[#lines + 1] = prefix .. parts[i]
  end
  if max_lines and n > max_lines then
    lines[#lines + 1] = prefix .. ("... (省略 %d 行)"):format(n - max_lines)
  end
end

---按工具名提取最有用的输入字段做摘要
local function summarize_tool_input(name, input)
  if type(input) ~= "table" then
    return tostring(input or "")
  end
  if name == "bash" then
    return "$ " .. (input.command or "")
  elseif name == "read" or name == "write" then
    return input.file_path or ""
  elseif name == "edit" then
    local s = input.file_path or ""
    if input.old_string then
      s = s
        .. "\n--- old ---\n"
        .. tostring(input.old_string)
        .. "\n+++ new +++\n"
        .. tostring(input.new_string or "")
    end
    return s
  elseif name == "ls" then
    return input.dir_path or ""
  elseif name == "grep" then
    return ("pattern=%s  path=%s"):format(
      tostring(input.pattern or ""),
      tostring(input.path or input.search_path or "")
    )
  elseif name == "glob" then
    return ("pattern=%s  path=%s"):format(tostring(input.pattern or ""), tostring(input.path or ""))
  elseif name == "task" then
    return (input.description or "") .. (input.prompt and ("\n" .. input.prompt) or "")
  elseif name == "todoWrite" then
    local out = {}
    for _, t in ipairs(input.todos or {}) do
      local mark = ({ pending = "[ ]", in_progress = "[~]", completed = "[x]" })[t.status] or "[?]"
      out[#out + 1] = mark .. " " .. tostring(t.content or "")
    end
    return table.concat(out, "\n")
  end
  local out = {}
  for k, v in pairs(input) do
    if type(v) == "string" then
      out[#out + 1] = k .. "=" .. v
    end
  end
  return table.concat(out, "  ")
end

---提取 tool-result 的可读内容: 优先 returnDisplay, 否则 llmContent
local function extract_tool_result(result)
  if type(result) == "string" then
    return result
  end
  if type(result) == "table" then
    if type(result.returnDisplay) == "string" and result.returnDisplay ~= "" then
      return result.returnDisplay
    end
    if type(result.llmContent) == "string" then
      return result.llmContent
    end
    return vim.inspect(result)
  end
  return tostring(result or "")
end

---读取 jsonl 全部行并解析为对象数组 (跳过解析失败行)
local function read_jsonl(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local objs = {}
  for raw in fd:lines() do
    local ok, o = pcall(vim.json.decode, raw)
    if ok and type(o) == "table" then
      objs[#objs + 1] = o
    end
  end
  fd:close()
  return objs
end

---把 jsonl 渲染成对话流文本行 (供 telescope previewer)
function M.render_session(path)
  local objs = read_jsonl(path)
  if not objs then
    return { "(无法打开文件: " .. path .. ")" }
  end

  -- 头部统计
  local summary, session_id, branch, model
  local msg_count, tool_use_count = 0, 0
  for _, o in ipairs(objs) do
    if o.type == "config" and o.config and o.config.summary and not summary then
      summary = o.config.summary
    end
    session_id = session_id or o.sessionId
    branch = branch or o.gitBranch
    model = model or o.model
    if o.type == "message" then
      msg_count = msg_count + 1
      if type(o.content) == "table" then
        for _, it in ipairs(o.content) do
          if type(it) == "table" and it.type == "tool_use" then
            tool_use_count = tool_use_count + 1
          end
        end
      end
    end
  end

  local lines = {
    "Session: " .. (session_id or "?") .. "    Branch: " .. (branch or "?"),
  }
  if model then
    lines[#lines + 1] = "Model:   " .. model
  end
  lines[#lines + 1] = "Summary: " .. (summary or "(none)")
  lines[#lines + 1] = ("Stats:   %d messages, %d tool calls"):format(msg_count, tool_use_count)
  lines[#lines + 1] = "File:    " .. path
  lines[#lines + 1] = string.rep("═", 78)
  lines[#lines + 1] = ""

  for _, o in ipairs(objs) do
    if o.type == "message" and o.role then
      local ts = fmt_ts(o.timestamp)
      local role = o.role

      if role == "user" then
        lines[#lines + 1] = string.rep("─", 78)
        lines[#lines + 1] = ("👤 USER  [%s]"):format(ts)
        lines[#lines + 1] = ""
        local c = o.content
        if type(c) == "string" then
          append_block(lines, c, "  ")
        elseif type(c) == "table" then
          for _, it in ipairs(c) do
            if type(it) == "table" then
              append_block(lines, it.text or it.content or vim.inspect(it), "  ")
            else
              append_block(lines, tostring(it), "  ")
            end
          end
        end
        lines[#lines + 1] = ""
      elseif role == "assistant" then
        lines[#lines + 1] = string.rep("─", 78)
        lines[#lines + 1] = ("🤖 ASSISTANT  [%s]"):format(ts)
        lines[#lines + 1] = ""
        for _, it in ipairs(o.content or {}) do
          if type(it) == "table" then
            local t = it.type
            if t == "text" then
              append_block(lines, it.text or "", "  ")
              lines[#lines + 1] = ""
            elseif t == "reasoning" then
              lines[#lines + 1] = "  💭 thinking:"
              append_block(lines, it.text or "", "    │ ", 40)
              lines[#lines + 1] = ""
            elseif t == "tool_use" then
              local name = it.name or "?"
              local desc = it.description and ("  — " .. it.description) or ""
              lines[#lines + 1] = ("  ▶ %s%s"):format(name, desc)
              local s = summarize_tool_input(name, it.input)
              if s and s ~= "" then
                append_block(lines, s, "      ", 20)
              end
              lines[#lines + 1] = ""
            end
          end
        end
      elseif role == "tool" then
        for _, it in ipairs(o.content or {}) do
          if type(it) == "table" and it.type == "tool-result" then
            local name = it.toolName or "?"
            lines[#lines + 1] = ("  ◀ %s ⇒"):format(name)
            append_block(lines, extract_tool_result(it.result), "      ", 15)
            lines[#lines + 1] = ""
          end
        end
      end
    end
  end

  return lines
end

---提取 jsonl 中用于全文搜索的纯文本 (轻量)
function M.extract_searchable(path)
  local objs = read_jsonl(path)
  if not objs then
    return ""
  end
  local buf = {}
  local function push(s)
    if type(s) == "string" and s ~= "" then
      buf[#buf + 1] = s
    end
  end
  for _, o in ipairs(objs) do
    if o.type == "config" and o.config and o.config.summary then
      push(o.config.summary)
    elseif o.type == "message" then
      local c = o.content
      if type(c) == "string" then
        push(c)
      elseif type(c) == "table" then
        for _, it in ipairs(c) do
          if type(it) == "table" then
            push(it.text)
            if it.type == "tool_use" and type(it.input) == "table" then
              push(it.description)
              push(it.input.command)
              push(it.input.file_path)
              push(it.input.dir_path)
              push(it.input.pattern)
              push(it.input.prompt)
            elseif it.type == "tool-result" and type(it.result) == "table" then
              push(it.result.returnDisplay)
              if type(it.result.llmContent) == "string" and #it.result.llmContent < 4000 then
                push(it.result.llmContent)
              end
            end
          end
        end
      end
    end
  end
  return table.concat(buf, "\n")
end

return M
