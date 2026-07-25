#!/bin/sh
# Copy the matcher into the plugin tree, rewriting only the package line.
#
# lib/HitsPlaylist/Matcher.pm is the single source of truth and the thing t/
# tests. The plugin needs the same code under Plugins::HitsPlaylist::Matcher.
# Keeping one file and generating the other means the tested code and the
# shipped code cannot drift apart, which they would within a week otherwise.
#
# Run after any matcher change, before installing the plugin.

set -e
cd "$(dirname "$0")/.."

SRC=lib/HitsPlaylist/Matcher.pm
DST=Plugins/HitsPlaylist/Matcher.pm

sed \
  -e 's/^package HitsPlaylist::Matcher;/package Plugins::HitsPlaylist::Matcher;/' \
  -e '1a\
\
# GENERATED FILE - do not edit.\
# Source of truth: lib/HitsPlaylist/Matcher.pm  (tested by t/matcher.t)\
# Regenerate:      tools/sync-matcher.sh
' \
  "$SRC" > "$DST"

echo "synced $SRC -> $DST"
grep -q '^package Plugins::HitsPlaylist::Matcher;' "$DST" || {
    echo "ERROR: package rename failed" >&2
    exit 1
}
