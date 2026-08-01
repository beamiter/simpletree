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
