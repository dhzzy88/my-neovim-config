-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

-- ============================================================
-- macOS 输入法自动切换 (依赖 macism: brew install laishulu/homebrew/macism)
-- 规则:
--   离开 insert/命令行 / 切走 nvim -> 还原上次记录的 IM (例如搜狗)
--   进入 insert / 切回 nvim       -> 切系统 ABC 英文 (并记录原 IM 以便下次还原)
-- 注意: tmux 下需要 `set -g focus-events on` 才能让 FocusGained/FocusLost 生效
-- ============================================================
-- if vim.fn.has("mac") == 1 and vim.fn.executable("macism") == 1 then
--   local IM_EN = "com.apple.keylayout.ABC"
--   local last_im = "com.sogou.inputmethod.sogou.pinyin"
--
--   local function set_im(id)
--     vim.fn.jobstart({ "macism", id }, { detach = true })
--   end
--
--   -- 切英文前先读当前 IM, 若不是 ABC 则记录, 用于离开 nvim 时还原
--   local function to_english()
--     vim.fn.jobstart({ "macism" }, {
--       stdout_buffered = true,
--       on_stdout = function(_, data)
--         local cur = data and data[1] or ""
--         if cur ~= "" and cur ~= IM_EN then
--           last_im = cur
--         end
--         set_im(IM_EN)
--       end,
--     })
--   end
--
--   local function to_last()
--     set_im(last_im)
--   end
--
--   -- 触发切英文: 离开 insert/命令行, 或聚焦 nvim
--   vim.api.nvim_create_autocmd({ "InsertLeave", "CmdlineLeave", "FocusGained" }, {
--     callback = function()
--       -- 兜底: 若仍在 insert 模式 (例如 :startinsert 后 FocusGained), 不要切走
--       if vim.fn.mode():sub(1, 1) ~= "i" then
--         to_english()
--       end
--     end,
--   })
--
--   -- 触发还原: 进入 insert, 或离开 nvim
--   -- vim.api.nvim_create_autocmd({ "InsertEnter", "FocusLost" }, { callback = to_last })
-- end

-- ============================================================
-- 文件外部修改自动重载
-- 原理: 利用 libuv fs_event (macOS FSEvents / Linux inotify) 监听文件变化,
-- 配合 autoread 选项实现"无感"刷新, 不依赖光标移动或窗口聚焦
-- ============================================================
do
  local watchers = {}
  local timers = {}
  local DEBOUNCE_MS = 50

  local function cleanup(buf)
    local w = watchers[buf]
    if w then
      w:stop()
      if not w:is_closing() then w:close() end
      watchers[buf] = nil
    end
    local t = timers[buf]
    if t then
      t:stop()
      if not t:is_closing() then t:close() end
      timers[buf] = nil
    end
  end

  local watch
  watch = function(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if vim.bo[buf].buftype ~= "" then return end
    local path = vim.api.nvim_buf_get_name(buf)
    if path == "" then return end

    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then return end
    local real = vim.uv.fs_realpath(path) or path

    cleanup(buf)
    local w = vim.uv.new_fs_event()
    if not w then return end
    watchers[buf] = w

    local ok = pcall(function()
      w:start(real, {}, function(err)
        if err then return end
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(buf) then
            cleanup(buf)
            return
          end
          local t = timers[buf] or vim.uv.new_timer()
          timers[buf] = t
          t:stop()
          t:start(
            DEBOUNCE_MS,
            0,
            vim.schedule_wrap(function()
              if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
                vim.cmd("silent! checktime " .. buf)
              end
              -- 原子写入(rename)会让 watcher 失效, 重新挂载
              watch(buf)
            end)
          )
        end)
      end)
    end)
    if not ok then cleanup(buf) end
  end

  local grp = vim.api.nvim_create_augroup("AutoReadFsEvent", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost", "BufWritePost" }, {
    group = grp,
    callback = function(ev) watch(ev.buf) end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = grp,
    callback = function(ev) cleanup(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = grp,
    callback = function()
      for buf, _ in pairs(watchers) do cleanup(buf) end
    end,
  })
end
