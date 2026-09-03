require("gitsigns").setup({
  current_line_blame = true, -- Toggle with `:Gitsigns toggle_current_line_blame`
  current_line_blame_formatter = '<abbrev_sha>, <author>, <author_time:%Y-%m-%d %H:%M:%S> - <summary>',
})

local function git_floating(cmd)
  return function()
    local opts = { win = { position = "float", width = 0.9, height = 0.85 } }
    local ok, lib = pcall(require, "diffview.lib")
    if ok then
      local view = lib.get_current_view()
      if view and view.adapter and view.adapter.ctx and view.adapter.ctx.toplevel then
        opts.cwd = view.adapter.ctx.toplevel
      end
    end
    Snacks.terminal(cmd, opts)
  end
end

local git_commit_floating = git_floating("GIT_EDITOR=nvim git commit")
local git_commit_amend_floating = git_floating("GIT_EDITOR=nvim git commit --amend")
local git_push_floating = git_floating("git push")
local git_push_force_floating = git_floating("git push -f")

-- 关闭 commit message 编辑时的自动换行:
-- Neovim 内置 gitcommit ftplugin 默认 textwidth=72, 输入超宽会自动插入换行符
vim.api.nvim_create_autocmd("FileType", {
  pattern = "gitcommit",
  callback = function()
    vim.opt_local.textwidth = 0
    vim.opt_local.formatoptions:remove("t")
  end,
})

require("diffview").setup({
  enhanced_diff_hl = true,
  -- 弥补 diffview 只监听 .git/index 不监听 HEAD 的缺陷:
  -- commit/amend/reset/checkout 都会写入 .git/logs/HEAD, 监听它实现自动刷新
  hooks = {
    view_opened = function(view)
      if not (view.adapter and view.adapter.ctx and view.adapter.ctx.dir) then
        return
      end
      local logs_head = view.adapter.ctx.dir .. "/logs/HEAD"
      local w = vim.uv.new_fs_poll()
      w:start(logs_head, 1000, vim.schedule_wrap(function(err)
        if not err and view.ready and not view.closing:check() then
          view:update_files()
        end
      end))
      view._head_watcher = w
    end,
    view_closed = function(view)
      if view._head_watcher then
        view._head_watcher:stop()
        view._head_watcher:close()
        view._head_watcher = nil
      end
    end,
  },
  keymaps = {
    file_panel = {
      { "n", "gc", git_commit_floating, { desc = "git commit (floating terminal)" } },
      { "n", "ga", git_commit_amend_floating, { desc = "git commit  --amend (floating terminal)" } },
      { "n", "gp", git_push_floating, { desc = "git push (floating terminal)" } },
      { "n", "gf", git_push_force_floating, { desc = "git push -f (floating terminal)" } },
    },
    view = {
      { "n", "gc", git_commit_floating, { desc = "git commit (floating terminal)" } },
      { "n", "ga", git_commit_amend_floating, { desc = "git commit  --amend (floating terminal)" } },
      { "n", "gp", git_push_floating, { desc = "git push (floating terminal)" } },
      { "n", "gf", git_push_force_floating, { desc = "git push -f (floating terminal)" } },
    },
  },
})
