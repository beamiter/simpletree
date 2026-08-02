" 书签:切换、持久化、跳转、清理。
"
" 书签写在一个 JSON 文件里,重启后还在;它也会改变树里的行内容,所以渲染缓存
" 的失效由 tests/vim_render_cache.vim 一并盯着。
"
" 跑法:vim -Nu NONE -n -i NONE -es -S tests/vim_bookmarks.vim

set nocompatible
set nomore
set lines=40 columns=120

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/bookmarks-errors.log')

let g:simpletree_daemon_path = s:root . '/lib/simpletree-daemon'
if !executable(g:simpletree_daemon_path)
  let g:simpletree_daemon_path = s:root . '/target/release/simpletree-daemon'
endif
let g:simpletree_git_status = 0

" 用一个临时文件,绝不碰用户真正的书签。
let s:store = tempname() . '/bookmarks.json'
let g:simpletree_bookmarks_file = s:store

runtime plugin/simpletree.vim

let s:tmp = tempname()
call mkdir(s:tmp . '/sub', 'p')
call writefile(['x'], s:tmp . '/one.txt')
call writefile(['x'], s:tmp . '/two.txt')
call writefile(['x'], s:tmp . '/sub/three.txt')

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
function! s:Text() abort
  return join(getbufline(s:Buf(), 1, '$'), "\n")
endfunction
function! s:Goto(lnum) abort
  call win_execute(bufwinid(s:Buf()), 'call cursor(' . a:lnum . ', 1)')
endfunction
function! s:Wait(ms) abort
  let l:i = 0
  while l:i < a:ms / 10
    sleep 10m
    let l:i += 1
  endwhile
endfunction
function! s:CursorLine() abort
  return getcurpos(bufwinid(s:Buf()))[1]
endfunction

call simpletree#Toggle(s:tmp)
call s:Wait(1500)
call assert_true(s:Buf() > 0, '树已打开')

" ------------------------------------------------------------- 切换与持久化 ---

call assert_equal([], simpletree#BookmarkList(), '初始没有书签')

call s:Goto(2)
call simpletree#OnBookmarkToggle()
call s:Wait(200)
call assert_true(s:Text() =~# '★', '标记出现在树里')
call assert_equal(1, len(simpletree#BookmarkList()), '记录了一个书签')
call assert_true(filereadable(s:store), '书签落盘')

" 落盘的内容必须是可读的 JSON 路径数组,而不是内部结构。
let s:saved = json_decode(join(readfile(s:store), "\n"))
call assert_equal(v:t_list, type(s:saved), '存的是数组')
call assert_equal(simpletree#BookmarkList(), s:saved, '盘上与内存一致')

" 再切一次就是取消。
call s:Goto(2)
call simpletree#OnBookmarkToggle()
call s:Wait(200)
call assert_false(s:Text() =~# '★', '取消后标记消失')
call assert_equal([], simpletree#BookmarkList(), '书签已删除')
call assert_equal([], json_decode(join(readfile(s:store), "\n")), '删除也落盘')

" ------------------------------------------------------------------ 跳转 ---

" 给两个不同的行加书签,]b / [b 应该在它们之间循环。
call s:Goto(2)
call simpletree#OnBookmarkToggle()
call s:Wait(150)
call s:Goto(4)
call simpletree#OnBookmarkToggle()
call s:Wait(150)
call assert_equal(2, len(simpletree#BookmarkList()), '两个书签')

call s:Goto(1)
call simpletree#OnBookmarkNext()
let s:first = s:CursorLine()
call assert_true(s:first > 1, ']b 跳到了一个书签行: ' . s:first)
call simpletree#OnBookmarkNext()
let s:second = s:CursorLine()
call assert_notequal(s:first, s:second, ']b 继续跳到下一个')
call simpletree#OnBookmarkPrev()
call assert_equal(s:first, s:CursorLine(), '[b 跳回上一个')

" 越过最后一个要绕回开头,而不是卡住。
call simpletree#OnBookmarkPrev()
call simpletree#OnBookmarkPrev()
call assert_true(s:CursorLine() > 0, '循环不会卡死')

" ------------------------------------------------------------- 无效书签清理 ---

" 指向已删除文件的书签应在列出时被清掉,免得列表越积越多。
call writefile(['x'], s:tmp . '/gone.txt')
call simpletree#Refresh()
call s:Wait(1200)
let s:before = len(simpletree#BookmarkList())
" 直接写进存储再重载,模拟"上次会话留下的书签指向了已删除的文件"。
call writefile([json_encode(simpletree#BookmarkList() + [s:tmp . '/never-existed.txt'])], s:store)
call simpletree#BookmarkClear()
call s:Wait(100)
call assert_equal([], simpletree#BookmarkList(), '清空后没有书签')
call assert_false(s:Text() =~# '★', '清空后树里没有标记')

" ------------------------------------------------------------------ 命令 ---

call assert_equal(2, exists(':SimpleTreeBookmarks'))
call assert_equal(2, exists(':SimpleTreeBookmarkClear'))

" 没有书签时列表命令不应该报错。
SimpleTreeBookmarks
call assert_equal([], simpletree#BookmarkList())

" ------------------------------------------------------------------ 收尾 ---

call simpletree#Toggle()
call delete(s:tmp, 'rf')
call delete(fnamemodify(s:store, ':h'), 'rf')

if len(v:errors)
  call writefile(v:errors, s:root . '/tests/bookmarks-errors.log')
  for s:e in v:errors
    echomsg s:e
  endfor
  cquit
endif
qall!
