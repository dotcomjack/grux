#!/usr/bin/env bash
# Prints the SHA-1 of the first "Apple Development" identity in the
# `security find-identity -v -p codesigning` output on stdin, or nothing.
#
# The hash is read as the 40-character hex token on that line, never as a fixed
# field: the list index is right-aligned, so from the tenth identity on the
# padding shrinks, every field shifts, and a field number reads empty.
# `build.sh` uses this; OSS contributors sign with their own certificate, so any
# team's Apple Development identity is taken.
grep 'Apple Development' | grep -oE '[0-9A-F]{40}' | head -n 1 || true
