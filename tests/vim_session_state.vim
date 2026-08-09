set nocompatible
set nomore
set lines=40 columns=120

" Session state: the expanded set and the last root outlive the session.
"
" Width has lived in $XDG_STATE_HOME/simpletree/width and bookmarks in
" bookmarks.json for a while, so the state-file pattern was established — but
" the one thing a user rebuilds by hand every single session, the set of
" expanded directories, was thrown away on :qa.
"
" 跑法：vim -Nu NONE -n -i NONE -es -S tests/vim_session_state.vim

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:daemon = s:repo .. '/target/debug/simpletree-daemon'
if !executable(s:daemon)
  let s:daemon = s:repo .. '/lib/simpletree-daemon'
endif

let s:root = tempname()
call mkdir(s:root .. '/sub/nested', 'p')
call mkdir(s:root .. '/other', 'p')
call writefile(['x'], s:root .. '/one.txt')
call writefile(['x'], s:root .. '/sub/three.txt')
call writefile(['x'], s:root .. '/other/four.txt')

" 一份"上次会话"留下的状态文件。里面故意混进一个已经不存在的目录：文件是
" 用户机器上放了几个月的东西，路径消失是常态，不是异常。
let s:store = tempname() .. '/state.json'
call mkdir(fnamemodify(s:store, ':h'), 'p')
call writefile([json_encode({
      \ 'roots': {s:root: {
      \   'expanded': [s:root .. '/sub', s:root .. '/gone'], 'saved_at': 1000}},
      \ 'last_root': s:root})], s:store)

let g:simpletree_state_file = s:store
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

function! s:LineNr(fragment) abort
  let l:lines = s:Lines()
  for l:i in range(len(l:lines))
    if stridx(l:lines[l:i], a:fragment) >= 0
      return l:i + 1
    endif
  endfor
  return 0
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

function! s:Stored() abort
  return filereadable(s:store) ? json_decode(join(readfile(s:store), "\n")) : {}
endfunction

let s:finished = 0
try

" ------------------------------------------------------------------ 恢复 ---

enew
execute 'SimpleTree ' .. fnameescape(s:root)
call assert_true(s:WaitFor({-> s:LineNr('one.txt') > 0}), 'the tree never listed its root')

" sub/ 在文件里，所以它自己展开了——用户一次键都没按。
call assert_true(s:WaitFor({-> s:LineNr('three.txt') > 0}),
      \ 'the persisted expansion was not restored: ' .. string(s:Lines()))
" other/ 不在文件里，必须保持折叠：恢复不是"全部展开"。
call assert_equal(0, s:LineNr('four.txt'),
      \ 'a directory that was not in the state file opened anyway')
" 已经不存在的路径不能进 s_state：留着它会让后面的 I 在空气上展开。
call assert_false(has_key(s:Vars()['s_state'], s:root .. '/gone'),
      \ 'a directory that no longer exists was restored into the expansion state')

" ------------------------------------------------------------------ 保存 ---

" 折掉 sub/，展开 other/：这次会话的形状和文件里的那份不一样了。
call win_execute(s:TreeWin(), 'call cursor(' .. s:LineNr('sub') .. ', 1)')
silent! call simpletree#OnCollapse()
call win_execute(s:TreeWin(), 'call cursor(' .. s:LineNr('other') .. ', 1)')
silent! call simpletree#OnExpand()
call assert_true(s:WaitFor({-> s:LineNr('four.txt') > 0}), 'other/ never opened')

call simpletree#PersistSessionState()
let s:record = get(get(s:Stored(), 'roots', {}), s:root, {})
call assert_equal([s:root .. '/other'], get(s:record, 'expanded', []),
      \ 'the saved expansion set does not match the tree on screen')
call assert_true(get(s:record, 'saved_at', 0) > 1000, 'saved_at was not refreshed')
call assert_equal(s:root, get(s:Stored(), 'last_root', ''), 'last_root was not recorded')

" 同一个会话里重开同一个根不会把用户刚折掉的目录顶回来。
SimpleTreeClose
execute 'SimpleTree ' .. fnameescape(s:root)
call assert_true(s:WaitFor({-> s:LineNr('one.txt') > 0}), 'the tree did not reopen')
call assert_equal(0, s:LineNr('three.txt'),
      \ 'reopening re-expanded a directory the user had just collapsed')

