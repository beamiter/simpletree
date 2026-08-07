set nocompatible
set nomore

let s:root = fnamemodify(expand('<sfile>:p:h'), ':h')
call delete('/tmp/simpletree-vim-sorting-errors')
execute 'set runtimepath^=' . fnameescape(s:root)
let g:simpletree_sort = 'invalid'
let g:simpletree_sort_reverse = {}
runtime plugin/simpletree.vim
call assert_equal('name', g:simpletree_sort)
call assert_equal(0, g:simpletree_sort_reverse)

" Load the Vim9 autoload module, then exercise frontend ordering with entries
" in the daemon's baseline name order.  Directories stay first when reversed.
call simpletree#EffectiveKeymap()
let s:info = getscriptinfo({'name': 'autoload/simpletree.vim'})[0]
let s:sorted = function(printf('<SNR>%d_SortedEntries', s:info.sid))
let s:entries = [
      \ {'name': 'dir',   'path': '/dir',   'is_dir': v:true,  'mtime': 1,   'size': 1},
      \ {'name': 'a.rs',  'path': '/a.rs',  'is_dir': v:false, 'mtime': 100, 'size': 10},
      \ {'name': 'm.txt', 'path': '/m.txt', 'is_dir': v:false, 'mtime': 300, 'size': 20},
      \ {'name': 'z.py',  'path': '/z.py',  'is_dir': v:false, 'mtime': 200, 'size': 30},
      \ ]

function! s:Names(mode, reverse) abort
  let g:simpletree_sort = a:mode
  let g:simpletree_sort_reverse = a:reverse
  return map(call(s:sorted, [deepcopy(s:entries)]), 'v:val.name')
endfunction

call assert_equal(['dir', 'a.rs', 'm.txt', 'z.py'], s:Names('name', 0))
call assert_equal(['dir', 'z.py', 'a.rs', 'm.txt'], s:Names('extension', 0))
call assert_equal(['dir', 'm.txt', 'z.py', 'a.rs'], s:Names('mtime', 0))
call assert_equal(['dir', 'z.py', 'm.txt', 'a.rs'], s:Names('size', 0))
call assert_equal(['dir', 'a.rs', 'm.txt', 'z.py'], s:Names('size', 1))

let s:mapped = simpletree#EffectiveKeymap()
call assert_equal('sort_cycle', get(s:mapped, 's', ''))
call assert_equal('sort_reverse', get(s:mapped, 'gs', ''))
call assert_equal(['mtime'], simpletree#CompleteSort('mt', '', 0))
call assert_equal(2, exists(':SimpleTreeSort'))
call assert_equal(2, exists(':SimpleTreeSortReverse'))

let g:simpletree_sort = 'name'
let g:simpletree_sort_reverse = 0
call simpletree#SetSort('extension')
call assert_equal('extension', g:simpletree_sort)
call simpletree#ToggleSortReverse()
call assert_equal(1, g:simpletree_sort_reverse)
call simpletree#SetSort('bogus')
call assert_equal('extension', g:simpletree_sort)

if !empty(v:errors)
  call writefile(v:errors, '/tmp/simpletree-vim-sorting-errors')
  cquit
endif
qa!
