" spacemacs_theme autoload — 兼容 Vim 8.x / 9.0+

if v:version >= 900
  " Vim 9.0+: 转发到 vim9 实现
  function! spacemacs_theme#set(mode) abort
    call spacemacs_theme_v9#set(a:mode)
  endfunction
  function! spacemacs_theme#toggle() abort
    call spacemacs_theme_v9#toggle()
  endfunction
  finish
endif

" Vim 8.x legacy
function! spacemacs_theme#set(mode) abort
  if a:mode !=# 'dark' && a:mode !=# 'light'
    echohl WarningMsg | echom 'spacemacs_theme: invalid mode ' . a:mode | echohl None
    return
  endif
  let g:spacemacs_theme_mode = a:mode
  let &background = a:mode
  try
    execute 'colorscheme spacemacs'
  catch
  endtry
endfunction

function! spacemacs_theme#toggle() abort
  let l:cur = get(g:, 'spacemacs_theme_mode', &background)
  let l:next = l:cur ==# 'dark' ? 'light' : 'dark'
  call spacemacs_theme#set(l:next)
endfunction
