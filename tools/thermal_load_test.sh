#!/bin/bash
# 1-hour multi-protocol thermal/stall load test.
#   - drives:   USB 10 Hz binary + WS 10 Hz stream + HTTP/WS churn + mDNS
#   - NOT driven here: BT (the user's app drives it concurrently)
#   - monitors: the WS status-frame telemetry (soc_temp_c/max, weight_stalled,
#               stall_count, last_stall_ms/temp) every ~60 s, watching for the
#               "weight stops being collected" failure and the temp at which it hits.
# Opening USB reboots the scale once (clean baseline); reconnect BT afterward.
set -u
cd "$(dirname "$0")/.."
IP=192.168.10.242
HOST=hds.local
DUR="${1:-3600}"
PORT="$(ls /dev/cu.*usbserial* 2>/dev/null | head -1)"
LOG=/tmp/thermal; rm -rf "$LOG"; mkdir -p "$LOG"
ts(){ date +%H:%M:%S; }
echo "[thermal] START $(ts) dur=${DUR}s port=$PORT"

# 1) USB 10 Hz (opening the port pulses DTR/RTS -> one reboot -> clean baseline)
python3 -u tools/usb_rate_check.py "$PORT" --seconds "$DUR" --mult 1 --boot-wait 8 > "$LOG/usb.log" 2>&1 &
echo "[thermal] USB launched (scale rebooting) @ $(ts)"

# 2) detect the reboot, then wait for full recovery
down=0
for i in $(seq 1 30); do
  if ! ping -c1 -t1 "$HOST" >/dev/null 2>&1; then down=1; echo "[thermal] reboot detected @ $(ts)"; break; fi
  sleep 1
done
until ping -c1 -t1 "$HOST" >/dev/null 2>&1; do sleep 1; done
sleep 4
echo "[thermal] WiFi back @ $(ts) (reboot_detected=$down) -- RECONNECT BT APP NOW"

RDUR=$((DUR-60)); [ "$RDUR" -lt 120 ] && RDUR=120

# 3) WiFi load
python3 -u tools/ws_drop_repro.py "$IP" --rate 10 --duration "$RDUR" --print-every 120 > "$LOG/ws.log" 2>&1 &
python3 -u tools/conn_churn.py "$IP" --http --ws --rate 0.5 --workers 1 --duration "$RDUR" > "$LOG/churn.log" 2>&1 &
python3 -u tools/mdns_stress.py --host "$HOST" --rate 1 --duration "$RDUR" --resolver > "$LOG/mdns.log" 2>&1 &

# 4) telemetry monitor: one WS client, events on, log status every ~60 s
python3 -u - "$HOST" "$RDUR" > "$LOG/telemetry.log" 2>&1 <<'PY' &
import json,sys,time,websocket
host=sys.argv[1]; dur=int(sys.argv[2]); end=time.time()+dur
def connect():
    w=websocket.create_connection("ws://%s/snapshot"%host,timeout=8); w.settimeout(1.0)
    try: w.send('{"command":"events","action":"on"}')
    except Exception: pass
    return w
ws=connect(); prev_stalls=0
while time.time()<end:
    st=None; t=time.time()+2.5
    while time.time()<t:
        try:
            d=json.loads(ws.recv())
            if d.get("type")=="status": st=d
        except Exception: pass
    if st:
        sc=st.get('stall_count',0)
        flag=" *** NEW STALL ***" if (sc or 0)>prev_stalls else ""
        prev_stalls=sc or 0
        print("[%s] soc=%5.1fC max=%5.1fC stalled=%-5s stalls=%s last_stall_ms=%s stall_temp=%s grams=%s chg=%s%s"%(
            time.strftime('%H:%M:%S'), st.get('soc_temp_c',-1), st.get('soc_temp_max_c',-1),
            st.get('weight_stalled'), sc, st.get('last_stall_ms'), st.get('last_stall_temp_c'),
            st.get('grams'), st.get('charging'), flag), flush=True)
    else:
        print("[%s] NO STATUS FRAME (reconnecting)"%time.strftime('%H:%M:%S'), flush=True)
        try: ws.close()
        except Exception: pass
        try: ws=connect()
        except Exception as e: print("reconnect failed:",e,flush=True); time.sleep(5)
    time.sleep(58)
try: ws.close()
except Exception: pass
PY

echo "[thermal] load + telemetry running ${RDUR}s @ $(ts)"
wait
echo "[thermal] DONE $(ts)"
echo "===== TELEMETRY (temp / stall) ====="; cat "$LOG/telemetry.log"
echo "===== peak temp / any stalls ====="; grep -E "STALL|max=" "$LOG/telemetry.log" | tail -3
echo "===== WS (drops) ====="; tail -12 "$LOG/ws.log"
echo "===== USB ====="; tail -6 "$LOG/usb.log"
echo "===== churn ====="; tail -3 "$LOG/churn.log"
echo "===== mDNS ====="; tail -3 "$LOG/mdns.log"
