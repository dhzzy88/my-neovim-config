require("auto-session").setup({
  suppressed_dirs = { '~/', '/' },
  bypass_session_save_file_types = { "alpha", "dashboard" }, -- table: Bypass auto save when only buffer open is one of these file types, useful to ignore dashboards
  close_unsupported_windows = true, -- boolean: Close windows that aren't backed by normal file
  cwd_change_handling = { -- table: Config for handling the DirChangePre and DirChanged autocmds, can be set to nil to disable altogether
    restore_upcoming_session = false, -- boolean: restore session for upcoming cwd on cwd change
    pre_cwd_changed_hook = nil, -- function: This is called after auto_session code runs for the `DirChangedPre` autocmd
    post_cwd_changed_hook = nil, -- function: This is called after auto_session code runs for the `DirChanged` autocmd
  },
  args_allow_single_directory = true, -- boolean Follow normal sesion save/load logic if launched with a single directory as the only argument
  args_allow_files_auto_save = false, -- boolean|function Allow saving a session even when launched with a file argument (or multiple files/dirs). It does not load any existing session first. While you can just set this to true, you probably want to set it to a function that decides when to save a session when launched with file args. See documentation for more detail
  silent_restore = true, -- Suppress extraneous messages and source the whole session, even if there's an error. Set to false to get the line number a restore error
  session_lens = {
    theme_conf = {
        layout_config = {
            width = 0.6,
            height = 0.4,
        },
        mappings = {
            -- Mode can be a string or a table, e.g. {"i", "n"} for both insert and normal mode
            delete_session = { "i", "<C-D>" },
            alternate_session = { "i", "<C-S>" },
            copy_session = { "i", "<C-Y>" },
        },
    },
  },
})
