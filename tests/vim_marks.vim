set nocompatible
set nomore
set lines=60 columns=200

" Marked nodes and the batch operations built on them.  The clipboard has always
" been {mode, items: [...]} and OnPaste() has always looped over items; these
" tests pin that the loop is now actually exercised with more than one element,
" and that the per-path guards still run for every item rather than once.
"
" The body runs inside :try so that an unexpected exception (E484 from a file a
" batch failed to produce, say) becomes a reported failure instead of silently
" aborting the script before its cquit is ever reached.

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif
let s:root = tempname()
call mkdir(s:root .. '/dest', 'p')
call mkdir(s:root .. '/moved', 'p')
call writefile(['one'], s:root .. '/one.txt')
call writefile(['two'], s:root .. '/two.txt')
call writefile(['three'], s:root .. '/three.txt')
" A second workspace, used at the end to pin that a root change drops the marks
" made under the old root.
let s:other = tempname()
call mkdir(s:other, 'p')
call writefile(['bee'], s:other .. '/bee.txt')

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_use_trash = 0
let g:simpletree_use_system_clipboard = 0
let g:simpletree_git_status = 0
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
  return getbufline(winbufnr(s:TreeWin()), 1, '$')
endfunction

function! s:LineOf(fragment) abort
  let l:lines = s:Lines()
  for l:i in range(len(l:lines))
    if stridx(l:lines[l:i], a:fragment) >= 0
      return l:i + 1
    endif
  endfor
  return 0
endfunction

function! s:Select(fragment) abort
  let l:winid = s:TreeWin()
  call assert_true(l:winid > 0, 'tree window is missing')
  call win_gotoid(l:winid)
  let l:lnum = s:LineOf(a:fragment)
  call assert_true(l:lnum > 0, 'tree node is missing: ' .. a:fragment)
  if l:lnum > 0
    call cursor(l:lnum, 1)
  endif
endfunction

" Select by exact path rather than by a substring of the rendered line: once a
" paste has revealed a copy inside dest/, 'one.txt' matches two different lines.
function! s:SelectPath(path) abort
  call win_gotoid(s:TreeWin())
  let l:idx = s:Vars().s_line_index
  for l:i in range(len(l:idx))
    if get(l:idx[l:i], 'path', '') ==# a:path
      call cursor(l:i + 1, 1)
      return l:i + 1
    endif
  endfor
  call assert_report('node is not in the tree: ' .. a:path)
  return 0
endfunction

function! s:Marked() abort
  return sort(keys(s:Vars().s_marked))
endfunction

" Ex mode cannot be driven into Visual mode with feedkeys(), so the range is
" applied the way the mapping applies it: leave Visual, then read '< and '>.
function! s:MarkRange(first, last) abort
  call win_gotoid(s:TreeWin())
  call setpos("'<", [0, a:first, 1, 0])
  call setpos("'>", [0, a:last, 1, 0])
  call simpletree#OnMarkRange()
endfunction

let s:finished = 0

try

enew
execute 'SimpleTree ' .. fnameescape(s:root)
sleep 500m
call assert_true(s:TreeWin() > 0, 'tree did not open')

" ------------------------------------------------------------------ marking ---

