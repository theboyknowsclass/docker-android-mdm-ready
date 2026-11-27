# docker-android-mdm-ready

An Android 14 emulator in Docker that is ready for QR (Device Owner) enrolment tests.

You give it a provisioning QR image. It scans the QR, provisions the device and checks that your DPC ends up as Device Owner.

Built on [budtmo/docker-android](https://github.com/budtmo/docker-android) (`emulator_14.0`).

## What a run does

1. Boots the emulator with `qr.png` as the back camera picture.
2. Resets the device to "never set up".
3. A small scanner app (Camera1 + ZXing) decodes the QR.
4. A root helper (`Prov`) sends the provisioning intent the Setup Wizard would send, including the admin extras bundle.
5. A script taps through the consent screens.
6. Android's ManagedProvisioning downloads the DPC, checks its checksum and installs it.
7. The run checks that the DPC named in the QR is Device Owner.
8. Once ManagedProvisioning has left the foreground it sends `PROVISION_FINALIZATION` (the Setup Wizard's job), taps through the DPC's own screens (granting "modify system settings" if the DPC asks) until the DPC leaves the foreground, then passes (exit code 0).

No Google proprietary APKs are included.

## Use

The host needs KVM (`/dev/kvm`). On Windows, use WSL2 and run `modprobe kvm_intel` (or `kvm_amd`).

```sh
docker pull ghcr.io/theboyknowsclass/docker-android-mdm-ready:android-14-<sha>

mkdir work
cp my-qr.png work/qr.png            # required
cp my-qr.json work/qr.json          # optional: expected decoded text, checked against the scan
cp my-dpc.apk work/agent.apk        # optional: served at http://10.0.2.2:8099/agent.apk

docker run --rm --device /dev/kvm --cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 -v "$PWD/work:/work" ghcr.io/theboyknowsclass/docker-android-mdm-ready:android-14-<sha> e2e
```

> **Always pass `--cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0`.** The emulator's modem connects over IPv6 localhost (`[::1]`), and Docker gives containers no IPv6 by default. Without the flags there is no modem: no SIM, no IMEI, no phone number, and a DPC reports a different device id. The container now refuses to boot without them (`ALLOW_NO_MODEM=1` overrides this).

- **Readiness:** after boot (and after each reset) the container waits until Android reports the IMEI, then creates `/tmp/device-ready`. A DPC that reads the IMEI too early falls back to another id and can keep it, so wait on it before provisioning: `docker exec <c> test -f /tmp/device-ready`.
- Tags on every build of `main`:

  | Tag | Moves? | Example |
  |---|---|---|
  | `:android-<version>-<sha>` | no, pin this in scripts, compose files and CI | `:android-14-b4ea83f` |
  | `:<sha>` | no | `:b4ea83f` |
  | `:android-<version>` | yes, newest build of that Android version | `:android-14` |
  | `:latest` | yes, newest build | |
- The same tags are on Docker Hub as `docker.io/theboyknowsclass/docker-android-mdm-ready`.

- Evidence is written to `work/out/`: `decoded.json`, `logcat.txt`, `screen-N.png`, and `fail.png` on failure.
- [examples/qr.json](examples/qr.json) shows the payload shape. [examples/qr-dense.png](examples/qr-dense.png) is a dense version 23 QR (109 modules, like real enrolment QRs) that CI scans on every build.

### Commands

| Command | What it does |
|---|---|
| `e2e` (default) | scan, provision, assert Device Owner, finalize provisioning |
| `start` | boot with the QR on the camera, reset to un-set-up, apply the identity, wait for the IMEI (`/tmp/device-ready`) and keep running; use `docker exec -it <c> adb shell` |
| `ids` | boot, apply the device identity and print what Android reports |
| `scan` | boot and decode `qr.png` with the test scanner only (compares with `qr.json`); `work/out/camera-frame.png` is what the camera saw |
| `bake` | one-off image preparation, used by the build |

### Options (`-e NAME=value`)

| Name | Default | Purpose |
|---|---|---|
| `VIEW` | `0` | `1` = live view in a browser: add `-p 6080:6080`, then open http://localhost:6080/vnc.html?autoconnect=1 |
| `CAM_SIZE` | `800` | QR size on the camera canvas |
| `CAM_CANVAS` | `2000` | camera canvas size |
| `CAM_XOFF` | `-447` | x offset (the emulator's image camera is rotated and off centre) |
| `CAM_CANVAS_W` / `CAM_CANVAS_H` | `CAM_CANVAS` | camera canvas width / height separately |
| `FRAME_LOG` | `0` | `1` = also print the camera frame base64-encoded in the log (CI) |
| `FINALIZE` | `1` | `0` = stop at Device Owner (no `PROVISION_FINALIZATION`, no DPC screens) |
| `DPC_ROUNDS` | `20` | most screens `e2e` handles while finalizing (`work/out/final-<n>.png`); the run fails if the DPC is still in front after them |
| `DPC_BUTTONS` | `NEXT`, `CONTINUE`, `Grant Permission`, `Allow`, `CONFIRM & <WORD>`, `ENROL`/`ENROLL`, `FINISH` (and other cases) | extra button labels tapped on the DPC's screens, as an extended regex |
| `KEEP_RUNNING` | `0` | `1` = after `e2e` passes, keep the enrolled device running (`/tmp/device-ready`) instead of stopping |

### Device identity

Each container start gets a new random identity, so every run enrols as a new device. Set any of these to fix a value:

| Name | Format | Random default |
|---|---|---|
| `DEVICE_SERIAL` | 1-16 letters/digits (`Build.getSerial()`, `ro.serialno`), so `S` + serial fits a 17-character device id (`T?[a-zA-Z0-9]{0,17}`) | 14 upper-case letters/digits, Pixel style (e.g. `28041FDH2003K7`) |
| `DEVICE_IMEI` | 15 digits | `35` + 12 random + Luhn check digit |
| `DEVICE_IMEI_TAC` | 8 digits: type allocation code (model id) for random IMEIs | `35` + 6 random digits |
| `DEVICE_SSAID_KEY` | 64 hex | random |
| `DEVICE_PHONE` | SIM phone number, 3-11 digits, optional `+` (the emulator ignores longer ones) | `1555` + 7 digits |
| `DEVICE_IMSI` | 15 digits | `310260` + 9 digits (keeps the emulator's MCC 310 / MNC 260) |
| `DEVICE_ICCID` | 19-20 digits | `8901` + 15 digits + Luhn check digit |
| `DEVICE_WIFI_MAC` | `aa:bb:cc:dd:ee:ff` | `02:` + 5 random bytes (locally administered) |
| `DEVICE_MODEL` | 1-40 letters, digits, spaces or `. _ -` (`Build.MODEL`) | `Pixel 6` (the AVD is a `pixel_6`) |
| `DEVICE_MANUFACTURER` | same format (`Build.MANUFACTURER`; `Build.BRAND` is the lower-case form) | `Google` |
| `DEVICE_BUILD_DISPLAY` | 1-40 letters, digits, spaces or `. _ -` (`Build.DISPLAY`, `ro.build.display.id`). The stock value is 63 characters, too long for schemas that cap it at 40 | `<ro.build.id>`, as on real user builds, e.g. `UE1A.230829.050` |

On Android 8+ `ANDROID_ID` differs per app; Android derives it from `DEVICE_SSAID_KEY`, so the same key and the same app give the same `ANDROID_ID`.

`--cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0` are needed for the SIM values and the IMEI: the emulator's modem connects over IPv6 localhost, which only works when the container has an IPv6 address, and Docker gives it none by default. Without them the device has no SIM.

The container logs the identity it used at start (`identity: ...`). `docker run ... ids` boots, applies it and checks each value against what Android reports.

### Several devices

Run one container per device, each with its own `work` folder (and its own `-p` port if you use `VIEW`). Each container needs about 4 GB of RAM.

### Reaching your servers

`10.0.2.2` inside the emulator is the container itself. To reach other containers, attach the container to their Docker network (`--network <name>`) and use their names in the QR.

## Build it yourself

```sh
docker build -t mdm-emu:base .
docker run --device /dev/kvm --name bake mdm-emu:base bake
docker commit --change 'CMD ["e2e"]' bake mdm-emu:ready
docker rm bake
```

The GitHub Actions workflow does the same thing on every push to `main` and pushes the image to GHCR (and Docker Hub). Pull requests run the same build, bake and identity check but push nothing.

The base image is pinned by digest in the `Dockerfile`, because `emu.sh` patches emulator binaries that change between base image versions. To move to a newer base, update the digest and let the identity check in CI prove it.

## Licences

- This repo's code: MIT, see [LICENSE](LICENSE).
- The base image [budtmo/docker-android](https://github.com/budtmo/docker-android) keeps its own licence (custom Apache-2.0).
- The image contains the Android SDK emulator and system image, which are under the Android SDK License, and ZXing, which is under Apache-2.0.
