-- :DiffviewFileHistory         查看当前branch的git graph (默认显示256条commit记录), 如果要显示更多记录，加参数 -n1000
-- :DiffviewFileHistory %       查看当前文件的git graph
-- 查看当前工作区的修改内容     :DiffviewOpen
-- 查看两个commit之间的变化     :DiffviewOpen HEAD~4..HEAD~2
--                              :DiffviewOpen d4a7b0d..519b30e
return {
  {
    "sindrets/diffview.nvim",
  },
  {
    "folke/snacks.nvim",
    opts = {
      gitbrowse = {
        url_patterns = {
          ["git%.corp%.kuaishou%.com"] = {
            branch = "/-/tree/{branch}",
            file = "/-/blob/{branch}/{file}#L{line_start}-{line_end}",
            permalink = "/-/blob/{commit}/{file}#L{line_start}-{line_end}",
            commit = "/-/commit/{commit}",
          },
        },
      },
    },
  }
}
