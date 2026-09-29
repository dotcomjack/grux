#!/bin/zsh
# Fire every locked tab key through the live app and assert the tab that
# RENDERED, not the ack (Phase C gate, G-C item 5).
#
#   Grux-Mac/tools/grux-tab-keys-check.sh [key ...]
#
# With no arguments it checks every locked key in SidebarIA.groups (read from
# the source, so the list follows it: 34 since Terminal Focus was removed), then
# `panel` last, 35 checks in all: the Command Panel closes its pane and reports
# `panel` as what rendered. Each key: delete ~/.grux/rendered-tab.txt, write the key to
# ~/.grux/fire-open-tab, and wait up to 5 s for rendered-tab.txt to name that
# key. The app writes that file from a task keyed on the selection, after the
# pane has updated; the ack file is written when the tab is requested, which is
# before the repaint.
#
# Assumes the Command Panel shell (`legacyShell` false in config). Under the
# classic sidebar there is no closed panel, so the `panel` key renders chat
# and its line fails.
set -u
G=~/.grux
here=${0:A:h}
if (( $# )); then keys=("$@"); else
  keys=(${(f)"$(grep -o 'SidebarItem(key: "[a-zA-Z]*"' "$here/../Sources/Grux/DesignSystem/SidebarModel.swift" | sed 's/.*"\(.*\)"/\1/')"})
  keys+=(panel)
fi
pass=0; fail=0; failed=()
# Start from a tab that is not the first key, so the first selection changes.
print -n "chat" > $G/fire-open-tab; sleep 1.2
for k in $keys; do
  rm -f $G/rendered-tab.txt
  print -n "$k" > $G/fire-open-tab
  got=""
  for i in {1..50}; do
    sleep 0.1
    [[ -f $G/rendered-tab.txt ]] && got=$(<$G/rendered-tab.txt) && [[ "$got" == "$k" ]] && break
  done
  if [[ "$got" == "$k" ]]; then (( pass++ )); print "ok    $k"; else (( fail++ )); failed+=("$k:$got"); print "FAIL  $k (rendered: ${got:-nothing})"; fi
done
print -n "panel" > $G/fire-open-tab
print "\n${#keys} keys: $pass rendered as asked, $fail did not${failed:+ (${failed[*]})}"
(( fail == 0 ))
