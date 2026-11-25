" Production synchronous transfers; the peer lists the actual filesystem
" but implements no transfers. Test multiple changes without widening scope.
set nocompatible nomore
set lines=60 columns=200
let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:repo)
let s:tmp = tempname()
let s:root = s:tmp .. '/work'
let s:target = s:root .. '/target'
let s:moves = s:root .. "/moves"
call mkdir(s:moves, "p")
call mkdir(s:target, 'p')
let s:names = ['a.txt', 'b.txt', 'c.txt']
for s:name in s:names
  call writefile([s:name], s:root .. '/' .. s:name)
endfor
let g:simpletree_daemon_path = s:repo .. '/tests/fake_tree_daemon.py'
let g:simpletree_async_fs_ops = 0
let g:simpletree_git_status = 0
let g:simpletree_persist_width = 0
let g:simpletree_bookmarks_file = s:tmp .. '/bookmarks.json'
let g:simpletree_state_file = s:tmp .. '/state.json'
runtime plugin/simpletree.vim

let s:events = []
let s:other_events = []
autocmd User SimpleTreePathsChanged call add(s:events, deepcopy(g:simpletree_event.paths))
autocmd User SimpleTreeFileCreated,SimpleTreeFileRenamed,SimpleTreeFileDeleted call add(s:other_events, expand('<amatch>'))

function! s:Select(path) abort
  for l:w in getwininfo()
    if getbufvar(l:w.bufnr, '&filetype') !=# 'simpletree'
      continue
    endif
    call win_gotoid(l:w.winid)
    let l:sid = getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
    let l:index = getscriptinfo({'sid': l:sid})[0].variables.s_line_index
    for l:i in range(len(l:index))
      if get(l:index[l:i], 'path', '') ==# a:path
        call cursor(l:i + 1, 1)
        return 1
      endif
    endfor
  endfor
  return 0
endfunction

try
  execute 'SimpleTree ' .. fnameescape(s:root)
  for s:attempt in range(300)
    if s:Select(s:target) && s:Select(s:root .. '/c.txt')
      break
    endif
    sleep 10m
  endfor

  for s:name in s:names
    call assert_true(s:Select(s:root .. '/' .. s:name), 'mark ' .. s:name)
    call simpletree#OnMarkToggle()
  endfor
  call simpletree#OnCopy()
  call assert_true(s:Select(s:target), 'copy destination')
  call simpletree#OnPaste()
  for s:name in s:names
    call assert_equal([s:name], readfile(s:target .. '/' .. s:name))
    call assert_equal([s:name], readfile(s:root .. '/' .. s:name))
  endfor
  call assert_equal(map(copy(s:names), '[s:target .. "/" .. v:val]'),
        \ s:events, 'three installed paths reported separately without touching sources')

  let s:events = []
  call assert_true(s:Select(s:root .. '/a.txt'), 'move source')
  call simpletree#OnCut()
  call assert_true(s:Select(s:moves), 'move destination')
  call simpletree#OnPaste()
  call assert_false(filereadable(s:root .. '/a.txt'))
  call assert_equal(['a.txt'], readfile(s:moves .. '/a.txt'))
  call assert_equal([[s:root .. '/a.txt', s:moves .. '/a.txt']], s:events,
        \ 'a completed cut reports both precise paths')
  call assert_equal([], s:other_events, 'paste is not reported as create, delete or rename')
catch
  call assert_report('unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

call delete(s:tmp, 'rf')
if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
