set nocompatible
set nomore

" The bundled spacemacs dark/light helpers.
"
" These three commands were dead on every Vim this suite supports.
" autoload/spacemacs_theme_v9.vim declared `export def set()` and
" `export def toggle()`, and Vim9 refuses a def whose name starts with a
" lowercase letter: sourcing the script aborted at its first definition with
" E1267, so :SpacemacsThemeToggle reported E1267 once and E117 for ever after
" (the script is marked sourced even though neither function was defined).
" tests/defcompile-skip excluded spacemacs_theme*.vim with the rationale that
" ":defcompile rejects them on principle rather than because anything is
" wrong" — written over precisely the diagnostic that says something is wrong,
" which is why `make check` stayed green.  The skip file is gone; this test is
" the other half, because :defcompile proves the script loads and says nothing
" about whether the commands do anything.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:repo)
runtime plugin/spacemacs_theme.vim

let s:finished = 0

function! s:Run(command) abort
  try
    execute a:command
    return ''
  catch
    return v:exception
  endtry
endfunction

try

" Every command must exist and must run.  E1267 shows up on the first call,
" E117 on every later one, so both orders are exercised below.
for s:command in ['SpacemacsThemeDark', 'SpacemacsThemeLight', 'SpacemacsThemeToggle']
  call assert_true(exists(':' .. s:command) == 2, s:command .. ' is not defined')
endfor

set background=light
call assert_equal('', s:Run('SpacemacsThemeDark'), 'SpacemacsThemeDark threw')
call assert_equal('dark', g:spacemacs_theme_mode, 'dark mode was not recorded')
call assert_equal('dark', &background, ':SpacemacsThemeDark did not set background')

call assert_equal('', s:Run('SpacemacsThemeLight'), 'SpacemacsThemeLight threw')
call assert_equal('light', g:spacemacs_theme_mode, 'light mode was not recorded')
call assert_equal('light', &background, ':SpacemacsThemeLight did not set background')

" toggle() called set() in a vim9 script, where `set(next)` parses as the :set
" command rather than as a call: it has to flip the mode, not silently do
" nothing.
call assert_equal('', s:Run('SpacemacsThemeToggle'), 'SpacemacsThemeToggle threw')
call assert_equal('dark', g:spacemacs_theme_mode, 'toggle did not flip light -> dark')
call assert_equal('dark', &background, 'toggle did not apply the flipped mode')
call assert_equal('', s:Run('SpacemacsThemeToggle'), 'the second toggle threw')
call assert_equal('light', g:spacemacs_theme_mode, 'toggle did not flip dark -> light')

" An invalid mode warns and changes nothing.
call assert_equal('', s:Run("call spacemacs_theme#set('mauve')"), 'an invalid mode threw')
call assert_equal('light', g:spacemacs_theme_mode, 'an invalid mode was accepted')

" The colorscheme the helpers apply must itself load.
call assert_equal('', s:Run('colorscheme spacemacs'), ':colorscheme spacemacs threw')
call assert_equal('spacemacs', get(g:, 'colors_name', ''), 'the colorscheme did not name itself')

let s:finished = 1

catch
  call add(v:errors, 'unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

if !s:finished
  call add(v:errors, 'the test body did not run to completion')
endif

if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
