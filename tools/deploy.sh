#!/bin/sh
# Sync, compile-check, install, restart, wait for a player.
#
# Exists because I once scp'd a file that failed to compile: the deploy was
# chained after the compile with && in the wrong place, LMS restarted with a
# broken plugin, and the symptom was an empty JSON-RPC response with nothing in
# the log. The compile gate below is not optional.
#
# usage: tools/deploy.sh [host] [plugin-dir]

set -e
cd "$(dirname "$0")/.."

HOST=${1:-ser5}
PLUGIN_DIR=${2:-/home/imyourwreck/Docker/lyrion/config/cache/InstalledPlugins/Plugins}
LMS=${LMS_HOST:-192.168.1.8}
PORT=${LMS_PORT:-9000}

echo "==> syncing matcher from lib/"
./tools/sync-matcher.sh

echo "==> compile check"
for f in Plugins/HitsPlaylist/*.pm; do
    if ! perl -It/stubs -I. -MLMSStubs -c "$f" >/dev/null 2>&1; then
        echo "COMPILE FAILED: $f" >&2
        perl -It/stubs -I. -MLMSStubs -c "$f" 2>&1 | head -5 >&2
        echo "NOT DEPLOYING." >&2
        exit 1
    fi
done
echo "    all modules compile"

echo "==> unit tests"
prove -Ilib -q t/ >/dev/null || { echo "TESTS FAILED. NOT DEPLOYING." >&2; exit 1; }
echo "    tests pass"

echo "==> installing to $HOST:$PLUGIN_DIR"
scp -q -r Plugins/HitsPlaylist "$HOST:$PLUGIN_DIR/"

echo "==> restarting lms"
ssh "$HOST" 'docker restart lms >/dev/null'

# A new plugin only loads on server start, and players take ~30s to come back.
# Until one reconnects $client is undef, the action rows are correctly absent,
# and that looks exactly like a regression. Wait for one before reporting ready.
printf "==> waiting for a connected player"
until curl -s -m 5 -X POST "http://$LMS:$PORT/jsonrpc.js" \
      -d '{"id":1,"method":"slim.request","params":["",["players",0,10]]}' 2>/dev/null \
      | grep -q '"connected":1'; do
    printf "."
    sleep 4
done
echo " ready"

echo "==> plugin log"
ssh "$HOST" 'grep -i hitsplaylist /home/imyourwreck/Docker/lyrion/config/logs/server.log | tail -3' || true
