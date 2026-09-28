vim9script

# Sourcing plugin/simpletree.vim a second time must leave it working.
#
# A plugin manager sources plugin/ again when the vimrc is reloaded.  The script
# is guarded, so nothing is redefined -- but plain `vim9script` deletes every
# script-local function and variable before the guard reaches `finish`, and the
# commands, autocommands and g: functions defined the first time round go on
# referring to them.  Here that was E933 from
# SimpleTreeMaybeAutoRefresh() on every CursorHold, with a hit-enter prompt each
# time.
#
# Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_reload.vim

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
const SCRIPT = ROOT .. '/plugin/simpletree.vim'
const ERRORS = '/tmp/simpletree-vim-reload-errors'
execute 'set runtimepath^=' .. fnameescape(ROOT)
delete(ERRORS)

# What the script owns, as Vim sees it.
def ScriptItems(): dict<list<string>>
  for info in getscriptinfo()
    if resolve(fnamemodify(info.name, ':p')) ==# SCRIPT
      var detail = getscriptinfo({sid: info.sid})[0]
      return {
        functions: sort(copy(detail.functions)),
        variables: sort(keys(detail.variables)),
      }
    endif
  endfor
  return {functions: [], variables: []}
enddef

# Never touch the user's real state files.
g:simpletree_width_state_file = tempname()
g:simpletree_state_file = tempname() .. '/state.json'
g:simpletree_set_default_mapping = 0
execute 'source ' .. fnameescape(SCRIPT)
var before = ScriptItems()
assert_true(!empty(before.functions),
  'the script defines no script-local function: this test checks nothing')

execute 'source ' .. fnameescape(SCRIPT)
assert_equal(before, ScriptItems(),
  'sourcing the script again deleted script-local items')

# The idle hook is what CursorHold runs; with no tree window open it has
# nothing to refresh, and must get that far.
v:errmsg = ''
try
  doautocmd <nomodeline> SimpleTreeAutoRefresh CursorHold
  g:SimpleTreeMaybeAutoRefresh('idle')
  g:SimpleTreeCaptureWidth()
catch
  assert_report('the idle refresh hook threw after a reload: ' .. v:exception)
endtry
assert_equal('', v:errmsg, 'the idle refresh hook reported an error after a reload')

if !empty(v:errors)
  writefile(v:errors, ERRORS)
  cquit
endif
qa!
