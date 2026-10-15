// The editing behind KeyField.qml: a line of text, a caret, and whether it
// is all selected, changed one key at a time. Qt-free, so it runs under
// plain node.
//
// A state is { text, cursor, all }. Every function returns a new one.

var maximumLength = 1024

// Typed or pasted text as one line: control characters dropped, line
// breaks and tabs as spaces.
function clean(value) {
  var out = ""
  var text = String(value === undefined || value === null ? "" : value)
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code === 9 || code === 10 || code === 13) out += " "
    else if (code >= 32 && code !== 127) out += text.charAt(i)
  }
  return out
}

function state(text, cursor, all) {
  var t = String(text === undefined || text === null ? "" : text)
  var c = cursor === undefined ? t.length : Math.max(0, Math.min(t.length, cursor))
  return { text: t, cursor: c, all: all === true && t.length > 0 }
}

// Typing or pasting: replaces everything while it is all selected.
// `allowed` is a RegExp a character must match, or null for any.
function insert(s, value, allowed, limit) {
  var add = clean(value)
  if (allowed) {
    var kept = ""
    for (var i = 0; i < add.length; i++) if (allowed.test(add.charAt(i))) kept += add.charAt(i)
    add = kept
  }
  var before = s.all ? "" : s.text.substr(0, s.cursor)
  var after = s.all ? "" : s.text.substr(s.cursor)
  var room = Math.max(0, (limit || maximumLength) - before.length - after.length)
  add = add.substr(0, room)
  return state(before + add + after, before.length + add.length, false)
}

function backspace(s) {
  if (s.all) return state("", 0, false)
  if (s.cursor === 0) return state(s.text, 0, false)
  return state(s.text.substr(0, s.cursor - 1) + s.text.substr(s.cursor), s.cursor - 1, false)
}

function del(s) {
  if (s.all) return state("", 0, false)
  return state(s.text.substr(0, s.cursor) + s.text.substr(s.cursor + 1), s.cursor, false)
}

// Where the word before the caret starts: back over spaces, then over the
// word.
function wordStart(text, cursor) {
  var i = cursor
  while (i > 0 && text.charAt(i - 1) === " ") i--
  while (i > 0 && text.charAt(i - 1) !== " ") i--
  return i
}

function wordEnd(text, cursor) {
  var i = cursor
  while (i < text.length && text.charAt(i) === " ") i++
  while (i < text.length && text.charAt(i) !== " ") i++
  return i
}

function deleteWord(s) {
  if (s.all) return state("", 0, false)
  var start = wordStart(s.text, s.cursor)
  return state(s.text.substr(0, start) + s.text.substr(s.cursor), start, false)
}

// Arrows leave a selection at its edge, as a text field does.
function left(s, word) {
  if (s.all) return state(s.text, 0, false)
  return state(s.text, word ? wordStart(s.text, s.cursor) : s.cursor - 1, false)
}

function right(s, word) {
  if (s.all) return state(s.text, s.text.length, false)
  return state(s.text, word ? wordEnd(s.text, s.cursor) : s.cursor + 1, false)
}

function home(s) { return state(s.text, 0, false) }
function end(s) { return state(s.text, s.text.length, false) }
function selectAll(s) { return state(s.text, s.text.length, true) }
function clear() { return state("", 0, false) }

if (typeof module !== "undefined") {
  module.exports = {
    maximumLength: maximumLength,
    clean: clean,
    state: state,
    insert: insert,
    backspace: backspace,
    del: del,
    deleteWord: deleteWord,
    left: left,
    right: right,
    home: home,
    end: end,
    selectAll: selectAll,
    clear: clear
  }
}
