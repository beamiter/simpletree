" 子树渲染缓存的安全网。
"
" Render() 现在按目录复用已渲染好的切片，正确性依赖 "所有会影响行内容的状态
" 要么进 SubtreeValid() 校验、要么 BumpRenderEpoch()" 这条规则。这里的做法是：
" 每做一次操作，就把 "走缓存" 的渲染结果和 "关掉缓存重算" 的结果逐行比对。
" 任何一处漏掉的失效点都会让两者分叉，测试立刻失败。
"
" 跑法：vim -Nu NONE -n -i NONE -es -S tests/vim_render_cache.vim

set nocompatible
set nomore
set lines=60 columns=200

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/render-cache-errors.log')

let g:simpletree_daemon_path = s:root . '/target/release/simpletree-daemon'
if !executable(g:simpletree_daemon_path)
  let g:simpletree_daemon_path = s:root . '/lib/simpletree-daemon'
endif
let g:simpletree_git_status = 0
let g:simpletree_bookmarks_file = tempname() . '/bookmarks.json'

" ---------------------------------------------------------------- fixture ---

let s:tmp = tempname()
for s:d in ['alpha', 'alpha/one', 'alpha/two', 'beta', 'beta/three']
  call mkdir(s:tmp . '/' . s:d, 'p')
endfor
let s:files = [
      \ 'alpha/a.rs', 'alpha/b.py', 'alpha/one/c.js', 'alpha/one/d.md',
      \ 'alpha/two/e.go', 'beta/f.txt', 'beta/three/g.vim', 'beta/three/h.json',
      \ 'top.md',
      \ ]
for s:f in s:files
  call writefile(['x'], s:tmp . '/' . s:f)
endfor

" 会话状态（展开集合）也落盘：绝不碰用户真正的 state.json。
let g:simpletree_state_file = tempname() . '/state.json'
runtime plugin/simpletree.vim

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletree.vim'})[0].sid
endfunction
function! s:P(name) abort
  return function(printf('<SNR>%d_%s', s:Sid(), a:name))
endfunction
function! s:Buf() abort
  let l:b = bufnr('SimpleTree')
  if l:b <= 0
    for l:w in getwininfo()
      if getbufvar(l:w.bufnr, '&filetype') ==# 'simpletree'
        return l:w.bufnr
      endif
    endfor
  endif
  return l:b
endfunction

function! s:Snapshot() abort
  return getbufline(s:Buf(), 1, '$')
endfunction

" 关键断言：同一状态下，走缓存与不走缓存必须渲染出完全一样的内容。
function! s:AssertMatchesUncached(label) abort
  let l:cached = s:Snapshot()
  call simpletree#TestSetRenderCache(v:false)
  call call(s:P('Render'), [])
  let l:fresh = s:Snapshot()
  call simpletree#TestSetRenderCache(v:true)
  call call(s:P('Render'), [])
  call assert_equal(l:fresh, l:cached, 'cached render diverged from uncached: ' . a:label)
  if l:fresh !=# l:cached
    call writefile(['=== cached ==='] + l:cached + ['=== uncached ==='] + l:fresh,
          \ s:root . '/tests/render-cache-divergence.log')
  endif
endfunction

function! s:Wait(ms) abort
  let l:i = 0
  while l:i < a:ms / 10
    sleep 10m
    let l:i += 1
  endwhile
endfunction

" ------------------------------------------------------------------ drive ---

call simpletree#Toggle(s:tmp)
call s:Wait(1500)
call assert_true(s:Buf() > 0, 'the tree buffer exists')
call s:AssertMatchesUncached('initial render')

" 逐行展开每一个目录，每展开一次比对一次。
let s:step = 0
while s:step < 12
  let s:l = 1
  while s:l <= line('$', bufwinid(s:Buf()))
    call win_execute(bufwinid(s:Buf()), 'call cursor(' . s:l . ', 1)')
    silent! call simpletree#OnExpand()
    let s:l += 1
  endwhile
  call s:Wait(400)
  call s:AssertMatchesUncached('after expand pass ' . s:step)
  let s:step += 1
endwhile

let s:full = s:Snapshot()
call assert_true(len(s:full) >= 10, 'the fully expanded tree has content: ' . len(s:full))

" 折叠中间某个目录。
call win_execute(bufwinid(s:Buf()), 'call cursor(2, 1)')
silent! call simpletree#OnCollapse()
call s:Wait(200)
call s:AssertMatchesUncached('after collapsing one directory')

" 再展开回去，必须还原成折叠前那棵树。
silent! call simpletree#OnExpand()
call s:Wait(400)
call s:AssertMatchesUncached('after re-expanding')

" ------------------------------------------------------------ 未保存标记 ---

" s_modified_paths 改变会换掉行尾的装饰，必须使缓存失效。
execute 'edit ' . fnameescape(s:tmp . '/top.md')
setlocal modifiable
call setline(1, 'dirty')
call simpletree#UpdateDecorations()
call s:Wait(200)
call s:AssertMatchesUncached('after marking a file modified')
setlocal nomodified
call simpletree#UpdateDecorations()
call s:Wait(200)
call s:AssertMatchesUncached('after clearing the modified flag')