call s:Select('one.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:root .. '/one.txt'], s:Marked())
call assert_true(s:Lines()[s:LineOf('one.txt') - 1] =~# '✓', 'the mark glyph is not rendered')
call assert_true(simpletree#StatusLine() =~# 'marked:1', 'statusline does not report the mark count')

" Marking advances the cursor so a run of nodes can be marked without moving.
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal(2, len(s:Marked()), 'the second toggle did not mark the next line')

call simpletree#OnMarkClear()
sleep 100m
call assert_equal([], s:Marked())
call assert_false(join(s:Lines(), "\n") =~# '✓', 'clearing marks left a glyph behind')

" The workspace root is never a batch target: it cannot be marked at all.
call win_gotoid(s:TreeWin())
call cursor(1, 1)
call simpletree#OnMarkToggle()
call assert_equal([], s:Marked(), 'the workspace root must not be markable')

" The visual mapping is installed on the same key as the normal-mode one, so a
" user who rebinds mark_toggle keeps both.  It goes through :<C-u> rather than
" <Cmd> because '< and '> are only updated once Visual mode has been left.
call win_gotoid(s:TreeWin())
call assert_equal(':<C-U>call simpletree#OnMarkRange()<CR>',
      \ trim(maparg('<Space>', 'x')), 'no visual mark mapping installed')

let s:first = s:SelectPath(s:root .. '/one.txt')
call s:MarkRange(s:first, s:first + 2)
sleep 100m
call assert_equal(3, len(s:Marked()), 'visual-range marking did not mark the selection')

" Re-marking a fully marked range toggles it off again.
call s:MarkRange(s:first, s:first + 2)
sleep 100m
call assert_equal(0, len(s:Marked()), 'a fully marked range did not toggle off')

" A range that starts on the workspace root skips it and marks the rest.
call s:MarkRange(1, s:first)
sleep 100m
call assert_equal([s:root .. '/dest', s:root .. '/moved', s:root .. '/one.txt'],
      \ s:Marked(), 'a visual range must skip the workspace root')
call simpletree#OnMarkClear()
sleep 100m

" gm marks every visible node sharing the cursor node's parent directory.
call s:SelectPath(s:root .. '/one.txt')
call simpletree#OnMarkSiblings()
sleep 100m
call assert_equal([s:root .. '/dest', s:root .. '/moved', s:root .. '/one.txt',
      \ s:root .. '/three.txt', s:root .. '/two.txt'],
      \ s:Marked(), 'gm did not mark the visible siblings')
call simpletree#OnMarkClear()
sleep 100m

" --------------------------------------------------------------- batch copy ---

call s:SelectPath(s:root .. '/one.txt')
call simpletree#OnMarkToggle()
call s:SelectPath(s:root .. '/three.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:root .. '/one.txt', s:root .. '/three.txt'], s:Marked())
call simpletree#OnCopy()
call assert_equal(['copy', [s:root .. '/one.txt', s:root .. '/three.txt']],
      \ [s:Vars().s_clipboard.mode, s:Vars().s_clipboard.items],
      \ 'copy did not use the whole marked set')

call s:SelectPath(s:root .. '/dest')
call simpletree#OnPaste()
sleep 400m
call assert_equal(['one'], readfile(s:root .. '/dest/one.txt'))
call assert_equal(['three'], readfile(s:root .. '/dest/three.txt'))
call assert_equal([], s:Marked(), 'a successful paste must clear the marks')
call assert_true(filereadable(s:root .. '/one.txt'), 'copy must not remove its sources')

" --------------------------------------------------------------- batch move ---

call simpletree#Refresh()
sleep 500m
call s:SelectPath(s:root .. '/one.txt')
call simpletree#OnMarkToggle()
call s:SelectPath(s:root .. '/three.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:root .. '/one.txt', s:root .. '/three.txt'], s:Marked())
call simpletree#OnCut()
call assert_equal('cut', s:Vars().s_clipboard.mode)
call s:SelectPath(s:root .. '/moved')
call simpletree#OnPaste()
sleep 400m
call assert_false(filereadable(s:root .. '/one.txt'), 'batch move left the first source behind')
call assert_false(filereadable(s:root .. '/three.txt'), 'batch move left the last source behind')
call assert_equal(['one'], readfile(s:root .. '/moved/one.txt'))
call assert_equal(['three'], readfile(s:root .. '/moved/three.txt'))
call assert_equal(['', []], [s:Vars().s_clipboard.mode, s:Vars().s_clipboard.items],
      \ 'a fully applied cut must empty the clipboard')

" ------------------------------------------------------------- batch delete ---

call writefile(['a'], s:root .. '/del_a.txt')
call writefile(['b'], s:root .. '/del_b.txt')
call simpletree#Refresh()
sleep 600m
call s:SelectPath(s:root .. '/del_a.txt')
call simpletree#OnMarkToggle()
call s:SelectPath(s:root .. '/del_b.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:root .. '/del_a.txt', s:root .. '/del_b.txt'], s:Marked())

" confirm() cannot be answered in headless ex mode, so it returns the default
" (No).  That is exactly the assertion that matters here: one declined prompt
" must leave the entire marked set untouched, not just its first element.
call simpletree#OnDelete()
sleep 200m
call assert_true(filereadable(s:root .. '/del_a.txt'), 'a declined batch prompt deleted a file')
call assert_true(filereadable(s:root .. '/del_b.txt'), 'a declined batch prompt deleted a file')
call assert_equal(2, len(s:Marked()), 'a declined delete dropped the marks')

" An unsaved buffer anywhere in the marked set fails that item closed before the
" prompt is ever shown; the post-prompt re-validation is exercised separately.
execute 'badd ' .. fnameescape(s:root .. '/del_a.txt')
let s:buf = bufnr(s:root .. '/del_a.txt')
call bufload(s:buf)
call setbufline(s:buf, 1, ['unsaved'])
call setbufvar(s:buf, '&modified', 1)
call simpletree#OnDelete()
call assert_true(filereadable(s:root .. '/del_a.txt'))
call setbufvar(s:buf, '&modified', 0)
execute 'silent! bwipeout! ' .. s:buf

" Drive the per-item worker directly: every destructive guard is re-run there,
" because the single prompt may have been open for an arbitrary time.
let s:DeleteOne = function(printf('<SNR>%d_DeleteOneConfirmed', s:Sid()))
call assert_true(call(s:DeleteOne, [s:root .. '/del_a.txt', v:false]).removed)
call assert_false(filereadable(s:root .. '/del_a.txt'))
let s:gone = call(s:DeleteOne, [s:root .. '/del_a.txt', v:false])
call assert_false(s:gone.removed, 'a vanished path must not report a delete')
call assert_notequal('', s:gone.reason)
call assert_false(call(s:DeleteOne, [tempname() .. '/outside.txt', v:false]).removed,
      \ 'a path outside the workspace must be refused')

" Marks survive a refresh, but stale ones are dropped rather than kept as
" ghosts: H / I go through Refresh() and must not throw the set away.
call simpletree#OnMarkClear()
call s:SelectPath(s:root .. '/del_b.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:root .. '/del_b.txt'], s:Marked())
call simpletree#Refresh()
sleep 500m
call assert_equal([s:root .. '/del_b.txt'], s:Marked(), 'refresh dropped a live mark')
call delete(s:root .. '/del_b.txt')
call simpletree#Refresh()
sleep 500m
call assert_equal([], s:Marked(), 'refresh kept a mark on a vanished path')

" ---------------------------------------------------------------- root change ---

" Marks belong to the root they were made under: once the root changes they are
" no longer on screen, and c / x / D would silently act on paths the user cannot
" see.  ':SimpleTree {dir}' re-roots just like '.', 'd', 'C' and root-up do, so
" it has to clear them too — including the re-root from a second tab page, which
" |simpletree-tabpages| explicitly recommends.

call s:SelectPath(s:root .. '/two.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:root .. '/two.txt'], s:Marked())
let s:watched_before = keys(s:Vars().s_watched)

tabnew
execute 'SimpleTree ' .. fnameescape(s:other)
sleep 600m
call assert_equal(s:other, simpletree#GetRoot(), ':SimpleTree {dir} did not re-root')
call assert_equal([], s:Marked(), 'a re-root from another tab kept the old root''s marks')
call assert_false(simpletree#StatusLine() =~# 'marked:',
      \ 'the statusline still counts marks from the old root')
" The old root's watches belong to the old root as well; without this the tree
" keeps receiving fs events for a directory it no longer shows.
if !empty(s:watched_before)
  call assert_equal([], filter(keys(s:Vars().s_watched), 'stridx(v:val, s:root) == 0'),
        \ 'the old root is still watched after a re-root')
endif
tabclose
sleep 100m

" The same holds for the single-tab flow: close, then reopen elsewhere.
call s:SelectPath(s:other .. '/bee.txt')
call simpletree#OnMarkToggle()
sleep 100m
call assert_equal([s:other .. '/bee.txt'], s:Marked())
SimpleTreeClose
execute 'SimpleTree ' .. fnameescape(s:root)
sleep 600m
call assert_equal(s:root, simpletree#GetRoot(), 'reopening elsewhere did not re-root')
call assert_equal([], s:Marked(), 'reopening at another root kept the old marks')

let s:finished = 1

catch
  call add(v:errors, 'unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

if !s:finished
  call add(v:errors, 'the test body did not run to completion')
endif

call simpletree#OnMarkClear()
SimpleTreeClose
call simpletree#Stop()
call delete(s:root, 'rf')
call delete(s:other, 'rf')
if len(v:errors) > 0
  call writefile(v:errors, '/tmp/simpletree-vim-marks-errors')
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
