vim9script

# Vim9 refuses a `def` whose name starts with a lowercase letter, so the
# original `export def set()` / `export def toggle()` aborted this script at
# its first definition with E1267 on every Vim the plugin supports (9.1+):
# :SpacemacsThemeToggle reported E1267 once and E117 for ever after, because
# the script was already marked sourced and neither function existed.  The
# capitalised names are what the rest of this plugin already uses.
export def Set(mode: string)
  if mode !=# 'dark' && mode !=# 'light'
    echohl WarningMsg | echom 'spacemacs_theme: invalid mode ' .. mode | echohl None
    return
  endif
  g:spacemacs_theme_mode = mode
  &background = mode
  try
    execute 'colorscheme spacemacs'
  catch
    # 若 colorscheme 文件未就绪，忽略错误
  endtry
enddef

export def Toggle()
  var cur = get(g:, 'spacemacs_theme_mode', &background)
  var next = cur ==# 'dark' ? 'light' : 'dark'
  # `set(next)` here parsed as the :set command, not as a call — a second bug
  # that would have bitten even once the name was legal.
  Set(next)
enddef
