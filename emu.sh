#!/bin/bash
# emu.sh: entrypoint of the docker-android-mdm-ready image.
#
#   bake      one-off, needs KVM: root the system image, disable GoogleSdkSetup (the stub that marks the
#             emulator as already set up), install the scanner app and the Prov helper, reset.
#   bake-sw   one-off, needs KVM, image from Dockerfile.setupwizard: also install the Google Setup Wizard
#             pulled from a phone (/opt/mdmtest/setupwizard).
#   bake-builtin  bake + bake-sw in one go, for Dockerfile.builtin (no test scanner, Setup Wizard only)
#   e2e       reset, scan /work/qr.png with the test scanner app, provision from the decoded text,
#             assert the DPC from the QR is Device Owner. Exit 0 = pass.
#   e2e-sw    reset, 6 taps on the Setup Wizard welcome screen, its own QR reader scans /work/qr.png,
#             assert Device Owner. Exit 0 = pass.
#   start     boot the emulator with /work/qr.png on the camera and keep running (docker exec ... adb shell).
#   ids       boot, apply the device identity below and print what Android reports. Exit 0 = all took.
#
# Device identity (any command that boots): random per container start unless set.
#   DEVICE_SERIAL      serial number (Build.getSerial / ro.serialno), letters and digits
#   DEVICE_IMEI        15 digits; random ones get a valid Luhn check digit
#   DEVICE_SSAID_KEY   64 hex chars: the seed Android derives every app's ANDROID_ID from
#                      (same key + same app = same ANDROID_ID)
#
# VIEW=1 (any command): show the emulator window live in a browser through noVNC on port 6080
#   docker run ... -e VIEW=1 -p 6080:6080 ... then open http://localhost:6080/vnc.html?autoconnect=1
#   Mouse clicks in the browser reach the emulator, so you can tap it yourself.
#
# /work (mount it):
#   qr.png     the QR image to scan (required for e2e / e2e-sw)
#   qr.json    optional: the exact text the QR should decode to; e2e checks the decoded text against it
#   agent.apk  optional: served at http://10.0.2.2:8099/agent.apk for QRs that point there
#   out/       written: decoded.json, logcat.txt, screen-N.png, fail.png
set -uo pipefail

MT=${MT:-/opt/mdmtest}
AVD=${AVD:-mdmtest}
WORK=${WORK:-/work}
OUT=$WORK/out
CAM_SIZE=${CAM_SIZE:-800}
CAM_CANVAS=${CAM_CANVAS:-2000}
CAM_XOFF=${CAM_XOFF:--447}
BUTTONS=${BUTTONS:-Next|Accept|Accept &amp; continue|Continue|Agree|I agree|OK|Done}
SCANNER=dev.mdmready.qrscan
SETUPWIZARD=com.google.android.setupwizard
A="adb -s emulator-5554"
DPC=""
VIEW=${VIEW:-0}
EMU_DIR=${ANDROID_HOME:-/opt/android}/emulator
# IMEIs the emulator's modem simulator is known to report; ids patches whichever is found
IMEI_DEFAULTS="867400022047199 358240051111110"

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

