set nocompatible
set nomore
set lines=60 columns=200

" Detail columns.
"
" Entry already carried size, mtime and is_symlink, the `meta` flag already
" flowed through ScanDirAsync, and s_cache_has_metadata already tracked which
" snapshots were rich — but every bit of it existed only to feed the sort
" comparator.  You could sort by size and still not see a size.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif

let s:root = tempname()
call mkdir(s:root .. '/subdir', 'p')
call writefile([repeat('x', 4095)], s:root .. '/big.txt', 'b')
call writefile(['tiny'], s:root .. '/tiny.txt')

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_git_status = 0
let g:simpletree_use_nerdfont = 0
let g:simpletree_bookmarks_file = tempname() .. '/bookmarks.json'
execute 'set runtimepath^=' .. fnameescape(s:repo)
runtime plugin/simpletree.vim

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
endfunction

function! s:Vars() abort
  return getscriptinfo({'sid': s:Sid()})[0].variables
endfunction

function! s:TreeWin() abort
  for l:info in getwininfo()
    if getbufvar(l:info.bufnr, '&filetype') ==# 'simpletree'
      return l:info.winid
    endif
  endfor
  return 0
endfunction

function! s:Lines() abort
  let l:w = s:TreeWin()
  return l:w == 0 ? [] : getbufline(winbufnr(l:w), 1, '$')
endfunction

function! s:LineFor(fragment) abort
  for l:line in s:Lines()
    if stridx(l:line, a:fragment) >= 0
      return l:line
    endif
  endfor
  return ''
endfunction

function! s:WaitFor(Cond, ...) abort
  let l:limit = a:0 > 0 ? a:1 : 5000
  let l:waited = 0
  while l:waited < l:limit
    if a:Cond()
      return 1
    endif
    sleep 100m
    let l:waited += 100
  endwhile
  return a:Cond()
endfunction

try

enew
execute 'SimpleTree ' .. fnameescape(s:root)
call assert_true(s:WaitFor({-> s:LineFor('big.txt') !=# ''}), 'the tree never listed its root')

" Off by default: nothing about an existing tree may change.
call assert_true(s:LineFor('big.txt') =~# 'big\.txt$',
      \ 'a column appeared without being asked for: ' .. s:LineFor('big.txt'))

" --------------------------------------------------------------- size column ---

SimpleTreeColumns size
" Enabling columns needs metadata, so this goes through the same one-shot
" re-scan SetSort() performs; the entries are only rich once it lands.
call assert_true(s:WaitFor({-> s:LineFor('big.txt') =~# '4\.0K'}),
      \ 'the size column never rendered: ' .. s:LineFor('big.txt'))
call assert_true(s:LineFor('tiny.txt') =~# '5B',
      \ 'a small file lost its exact size: ' .. s:LineFor('tiny.txt'))
call assert_true(s:LineFor('subdir/') =~# '-\s*$',
      \ 'a directory reported a size instead of a dash: ' .. s:LineFor('subdir/'))

" The block is right-aligned, so the two files agree on where it ends.
call assert_equal(strdisplaywidth(s:LineFor('big.txt')),
      \ strdisplaywidth(s:LineFor('tiny.txt')),
      \ 'the detail columns did not line up')

" It is a real text property, not a lucky regex: names may contain anything.
let s:props = prop_list(1, {'bufnr': winbufnr(s:TreeWin()), 'end_lnum': -1})
call assert_true(len(filter(copy(s:props), {_, p -> p.type ==# 'SimpleTreeColumn'})) >= 2,
      \ 'the column block carries no highlight property')

" -------------------------------------------------------------- mtime column ---

SimpleTreeColumns size mtime
sleep 400m
call assert_true(s:LineFor('big.txt') =~# '\d\d-\d\d \d\d:\d\d',
      \ 'the mtime column never rendered: ' .. s:LineFor('big.txt'))
let g:simpletree_column_time_format = '%Y'
call simpletree#Refresh()
call assert_true(s:WaitFor({-> s:LineFor('big.txt') =~# '\<20\d\d\>'}),
      \ 'the time format was ignored: ' .. s:LineFor('big.txt'))

" ------------------------------------------------------------------- off again ---

SimpleTreeColumns none
sleep 300m
call assert_true(s:LineFor('big.txt') =~# 'big\.txt$',
      \ 'turning columns off left the detail block behind: ' .. s:LineFor('big.txt'))
call assert_equal([], g:simpletree_columns)

" An unknown column is refused rather than silently ignored.
SimpleTreeColumns size
sleep 300m
SimpleTreeColumns nonsense
call assert_equal(['size'], g:simpletree_columns,
      \ 'an unknown column name changed the configuration')

catch
  call assert_report('unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

call delete(s:root, 'rf')
if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
