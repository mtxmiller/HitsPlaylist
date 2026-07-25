#!/bin/sh
# Sync, compile-check, test, install, restart, wait for a player.
#
# Exists because I once scp'd a file that failed to compile: the deploy was
# chained after the compile with && in the wrong place, LMS restarted with a
# broken plugin, and the symptom was an empty JSON-RPC response with nothing in
# the log. The compile and test gates below are not optional.
#
# Configure with environment variables:
#   HOST           ssh target running LMS            (default: lms-server)
#   PLUGIN_DIR     InstalledPlugins/Plugins path on that host
#   LMS_HOST       hostname/IP for JSON-RPC          (default: $HOST)
#   LMS_PORT       JSON-RPC port                     (default: 9000)
#   LMS_CONTAINER  docker container name, if LMS runs in Docker
#   LMS_LOG        server.log path on that host
#
# Example:
#   HOST=nas LMS_CONTAINER=lms LMS_HOST=192.168.1.50 \
#   PLUGIN_DIR=/volume1/docker/lyrion/config/cache/InstalledPlugins/Plugins \
#   tools/deploy.sh

set -e
cd "$(dirname "$0")/.."

HOST=${HOST:-lms-server}
PLUGIN_DIR=${PLUGIN_DIR:-/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins}
LMS_HOST=${LMS_HOST:-$HOST}
LMS_PORT=${LMS_PORT:-9000}
LMS_CONTAINER=${LMS_CONTAINER:-}
LMS_LOG=${LMS_LOG:-/var/log/squeezeboxserver/server.log}

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

echo "==> restarting LMS"
if [ -n "$LMS_CONTAINER" ]; then
    ssh "$HOST" "docker restart $LMS_CONTAINER >/dev/null"
else
    ssh "$HOST" "sudo systemctl restart lyrionmusicserver 2>/dev/null || sudo systemctl restart logitechmediaserver"
fi

# A new plugin only loads on server start, and players take ~30s to reconnect.
# Until one does, $client is undef, the action rows are correctly absent, and
# that looks exactly like a regression. Wait before reporting ready.
printf "==> waiting for a connected player"
until curl -s -m 5 -X POST "http://$LMS_HOST:$LMS_PORT/jsonrpc.js" \
      -d '{"id":1,"method":"slim.request","params":["",["players",0,10]]}' 2>/dev/null \
      | grep -q '"connected":1'; do
    printf "."
    sleep 4
done
echo " ready"

# Only lines from the current run. Tailing the whole log surfaces errors from
# previous boots and makes a healthy deploy look broken; that cost me a false
# alarm once already.
echo "==> plugin log (recent)"
ssh "$HOST" "tail -200 '$LMS_LOG' 2>/dev/null | grep -i hitsplaylist | tail -5" || true
echo "    (no output above means a clean load)"
