set nocompatible
set nomore

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif
let s:root = tempname()
let s:outside = tempname()
call mkdir(s:root .. '/dest', 'p')
call mkdir(s:root .. '/folder', 'p')
call mkdir(s:outside, 'p')
call writefile(['alpha'], s:root .. '/alpha.txt')
call writefile(['gamma'], s:root .. '/gamma.txt')
call writefile(['morph'], s:root .. '/morph.txt')
call writefile(['child'], s:root .. '/folder/child.txt')
call writefile(['outside'], s:outside .. '/outside.txt')
let s:has_symlink_fixture = has('unix') && executable('ln')
if s:has_symlink_fixture
  call system('ln -s ' .. shellescape(s:outside) .. ' ' .. shellescape(s:root .. '/escape'))
  call assert_equal(0, v:shell_error)
  call system('ln -s ' .. shellescape(s:root .. '/folder') .. ' ' .. shellescape(s:root .. '/alias-into-folder'))
  call assert_equal(0, v:shell_error)
endif

let g:simpletree_persist_width = 0
let g:simpletree_daemon_path = s:daemon
let g:simpletree_use_trash = 0
let g:simpletree_use_system_clipboard = 0
execute 'set runtimepath^=' .. fnameescape(s:repo)
runtime plugin/simpletree.vim

function! s:TreeWin() abort
  for info in getwininfo()
    if getbufvar(info.bufnr, '&filetype') ==# 'simpletree'
      return info.winid
    endif
  endfor
  return 0
endfunction

function! s:TreeLine(fragment) abort
  let winid = s:TreeWin()
  if winid == 0
    return 0
  endif
  let lines = getbufline(winbufnr(winid), 1, '$')
  for index in range(len(lines))
    if stridx(lines[index], a:fragment) >= 0
      return index + 1
    endif
  endfor
  return 0
endfunction

function! s:Select(fragment) abort
  let winid = s:TreeWin()
  call assert_true(winid > 0, 'tree window is missing')
  call win_gotoid(winid)
  let lnum = s:TreeLine(a:fragment)
  call assert_true(lnum > 0, 'tree node is missing: ' .. a:fragment)
  if lnum > 0
    call cursor(lnum, 1)
  endif
endfunction

