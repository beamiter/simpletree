" spacemacs_theme plugin 入口 — 兼容 Vim 8.x / 9.0+

command! SpacemacsThemeToggle call spacemacs_theme#toggle()
command! SpacemacsThemeDark   call spacemacs_theme#set('dark')
command! SpacemacsThemeLight  call spacemacs_theme#set('light')

if !exists('g:spacemacs_theme_mode')
  let g:spacemacs_theme_mode = &background
endif