luhn() {
    local n=$1 sum=0 i d
    for ((i = 0; i < ${#n}; i++)); do
        d=${n:${#n}-1-i:1}
        if (( i % 2 == 0 )); then d=$((d * 2)); (( d > 9 )) && d=$((d - 9)); fi
        sum=$((sum + d))
    done
    echo $(( (10 - sum % 10) % 10 ))
}

pick_ids() {
    if [ -z "${DEVICE_SERIAL:-}" ]; then DEVICE_SERIAL=MDMR$(rand_hex 6 | tr a-f A-F); fi
    if [ -z "${DEVICE_IMEI:-}" ]; then
        local body
        body=35$(od -An -tu1 -N12 /dev/urandom | tr -s ' ' '\n' | grep . | awk '{printf "%d", $1 % 10}')
        DEVICE_IMEI=$body$(luhn "$body")
    fi
    if [ -z "${DEVICE_SSAID_KEY:-}" ]; then DEVICE_SSAID_KEY=$(rand_hex 32); fi
    [[ $DEVICE_SERIAL =~ ^[A-Za-z0-9]{1,20}$ ]] || { log "DEVICE_SERIAL must be 1-20 letters/digits"; exit 2; }
    [[ $DEVICE_IMEI =~ ^[0-9]{15}$ ]] || { log "DEVICE_IMEI must be 15 digits"; exit 2; }
    [[ $DEVICE_SSAID_KEY =~ ^[0-9A-Fa-f]{64}$ ]] || { log "DEVICE_SSAID_KEY must be 64 hex chars"; exit 2; }
    DEVICE_SSAID_KEY=$(tr a-f A-F <<<"$DEVICE_SSAID_KEY")
    log "identity: serial=$DEVICE_SERIAL imei=$DEVICE_IMEI ssaid_key=${DEVICE_SSAID_KEY:0:8}..."
}

# The modem simulator has the IMEI built in, so swap it (same length) in the emulator files.
# Originals are kept as *.mdmr-orig, so every start patches from the original.
patch_imei() {
    local f def found=""
    for def in $IMEI_DEFAULTS; do
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            case $f in *.mdmr-orig) continue ;; esac
            [ -f "$f.mdmr-orig" ] || cp -p "$f" "$f.mdmr-orig"
            found="$found $f"
        done < <({ grep -rlaF "$def" "$EMU_DIR"; find "$ANDROID_AVD_HOME" -type f -size -10M -exec grep -laF "$def" {} +; } 2>/dev/null)
    done
    for f in $(find "$EMU_DIR" "$ANDROID_AVD_HOME" -name '*.mdmr-orig' 2>/dev/null); do
        cp -p "$f" "${f%.mdmr-orig}"
        for def in $IMEI_DEFAULTS; do
            DEF=$def NEW=$DEVICE_IMEI perl -pi -e 's/\Q$ENV{DEF}\E/$ENV{NEW}/g' "${f%.mdmr-orig}"
        done
        found="$found ${f%.mdmr-orig}"
    done
    if [ -z "$found" ]; then
        log "WARNING: no built-in IMEI found under $EMU_DIR; DEVICE_IMEI not applied"
    else
        log "IMEI patched in:$(tr ' ' '\n' <<<"$found" | sort -u | tr '\n' ' ')"
    fi
}

# Android derives each app's ANDROID_ID from a per-user key in settings_ssaid.xml. Writing a new key
# (text XML; Android reads text and binary XML) and dropping the per-app entries gives new IDs.
write_ssaid() {
    $A shell "cat > /data/system/users/0/settings_ssaid.xml" <<EOF
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<settings version="-1">
<setting id="0" name="userkey" value="$DEVICE_SSAID_KEY" package="android" defaultValue="$DEVICE_SSAID_KEY" defaultSysSet="false" />
</settings>
EOF
    $A shell 'chown system:system /data/system/users/0/settings_ssaid.xml; chmod 600 /data/system/users/0/settings_ssaid.xml; restorecon /data/system/users/0/settings_ssaid.xml'
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

fail() {
    log "FAIL: $*"
    $A exec-out screencap -p > "$OUT/fail.png" 2>/dev/null
    $A logcat -d > "$OUT/logcat.txt" 2>/dev/null
    stop_emu
    exit 1
}

wait_boot() {
    timeout 180 $A wait-for-device || return 1
    for _ in $(seq 1 90); do
        if [ "$($A shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
            sleep 5
            return 0
        fi
        sleep 2
    done
    return 1
}

root_up() {
    $A root >/dev/null 2>&1
    sleep 3
    timeout 60 $A wait-for-device
}

# Virtual display + VNC + noVNC, for VIEW=1.
start_view() {
    export DISPLAY=:1
    pgrep -f "Xvfb :1" >/dev/null && return 0
    # a committed image keeps the bake's X lock files, which stop a new Xvfb :1 starting
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
    Xvfb :1 -screen 0 1600x1300x24 > /tmp/xvfb.log 2>&1 &
    sleep 2
    x11vnc -display :1 -forever -shared -nopw -rfbport 5901 -quiet > /tmp/x11vnc.log 2>&1 &
    sleep 1
    local web
    web=$(dirname "$(find /usr/share/novnc /opt/noVNC /opt /home -maxdepth 4 -name vnc.html 2>/dev/null | head -1)")
    if command -v websockify >/dev/null; then
        websockify --web "$web" 6080 localhost:5901 > /tmp/novnc.log 2>&1 &
    elif [ -x "$web/utils/novnc_proxy" ]; then
        "$web/utils/novnc_proxy" --vnc localhost:5901 --listen 6080 > /tmp/novnc.log 2>&1 &
    else
        log "no websockify/noVNC found (web=$web); VNC only on port 5901"
    fi
    log "live view: http://localhost:6080/vnc.html?autoconnect=1 (publish it with -p 6080:6080)"
}

start_emu() {
    [ -e /dev/kvm ] || { log "no /dev/kvm: run with --device /dev/kvm"; exit 2; }
    chmod 666 /dev/kvm
    local window=-no-window
    if [ "$VIEW" = 1 ]; then
        start_view
        window=""
    fi
    local cam=emulated
    if [ -f "$WORK/qr.png" ]; then
        java -Djava.awt.headless=true -cp "$MT" Pad "$WORK/qr.png" /tmp/qrpad.png "$CAM_SIZE" "$CAM_CANVAS" "$CAM_CANVAS" "$CAM_XOFF" || exit 2
        cam=imagefile:/tmp/qrpad.png
    fi
    [ -n "${DEVICE_SERIAL:-}" ] || pick_ids
    patch_imei
    adb start-server >/dev/null 2>&1
    log "booting $AVD, back camera $cam"
    # androidboot.* on the kernel command line are read before the emulator's bootconfig, so this wins
    setsid nohup emulator -avd "$AVD" -writable-system $window -no-audio -no-boot-anim \
        -no-snapshot-load -no-snapshot-save -gpu swiftshader_indirect -accel on \
        -camera-back "$cam" -qemu -append "androidboot.serialno=$DEVICE_SERIAL" \
        > /tmp/emulator.log 2>&1 < /dev/null &
    if ! wait_boot; then
        tail -20 /tmp/emulator.log
        log "emulator did not boot"
        exit 3
    fi
    root_up
    log "booted"
}

# A full emulator restart. adb reboot after disable-verity can crash the emulator (seen on CI runners).
restart_emu() {
    stop_emu
    start_emu
}

stop_emu() {
    $A shell sync >/dev/null 2>&1
    $A emu kill >/dev/null 2>&1
    sleep 5
    pkill -f qemu-system >/dev/null 2>&1
    sleep 2
}

serve_agent() {
    if [ -f "$WORK/agent.apk" ] && ! pgrep -f "http.server 8099" >/dev/null; then
        (cd "$WORK" && nohup python3 -m http.server 8099 > /tmp/http.log 2>&1 &)
        sleep 2
        log "serving $WORK/agent.apk at http://10.0.2.2:8099/agent.apk"
    fi
}

# Back to "never set up": settings and device policy state deleted, DPC uninstalled.
reset_device() {
    log "reset to un-set-up"
    $A shell pm clear "$SETUPWIZARD" >/dev/null 2>&1
    # stop the framework first, so system_server cannot write its settings back before the restart
    $A shell stop
    sleep 3
    $A shell 'rm -f /data/system/users/0/settings_global.xml /data/system/users/0/settings_secure.xml /data/system/users/0/settings_system.xml /data/system/users/0/settings_ssaid.xml /data/system/device_policies.xml /data/system/device_policy_state.xml /data/system/device_owner_2.xml'
    write_ssaid
    restart_emu
    if [ -n "$DPC" ]; then
        $A shell pm uninstall "${DPC%%/*}" >/dev/null 2>&1
    fi
    # The Setup Wizard disables its own main activity once it has run (or skipped itself); turn it back on
    # and send the device home so the welcome screen comes up.
    if $A shell pm list packages -s | grep -q "package:$SETUPWIZARD\$"; then
        $A shell pm enable "$SETUPWIZARD/.SetupWizardActivity" >/dev/null 2>&1
        $A shell pm enable "$SETUPWIZARD/.deferred.ComponentStateMitigationReceiver" >/dev/null 2>&1
        # on a Pixel a default-permissions file pre-grants this; without it the QR reader gets no camera
        $A shell pm grant "$SETUPWIZARD" android.permission.CAMERA >/dev/null 2>&1
        $A shell am start -W -n "$SETUPWIZARD/.SetupWizardActivity" >/dev/null 2>&1
        sleep 5
    fi
    local p
    p=$($A shell settings get global device_provisioned | tr -d '\r')
    log "device_provisioned=$p"
    [ "$p" = 0 ] || { log "device still marked provisioned (was bake run?)"; exit 3; }
}

# Reads the DPC component from a QR json file into DPC, in dumpsys form (package/full.class.Name).
read_dpc() {
    DPC=$(python3 - "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["android.app.extra.PROVISIONING_DEVICE_ADMIN_COMPONENT_NAME"]
pkg, cls = c.split("/", 1)
print(pkg + "/" + (pkg + cls if cls.startswith(".") else cls))
PY
)
}

owner_ok() {
    $A shell dumpsys device_policy 2>/dev/null | grep -A1 'Device Owner:' | grep -q "admin=ComponentInfo{$DPC}"
}

# Up to $1 rounds: stop once $DPC is Device Owner, otherwise tap the first button matching $BUTTONS.
tap_through() {
    local rounds=$1 r ui b
    for r in $(seq 1 "$rounds"); do
        owner_ok && return 0
        $A shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
        ui=$($A exec-out cat /sdcard/ui.xml 2>/dev/null)
        log "screen $r: $(grep -oE 'text="[^"]+"' <<<"$ui" | tr '\n' ' ' | cut -c1-200)"
        $A exec-out screencap -p > "$OUT/screen-$r.png" 2>/dev/null
        b=$(grep -oE "text=\"($BUTTONS)\"[^>]*bounds=\"\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]\"" <<<"$ui" | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
        if [ -n "$b" ]; then
            set -- $(grep -oE '[0-9]+' <<<"$b")
            $A shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
            log "tapped $b"
        fi
        sleep 8
    done
    owner_ok
}

report() {
    $A logcat -d > "$OUT/logcat.txt" 2>/dev/null
    grep -E 'ManagedProvisioning' "$OUT/logcat.txt" | grep -iE 'download|checksum|install|success|complete|error|fail' | tail -8 | cut -c1-200
    grep -iE 'GET_PROVISIONING_MODE|onEnabled' "$OUT/logcat.txt" | tail -4 | cut -c1-200
}

check_decoded() {
    [ -f "$WORK/qr.json" ] || return 0
    python3 - "$WORK/qr.json" "$OUT/decoded.json" <<'PY' || fail "decoded QR text differs from qr.json"
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
sys.exit(0 if a == b else 1)
PY
    log "decoded text matches qr.json"
}

cmd_bake() {
    start_emu
    log "disable verity, remount system"
    $A disable-verity
    restart_emu
    $A remount || { log "remount failed"; exit 3; }
    # GoogleSdkSetup has to leave priv-app entirely (a renamed folder inside priv-app is still scanned),
    # and ro.setupwizard.mode=DISABLED makes Google's Setup Wizard skip itself.
    $A shell 'mkdir -p /system_ext/mdmtest-disabled; for d in /system_ext/priv-app/GoogleSdkSetup /system_ext/priv-app/GoogleSdkSetup.disabled; do [ -d $d ] && mv $d /system_ext/mdmtest-disabled/; done; ls /system_ext/priv-app | grep -i setup'
    $A shell 'for f in /system/build.prop /system_ext/etc/build.prop /product/etc/build.prop /vendor/build.prop /odm/etc/build.prop /vendor/odm/etc/build.prop; do if [ -f $f ] && grep -q "^ro.setupwizard.mode=" $f; then sed -i "s/^ro.setupwizard.mode=.*/ro.setupwizard.mode=OPTIONAL/" $f; echo "ro.setupwizard.mode=OPTIONAL in $f"; fi; done'
    # The emulator injects ro.test_harness=1 at boot (qemu-props), and the Setup Wizard finishes itself
    # straight away in a test harness. Read-only props are first-set-wins and build.prop is read first.
    $A shell 'f=/system_ext/etc/build.prop; grep -q "^ro.test_harness=" $f || echo "ro.test_harness=0" >> $f'
    if [ -f "$MT/qrscan.apk" ]; then
        $A install -r -g "$MT/qrscan.apk"
        $A push "$MT/prov.dex" /data/local/tmp/prov.dex
    fi
    reset_device
    stop_emu
    log "bake done: docker commit this container"
}

cmd_bake_sw() {
    local sw=$MT/setupwizard
    ls "$sw"/apk/*.apk >/dev/null 2>&1 || { log "no APKs in $sw/apk"; exit 2; }
    # Only the Setup Wizard's own allowlist entries go in, under a new file name, so no emulator
    # allowlist file is overwritten (a missing privapp allowlist entry stops system_server booting).
    # Allowlist entries per APK package: taken from the phone/factory permission files when they name
    # the package, otherwise generated from every permission the APK asks for (entries for
    # non-privileged permissions are ignored by Android).
    local bt apk pkg
    bt=$(ls -d /opt/android/build-tools/* | sort -V | tail -1)
    rm -rf /tmp/swperm
    mkdir -p /tmp/swperm
    for apk in "$sw"/apk/*.apk; do
        pkg=$("$bt/aapt2" dump packagename "$apk" 2>/dev/null | tr -d '\r')
        [ -n "$pkg" ] || { log "cannot read the package name of $apk"; exit 2; }
        log "$(basename "$apk"): package $pkg"
        "$bt/aapt2" dump permissions "$apk" 2>/dev/null >> "/tmp/swperm/$pkg"
    done
    python3 - "$sw/permissions" /tmp/privapp-permissions-mdmtest-setupwizard.xml /tmp/swperm <<'PY' || exit 2
import glob, os, re, sys
import xml.etree.ElementTree as ET
src, out, reqdir = sys.argv[1:4]
root = ET.Element("permissions")
for pkg in sorted(os.listdir(reqdir)):
    found = 0
    for f in sorted(glob.glob(src + "/*.xml")):
        for e in ET.parse(f).getroot():
            if e.get("package") == pkg:
                root.append(e)
                found += 1
    if found:
        print(pkg + ":", found, "allowlist entries from the permission files")
        continue
    names = sorted(set(re.findall(r"uses-permission(?:-sdk-23)?: name='([^']+)'", open(os.path.join(reqdir, pkg)).read())))
    if not names:
        sys.exit(pkg + ": no allowlist entries and could not read the APK's permissions")
    e = ET.SubElement(root, "privapp-permissions", package=pkg)
    for n in names:
        ET.SubElement(e, "permission", name=n)
    print(pkg + ": allowlist generated from the APK,", len(names), "permissions")
ET.ElementTree(root).write(out, encoding="utf-8", xml_declaration=True)
PY
    start_emu
    $A remount || { log "remount failed (was bake run on this image?)"; exit 3; }
    $A shell 'mkdir -p /system_ext/priv-app/MdmTestSetupWizard'
    $A push "$sw"/apk/*.apk /system_ext/priv-app/MdmTestSetupWizard/
    $A push /tmp/privapp-permissions-mdmtest-setupwizard.xml /system_ext/etc/permissions/
    $A shell 'chmod 755 /system_ext/priv-app/MdmTestSetupWizard; chmod 644 /system_ext/priv-app/MdmTestSetupWizard/* /system_ext/etc/permissions/privapp-permissions-mdmtest-setupwizard.xml; restorecon -R /system_ext/priv-app/MdmTestSetupWizard /system_ext/etc/permissions'
    log "rebooting with the Setup Wizard"
    stop_emu
    if ! start_emu; then
        $A logcat -d | grep -iE 'privapp-permissions|FATAL EXCEPTION|setupwizard' | tail -20
        log "no boot with the Setup Wizard installed"
        exit 3
    fi
    root_up
    $A shell pm list packages -s | grep -q "$SETUPWIZARD" || { log "Setup Wizard not installed as a system app"; exit 3; }
    reset_device
    $A shell dumpsys activity activities | grep -m1 topResumedActivity
    stop_emu
    log "bake-sw done: docker commit this container"
}

# Boot, reset with the chosen identity and print what Android reports.
cmd_ids() {
    mkdir -p "$OUT"
    start_emu
    reset_device
    local serial imei ssaid ok=0
    serial=$($A shell getprop ro.serialno | tr -d '\r')
    # IMEI: ask telephony a few ways (transaction numbers differ between Android versions)
    local t out
    imei=""
    for t in 1 2 3 4 5; do
        out=$($A shell service call iphonesubinfo $t s16 com.android.shell 2>/dev/null | grep -oE "'[^']*'" | tr -d "'.[:space:]")
        if [[ $out =~ ^[0-9]{15}$ ]]; then imei=$out; break; fi
    done
    [ -n "$imei" ] || imei=$($A shell dumpsys phone 2>/dev/null | grep -oE '\b[0-9]{15}\b' | head -1)
    log "IMEI candidates seen by the modem: $($A shell dumpsys phone 2>/dev/null | grep -oiE 'imei[^,]{0,40}' | sort -u | head -3 | tr '\n' ' ')"
    ssaid=$($A shell settings get secure android_id | tr -d '\r')
    log "reported: serial=$serial imei=$imei shell_android_id=$ssaid"
    log "ssaid file: $($A shell head -c 300 /data/system/users/0/settings_ssaid.xml | tr -d '\n' | cut -c1-200)"
    [ "$serial" = "$DEVICE_SERIAL" ] && log "serial OK" || { log "serial NOT applied"; ok=1; }
    [ "$imei" = "$DEVICE_IMEI" ] && log "IMEI OK" || { log "IMEI NOT applied"; ok=1; }
    $A shell grep -q "$DEVICE_SSAID_KEY" /data/system/users/0/settings_ssaid.xml 2>/dev/null \
        && log "SSAID key OK" || { log "SSAID key NOT kept"; ok=1; }
    stop_emu
    return $ok
}

cmd_e2e() {
    [ -f "$WORK/qr.png" ] || { log "need $WORK/qr.png"; exit 2; }
    mkdir -p "$OUT"
    [ -f "$WORK/qr.json" ] && read_dpc "$WORK/qr.json"
    start_emu
    serve_agent
    reset_device
    log "scan with the test scanner app"
    $A shell pm grant $SCANNER android.permission.CAMERA
    $A shell am force-stop $SCANNER
    $A logcat -c
    $A shell am start -n $SCANNER/.ScanActivity >/dev/null
    for _ in $(seq 1 30); do
        sleep 2
        $A logcat -d -s QRSCAN | grep -q RESULT && break
    done
    $A logcat -d -s QRSCAN | grep -q RESULT || fail "scanner did not decode the QR in 60 s"
    $A shell "cat /data/data/$SCANNER/files/qr.txt > /data/local/tmp/qr.json"
    $A exec-out cat /data/local/tmp/qr.json > "$OUT/decoded.json"
    $A shell am force-stop $SCANNER
    log "decoded $(wc -c < "$OUT/decoded.json") bytes"
    check_decoded
    read_dpc "$OUT/decoded.json"
    log "provision, expecting Device Owner $DPC"
    $A logcat -c
    $A shell 'CLASSPATH=/data/local/tmp/prov.dex app_process / Prov /data/local/tmp/qr.json' | grep -q 'result=0' || fail "provisioning intent refused"
    sleep 10
    tap_through 10 || fail "$DPC is not Device Owner"
    report
    log "PASS: $DPC is Device Owner"
    stop_emu
}

cmd_e2e_sw() {
    [ -f "$WORK/qr.png" ] || { log "need $WORK/qr.png"; exit 2; }
    [ -f "$WORK/qr.json" ] || { log "need $WORK/qr.json (to know which DPC to expect)"; exit 2; }
    mkdir -p "$OUT"
    read_dpc "$WORK/qr.json"
    start_emu
    serve_agent
    reset_device
    local top size w h
    for _ in $(seq 1 30); do
        top=$($A shell dumpsys activity activities | grep -m1 topResumedActivity)
        grep -q "$SETUPWIZARD" <<<"$top" && break
        sleep 2
    done
    grep -q "$SETUPWIZARD" <<<"$top" || fail "Setup Wizard welcome screen not shown (top: $top)"
    size=$($A shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
    w=${size%x*}
    h=${size#*x}
    log "6 taps on the welcome screen"
    for _ in 1 2 3 4 5 6; do
        $A shell input tap $(( w / 2 )) $(( h / 4 ))
        sleep 0.3
    done
    sleep 10
    BUTTONS="$BUTTONS|AndroidWifi|Set up|Scan"
    tap_through 15 || fail "$DPC is not Device Owner"
    report
    log "PASS: $DPC is Device Owner (Setup Wizard QR reader)"
    stop_emu
}

case "${1:-e2e}" in
    bake) cmd_bake ;;
    bake-sw) cmd_bake_sw ;;
    bake-builtin) cmd_bake && cmd_bake_sw ;;
    e2e) cmd_e2e ;;
    e2e-sw) cmd_e2e_sw ;;
    ids) cmd_ids ;;
    start)
        start_emu
        serve_agent
        log "running; docker exec -it <container> adb shell"
        tail -f /tmp/emulator.log
        ;;
    *) echo "usage: emu.sh bake|bake-sw|bake-builtin|e2e|e2e-sw|start|ids"; exit 2 ;;
esac