" ---------------------------------------------------------------- 过滤 ---

call simpletree#TestSetFilter('c')
call s:Wait(200)
call s:AssertMatchesUncached('with a name filter active')
call simpletree#TestSetFilter('')
call s:Wait(200)
call s:AssertMatchesUncached('after clearing the filter')

" ------------------------------------------------------------ 运行时配置 ---

" 配置签名走的是 O(1) 比对；改掉任何一项都必须让整棵缓存作废。
let g:simpletree_folder_suffix = 0
call call(s:P('Render'), [])
call s:AssertMatchesUncached('after turning folder suffixes off')
let g:simpletree_folder_suffix = 1

let g:simpletree_show_file_icons = 0
call call(s:P('Render'), [])
call s:AssertMatchesUncached('after turning file icons off')
let g:simpletree_show_file_icons = 1

let g:simpletree_modified_symbol = '*'
call call(s:P('Render'), [])
call s:AssertMatchesUncached('after changing the modified symbol')

" -------------------------------------------------------------- 刷新/重扫 ---

" 重扫会换掉 s_cache 里的 list 对象，身份比对必须发现。
call simpletree#Refresh()
call s:Wait(1200)
call s:AssertMatchesUncached('after a full refresh')

" -------------------------------------------------------------- 书签 ---

