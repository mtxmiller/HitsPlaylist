#!/bin/sh
# Drill into Hits Radio for an artist, resolving item_id dynamically.
# item_id in artistinfo is POSITIONAL and shifts when other providers appear or
# disappear (attaching a player alone inserts three rows). Hardcoding it makes a
# working plugin look broken.
#
# usage: tools/drill.sh <artist_id> [player_mac]
HOST=${LMS_HOST:-localhost}; PORT=${LMS_PORT:-9000}
ART=$1; PLAYER=${2:-}
rpc() { curl -s -m 90 -X POST "http://$HOST:$PORT/jsonrpc.js" -d "$1"; }

ITEM=$(rpc "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER\",[\"artistinfo\",\"items\",\"0\",\"50\",\"artist_id:$ART\",\"menu:1\"]]}" \
 | python3 -c "
import sys,json
for i in json.load(sys.stdin)['result'].get('item_loop',[]):
    if 'Hits Radio' in str(i.get('text')):
        print((i.get('actions',{}).get('go',{}).get('params',{}) or {}).get('item_id')); break
")
[ -z "$ITEM" ] && { echo "Hits Radio not in the artist menu (plugin not loaded?)"; exit 1; }
echo "item_id=$ITEM player='${PLAYER:-none}'"
rpc "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$PLAYER\",[\"artistinfo\",\"items\",\"0\",\"60\",\"artist_id:$ART\",\"menu:artistinfo\",\"item_id:$ITEM\"]]}" \
 | python3 -c "
import sys,json
raw=sys.stdin.read()
if not raw.strip(): print('EMPTY RESPONSE'); raise SystemExit(1)
r=json.loads(raw).get('result',{})
print('count:', r.get('count'))
for i in r.get('item_loop',[]): print('  ', str(i.get('text'))[:72])
"