function! s:SelectLeaf(name) abort
  let winid = s:TreeWin()
  call assert_true(winid > 0, 'tree window is missing')
  call win_gotoid(winid)
  let lines = getbufline(winbufnr(winid), 1, '$')
  let pattern = '\V ' .. escape(a:name, '\') .. '\m$'
  let lnum = 0
  for index in range(len(lines))
    if lines[index] =~# pattern
      let lnum = index + 1
      break
    endif
  endfor
  call assert_true(lnum > 0, 'tree leaf is missing: ' .. a:name)
  if lnum > 0
    call cursor(lnum, 1)
  endif
endfunction

execute 'edit ' .. fnameescape(s:root .. '/alpha.txt')
execute 'badd ' .. fnameescape(s:root .. '/folder/child.txt')
let s:child_buf = bufnr(s:root .. '/folder/child.txt')
call bufload(s:child_buf)
let s:alias_buf = -1
let s:outside_buf = -1
if s:has_symlink_fixture
  execute 'badd ' .. fnameescape(s:root .. '/alias-into-folder/child.txt')
  let s:alias_buf = bufnr(s:root .. '/alias-into-folder/child.txt')
  call bufload(s:alias_buf)
  execute 'badd ' .. fnameescape(s:outside .. '/outside.txt')
  let s:outside_buf = bufnr(s:outside .. '/outside.txt')
  call bufload(s:outside_buf)
endif
execute 'SimpleTree ' .. fnameescape(s:root)
sleep 400m

" Traversal-like rename input must be rejected without touching either path.
call s:Select('alpha.txt')
call feedkeys("\<C-U>..\<CR>", 't')
call simpletree#OnRename()
call assert_true(isdirectory(s:root))
call assert_true(filereadable(s:root .. '/alpha.txt'))

" A valid rename keeps the loaded, unmodified buffer attached to the new path.
call feedkeys("\<C-U>beta.txt\<CR>", 't')
call simpletree#OnRename()
sleep 200m
call assert_false(filereadable(s:root .. '/alpha.txt'))
call assert_true(filereadable(s:root .. '/beta.txt'))
call assert_true(bufnr(s:root .. '/beta.txt') > 0)
call s:Select('beta.txt')
call simpletree#OnYankPath()
call assert_equal('beta.txt', getreg('"'))
call simpletree#OnYankAbsPath()
call assert_equal(s:root .. '/beta.txt', getreg('"'))

" Destructive guards use the live entry type, not the daemon's cached type.
call delete(s:root .. '/morph.txt')
call mkdir(s:root .. '/morph.txt')
call writefile(['live child'], s:root .. '/morph.txt/child.txt')
execute 'badd ' .. fnameescape(s:root .. '/morph.txt/child.txt')
let s:morph_buf = bufnr(s:root .. '/morph.txt/child.txt')
call bufload(s:morph_buf)
call setbufline(s:morph_buf, 1, ['unsaved live child'])
call setbufvar(s:morph_buf, '&modified', 1)
call s:Select('morph.txt')
call simpletree#OnDelete()
call assert_true(isdirectory(s:root .. '/morph.txt'))
call setbufvar(s:morph_buf, '&modified', 0)
execute 'silent! bwipeout! ' .. s:morph_buf
call delete(s:root .. '/morph.txt', 'rf')
SimpleTreeRefresh
sleep 200m

if s:has_symlink_fixture
  " Nested creation cannot traverse an intermediate link outside the workspace.
  call s:Select('beta.txt')
  call feedkeys("\<C-U>escape/should-not-exist\<CR>", 't')
  call simpletree#OnNewFile()
  call assert_false(filereadable(s:outside .. '/should-not-exist'))
  call feedkeys("\<C-U>escape/folder-should-not-exist\<CR>", 't')
  call simpletree#OnNewFolder()
  call assert_false(isdirectory(s:outside .. '/folder-should-not-exist'))

  " A directory-link alias cannot bypass workspace or self-paste boundaries.
  call s:SelectLeaf('escape/')
  call simpletree#OnNewFile()
  call assert_false(filereadable(s:outside .. '/should-not-exist'))
  call simpletree#OnEnter()
  sleep 200m
  call s:Select('outside.txt')
  call simpletree#OnDelete()
  call assert_true(filereadable(s:outside .. '/outside.txt'))

  call s:SelectLeaf('folder/')
  call simpletree#OnCopy()
  call s:SelectLeaf('alias-into-folder/')
  call simpletree#OnPaste()
  call assert_equal([], glob(s:root .. '/folder/.simpletree-*', 0, 1))

  " Copying the link node preserves the link rather than traversing its target.
  call s:SelectLeaf('escape/')
  call simpletree#OnCopy()
  call s:Select('dest/')
  call simpletree#OnPaste()
  call assert_equal('link', getftype(s:root .. '/dest/escape'))
  call assert_true(bufexists(s:outside_buf), 'copying a link closed its target buffer')
  call assert_equal(fnamemodify(s:outside .. '/outside.txt', ':p'),
        \ fnamemodify(bufname(s:outside_buf), ':p'))
endif

" Directory rename updates hidden descendant buffers without forcing a reload.
call s:SelectLeaf('folder/')
call feedkeys("\<C-U>renamed\<CR>", 't')
call simpletree#OnRename()
sleep 200m
call assert_false(isdirectory(s:root .. '/folder'))
call assert_true(filereadable(s:root .. '/renamed/child.txt'))
call assert_equal(s:child_buf, bufnr(s:root .. '/renamed/child.txt'))
if s:alias_buf > 0 && s:alias_buf != s:child_buf
  call assert_true(bufexists(s:alias_buf), 'renaming a real directory closed an alias buffer')
  call assert_equal(fnamemodify(s:root .. '/alias-into-folder/child.txt', ':p'),
        \ fnamemodify(bufname(s:alias_buf), ':p'),
        \ 'resolved alias buffer was incorrectly renamed')
endif
call setbufline(s:child_buf, 1, ['unsaved-child'])
call setbufvar(s:child_buf, '&modified', 1)
call s:Select('renamed/')
call simpletree#OnDelete()
call assert_true(isdirectory(s:root .. '/renamed'))
call setbufvar(s:child_buf, '&modified', 0)

" Modified buffers make destructive operations fail closed.
let s:beta_buf = bufnr(s:root .. '/beta.txt')
call setbufline(s:beta_buf, 1, ['unsaved'])
call setbufvar(s:beta_buf, '&modified', 1)
call s:Select('beta.txt')
call simpletree#OnDelete()
call assert_true(filereadable(s:root .. '/beta.txt'))
call assert_true(getbufvar(s:beta_buf, '&modified'))
call writefile(['source-v2'], s:root .. '/beta.txt')
call setbufline(s:beta_buf, 1, ['source-v2'])
call setbufvar(s:beta_buf, '&modified', 0)

" Copy and overwrite use the staged transaction path.
call s:Select('beta.txt')
call simpletree#OnCopy()
call s:Select('dest/')
call simpletree#OnPaste()
call assert_equal(['source-v2'], readfile(s:root .. '/dest/beta.txt'))
call writefile(['source-v3'], s:root .. '/beta.txt')
call s:Select('beta.txt')
call simpletree#OnCopy()
call s:Select('dest/')
call feedkeys("o\<CR>", 't')
call simpletree#OnPaste()
call assert_equal(['source-v3'], readfile(s:root .. '/dest/beta.txt'))

" A cut only clears its source after the complete destination is installed.
call s:Select('gamma.txt')
call simpletree#OnCut()
call s:Select('dest/')
call simpletree#OnPaste()
call assert_false(filereadable(s:root .. '/gamma.txt'))
call assert_equal(['gamma'], readfile(s:root .. '/dest/gamma.txt'))

" Backend errors become a stable row instead of an immediate rescan loop.
call delete(s:root, 'rf')
call delete(s:outside, 'rf')
SimpleTreeRefresh
sleep 300m
call assert_true(s:TreeLine('failed to inspect directory') > 0)

" Pending callbacks must not resurrect a tree that was just closed.
SimpleTreeRefresh
SimpleTreeClose
sleep 500m
call assert_equal(0, s:TreeWin(), 'tree reopened after Close()')
call simpletree#Stop()

if s:beta_buf > 0
  execute 'silent! bwipeout! ' .. s:beta_buf
endif
if s:child_buf > 0
  execute 'silent! bwipeout! ' .. s:child_buf
endif
if s:alias_buf > 0 && s:alias_buf != s:child_buf
  execute 'silent! bwipeout! ' .. s:alias_buf
endif
if s:outside_buf > 0
  execute 'silent! bwipeout! ' .. s:outside_buf
endif
call delete(s:root, 'rf')
if len(v:errors) > 0
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