" 书签标记属于行内容,增删书签必须让缓存失效。
call win_execute(bufwinid(s:Buf()), 'call cursor(2, 1)')
call simpletree#OnBookmarkToggle()
call s:Wait(200)
call assert_true(join(s:Snapshot(), "\n") =~# '★', '书签标记出现在树里')
call s:AssertMatchesUncached('after adding a bookmark')

call win_execute(bufwinid(s:Buf()), 'call cursor(2, 1)')
call simpletree#OnBookmarkToggle()
call s:Wait(200)
call assert_false(join(s:Snapshot(), "\n") =~# '★', '取消后标记消失')
call s:AssertMatchesUncached('after removing a bookmark')

" 改书签符号走的是配置签名(O(1) 比对),同样必须整体失效。
call win_execute(bufwinid(s:Buf()), 'call cursor(2, 1)')
call simpletree#OnBookmarkToggle()
call s:Wait(200)
let g:simpletree_bookmark_symbol = '@@'
call call(s:P('Render'), [])
call assert_true(join(s:Snapshot(), "\n") =~# '@@', '改符号后立即生效')
call s:AssertMatchesUncached('after changing the bookmark symbol')
unlet g:simpletree_bookmark_symbol

let g:simpletree_show_bookmarks = 0
call call(s:P('Render'), [])
call s:AssertMatchesUncached('after turning bookmarks off')
let g:simpletree_show_bookmarks = 1
call win_execute(bufwinid(s:Buf()), 'call cursor(2, 1)')
call simpletree#OnBookmarkToggle()
call s:Wait(200)

" -------------------------------------------------------------- 标记 ---

" 批量操作的标记同样属于行内容，遵守和书签一样的失效规则。
call win_execute(bufwinid(s:Buf()), 'call cursor(3, 1)')
call simpletree#OnMarkToggle()
call s:Wait(200)
call assert_true(join(s:Snapshot(), "\n") =~# '✓', '标记出现在树里')
call s:AssertMatchesUncached('after marking a node')

let g:simpletree_mark_symbol = '%%'
call call(s:P('Render'), [])
call assert_true(join(s:Snapshot(), "\n") =~# '%%', '改标记符号后立即生效')
call s:AssertMatchesUncached('after changing the mark symbol')
unlet g:simpletree_mark_symbol

call simpletree#OnMarkClear()
call s:Wait(200)
call assert_false(join(s:Snapshot(), "\n") =~# '✓', '清除后标记消失')
call s:AssertMatchesUncached('after clearing marks')

" ------------------------------------------------------------ 新增/删除 ---

call writefile(['new'], s:tmp . '/alpha/zz_new.rs')
call simpletree#Refresh()
call s:Wait(1200)
call assert_true(join(s:Snapshot(), "\n") =~# 'zz_new', 'a newly created file shows up')
call s:AssertMatchesUncached('after creating a file')

call delete(s:tmp . '/alpha/zz_new.rs')
call simpletree#Refresh()
call s:Wait(1200)
call assert_false(join(s:Snapshot(), "\n") =~# 'zz_new', 'a deleted file disappears')
call s:AssertMatchesUncached('after deleting a file')

" -------------------------------------------------------- 性能统计旁路 ---

" 查询不能改变任何计数或缓存身份；重置也只清计数，不能 bump epoch 或清掉
" 已构建子树。重置后的下一次相同 Render 应直接重新累计一次 cache hit。
let s:stats_before = simpletree#TestGetState().render_stats
call assert_true(s:stats_before.renders > 0, 'render counter never advanced')
call assert_true(s:stats_before.cache_hits > 0, 'render cache recorded no hits')
call assert_true(s:stats_before.cache_misses > 0, 'render cache recorded no misses')
call assert_true(s:stats_before.max_ms >= s:stats_before.last_ms,
      \ 'explicit Vim-9.0-compatible Float maximum lost the latest sample')
silent SimpleTreeStats
let s:stats_after_query = simpletree#TestGetState().render_stats
call assert_equal(s:stats_before, s:stats_after_query,
      \ 'reading render statistics changed counters or cache state')

SimpleTreeStats!
let s:stats_reset = simpletree#TestGetState().render_stats
for s:key in ['renders', 'cache_hits', 'cache_misses', 'invalidations',
      \ 'invalidated_subtrees', 'total_changed_lines', 'buffer_writes']
  call assert_equal(0, s:stats_reset[s:key], 'stats reset missed ' . s:key)
endfor
call assert_equal(s:stats_before.epoch, s:stats_reset.epoch,
      \ 'stats reset bumped the render epoch')
call assert_equal(s:stats_before.cache_entries, s:stats_reset.cache_entries,
      \ 'stats reset discarded subtree cache entries')
call call(s:P('Render'), [])
let s:stats_reused = simpletree#TestGetState().render_stats
call assert_equal(1, s:stats_reused.renders, 'post-reset render was not counted')
call assert_true(s:stats_reused.cache_hits > 0, 'stats reset invalidated a reusable subtree')
call assert_equal(0, s:stats_reused.cache_misses, 'unchanged post-reset render rebuilt a subtree')
call assert_equal(0, s:stats_reused.last_changed_lines,
      \ 'unchanged render did not reset last_changed_lines to zero')
call assert_equal(0, s:stats_reused.buffer_writes,
      \ 'unchanged render reported a successful buffer API write')

" buffer_writes 数的是成功调用次数，而不是有改动的 Render 次数。
" 两段不相邻的 diff 必须对应两次 setbufline()；缩短一行再对应
" 一次 deletebufline()。同时用 nomodifiable 钉死失败返回不得计数。
let s:probe_base = s:Snapshot()
call assert_true(len(s:probe_base) >= 3, 'buffer-write probe needs three tree lines')
let s:probe_lines = copy(s:probe_base)
let s:probe_lines[0] ..= ' [stats-probe-a]'
let s:probe_lines[2] ..= ' [stats-probe-b]'
SimpleTreeStats!
call call(s:P('UpdateBufferDiff'), [s:probe_lines])
let s:stats_failed_write = simpletree#TestGetState().render_stats
call assert_equal(0, s:stats_failed_write.buffer_writes,
      \ 'failed setbufline() was counted as a buffer write')
call assert_equal(0, s:stats_failed_write.last_changed_lines,
      \ 'failed setbufline() was counted as changed lines')
call assert_equal(s:probe_base, s:Snapshot(), 'failed write changed the tree buffer')

call setbufvar(s:Buf(), '&modifiable', 1)
call call(s:P('UpdateBufferDiff'), [s:probe_lines])
let s:stats_two_runs = simpletree#TestGetState().render_stats
call assert_equal(2, s:stats_two_runs.buffer_writes,
      \ 'two separated diff runs were not counted as two successful API writes')
call assert_equal(2, s:stats_two_runs.last_changed_lines,
      \ 'successful changed-line count did not match the two diff runs')
call call(s:P('UpdateBufferDiff'), [s:probe_lines])
let s:stats_unchanged_probe = simpletree#TestGetState().render_stats
call assert_equal(2, s:stats_unchanged_probe.buffer_writes,
      \ 'unchanged low-level diff added a buffer write')
call assert_equal(0, s:stats_unchanged_probe.last_changed_lines,
      \ 'unchanged low-level diff retained the prior changed-line count')
call call(s:P('UpdateBufferDiff'), [s:probe_lines[0 : -2]])
let s:stats_delete = simpletree#TestGetState().render_stats
call assert_equal(3, s:stats_delete.buffer_writes,
      \ 'successful deletebufline() was not counted as an API write')
call assert_equal(1, s:stats_delete.last_changed_lines,
      \ 'successful deletebufline() did not count its removed line')
let s:stats_output = execute('SimpleTreeStats')
call assert_match('successful API writes=3', s:stats_output,
      \ 'stats output does not describe successful API write calls')
call call(s:P('UpdateBufferDiff'), [s:probe_base])
call setbufvar(s:Buf(), '&modifiable', 0)
call assert_equal(s:probe_base, s:Snapshot(), 'buffer-write probe did not restore tree lines')

" ------------------------------------------------------------------ 收尾 ---

call simpletree#Toggle()
call delete(s:tmp, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root . '/tests/render-cache-errors.log')
  for s:e in v:errors
    echomsg s:e
  endfor
  cquit
endif
qall!