" ---------------------------------------------------------------- 换根即存 ---

" 会话中途换根（这里是 OnRootHere，`r`）时旧根的展开集合必须先落盘：换完之后
" s_root 再也指不回它，而它的展开状态此刻还完整地留在内存里。
call simpletree#OnToggleRootLock()
call win_execute(s:TreeWin(), 'call cursor(' .. s:LineNr('sub') .. ', 1)')
call simpletree#OnRootHere()
call assert_equal(s:root .. '/sub', simpletree#GetRoot(), 'the root did not change')
call assert_true(s:WaitFor({-> s:LineNr('three.txt') > 0}), 'the new root never listed')
call assert_equal([s:root .. '/other'],
      \ get(get(get(s:Stored(), 'roots', {}), s:root, {}), 'expanded', []),
      \ 're-rooting lost the expansion set of the root it left')
call assert_equal(s:root .. '/sub', get(s:Stored(), 'last_root', ''),
      \ 're-rooting did not update last_root')

" ------------------------------------------------------------------ 上限 ---

call win_execute(s:TreeWin(), 'call cursor(' .. s:LineNr('nested') .. ', 1)')
silent! call simpletree#OnExpand()
call assert_true(s:WaitFor({-> s:Vars()['s_state']->get(s:root .. '/sub/nested', {})
      \ ->get('expanded', 0)}), 'nested/ never opened')
let g:simpletree_state_max_dirs = 0
call simpletree#PersistSessionState()
call assert_false(has_key(get(s:Stored(), 'roots', {}), s:root .. '/sub'),
      \ 'the per-root directory cap was ignored')
let g:simpletree_state_max_dirs = 500
call simpletree#PersistSessionState()
call assert_equal([s:root .. '/sub/nested'],
      \ get(get(get(s:Stored(), 'roots', {}), s:root .. '/sub', {}), 'expanded', []),
      \ 'raising the cap did not record the expansion again')

" 根的数量也有上限。只剩一个名额时留下的必须是正在看的那棵树：s:root 更旧，
" s:root/sub 是当前根，而当前根永远不参与淘汰。
let g:simpletree_state_max_roots = 1
call simpletree#PersistSessionState()
call assert_equal([s:root .. '/sub'], keys(get(s:Stored(), 'roots', {})),
      \ 'the root cap dropped the root of the session doing the saving')

" 淘汰的顺序是 saved_at LRU：名额不够时先丢最久没保存的那个。上面那条断言
" 只有一个候选根，谁走谁留和比较器的方向无关——要看见方向，候选得比名额多。
" 三个 saved_at 互不相同的旧根从磁盘进来，当前根之外还剩两个名额。
let s:old = tempname()
let s:mid = tempname()
let s:new = tempname()
call mkdir(s:old .. '/d', 'p')
call mkdir(s:mid .. '/d', 'p')
call mkdir(s:new .. '/d', 'p')
let s:seeded = s:Stored()
let s:seeded.roots[s:old] = {'expanded': [s:old .. '/d'], 'saved_at': 100}
let s:seeded.roots[s:mid] = {'expanded': [s:mid .. '/d'], 'saved_at': 200}
let s:seeded.roots[s:new] = {'expanded': [s:new .. '/d'], 'saved_at': 300}
call writefile([json_encode(s:seeded)], s:store)

let g:simpletree_state_max_roots = 3
call simpletree#PersistSessionState()
call assert_equal(sort([s:root .. '/sub', s:mid, s:new]),
      \ sort(keys(get(s:Stored(), 'roots', {}))),
      \ 'the cap evicted by the wrong end of saved_at: the oldest root must go first')

" 再收一个名额：三个候选只剩一个，活下来的得是 saved_at 最大的那个。
let g:simpletree_state_max_roots = 2
call simpletree#PersistSessionState()
call assert_equal(sort([s:root .. '/sub', s:new]),
      \ sort(keys(get(s:Stored(), 'roots', {}))),
      \ 'the most recently saved root was not the last one standing')

" 把这几个种子根清掉，后面的用例接着从"只有当前根"这个状态开始。
let g:simpletree_state_max_roots = 1
call simpletree#PersistSessionState()
call assert_equal([s:root .. '/sub'], keys(get(s:Stored(), 'roots', {})),
      \ 'the seeded roots outlived a cap of one')
let g:simpletree_state_max_roots = 20
call delete(s:old, 'rf')
call delete(s:mid, 'rf')
call delete(s:new, 'rf')

" -------------------------------------------------------------- 并发实例 ---

" 状态文件是所有 Vim 共用的，而每个实例只知道自己那个根，还把整份文件重写。
" 会话开始时读进来的那份快照到落盘时可能已经是几小时前的了：两个窗口开两个
" 项目是常态，谁后退出谁的记录留下、另一个的被抹掉，文件最后收敛成一个根——
" 那正好是 |g:simpletree_state_max_roots| 说它能记住 20 个的反面。
"
" 另一个实例刚刚写过文件（我们的内存快照里没有它那个根），现在轮到我们保存。
let s:other = tempname()
call mkdir(s:other .. '/x', 'p')
let s:disk = s:Stored()
let s:disk.roots[s:other] = {'expanded': [s:other .. '/x'], 'saved_at': 4242}
call writefile([json_encode(s:disk)], s:store)

call simpletree#PersistSessionState()
call assert_equal([s:other .. '/x'],
      \ get(get(get(s:Stored(), 'roots', {}), s:other, {}), 'expanded', []),
      \ "saving erased the root a concurrent instance had just recorded")
call assert_equal([s:root .. '/sub/nested'],
      \ get(get(get(s:Stored(), 'roots', {}), s:root .. '/sub', {}), 'expanded', []),
      \ 'merging with the file on disk lost this instance own root')
call assert_equal(s:root .. '/sub', get(s:Stored(), 'last_root', ''),
      \ 'last_root did not follow the instance that saved last')

" 合并不是"磁盘赢"：当前根这次没有任何可恢复的展开时，磁盘上那条旧记录已经
" 作废，不能靠合并复活。
let g:simpletree_state_max_dirs = 0
call simpletree#PersistSessionState()
call assert_false(has_key(get(s:Stored(), 'roots', {}), s:root .. '/sub'),
      \ 'a stale record for the current root came back from disk')
call assert_true(has_key(get(s:Stored(), 'roots', {}), s:other),
      \ 'dropping our own record took the concurrent instance down with it')
let g:simpletree_state_max_dirs = 500
call simpletree#PersistSessionState()

" 合并之后上限还得成立，否则 roots 会随着别的实例无限长下去。
let g:simpletree_state_max_roots = 1
call simpletree#PersistSessionState()
call assert_equal([s:root .. '/sub'], keys(get(s:Stored(), 'roots', {})),
      \ 'the root cap was not applied to the merged map')
let g:simpletree_state_max_roots = 20
call delete(s:other, 'rf')

" ------------------------------------------------------------------ 关闭 ---

" 关掉持久化之后什么都不写：文件停在上一次保存的样子。
let s:before = readfile(s:store)
let g:simpletree_persist_state = 0
call win_execute(s:TreeWin(), 'call cursor(' .. s:LineNr('nested') .. ', 1)')
silent! call simpletree#OnCollapse()
call simpletree#PersistSessionState()
call assert_equal(s:before, readfile(s:store),
      \ 'the state file was written with persistence turned off')
let g:simpletree_persist_state = 1

" :SimpleTreeStateClear 真的删文件。
SimpleTreeStateClear
call assert_false(filereadable(s:store), 'the state file survived :SimpleTreeStateClear')

let s:finished = 1

catch
  call add(v:errors, 'unexpected exception: ' .. v:exception .. ' @ ' .. v:throwpoint)
endtry

if !s:finished
  call add(v:errors, 'the test body did not run to completion')
endif

let g:simpletree_persist_state = 0
silent! SimpleTreeClose
call simpletree#Stop()
call delete(s:root, 'rf')
call delete(fnamemodify(s:store, ':h'), 'rf')
if len(v:errors) > 0
  call writefile(v:errors, '/tmp/simpletree-vim-session-state-errors')
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
