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
7. The run passes (exit code 0) when the DPC named in the QR is Device Owner.

No Google proprietary APKs are included.

## Use

The host needs KVM (`/dev/kvm`). On Windows, use WSL2 and run `modprobe kvm_intel` (or `kvm_amd`).

```sh
docker pull ghcr.io/theboyknowsclass/docker-android-mdm-ready:latest

mkdir work
cp my-qr.png work/qr.png            # required
cp my-qr.json work/qr.json          # optional: expected decoded text, checked against the scan
cp my-dpc.apk work/agent.apk        # optional: served at http://10.0.2.2:8099/agent.apk

docker run --rm --device /dev/kvm --cap-add NET_ADMIN --sysctl net.ipv6.conf.all.disable_ipv6=0 -v "$PWD/work:/work" ghcr.io/theboyknowsclass/docker-android-mdm-ready:latest e2e
```

- Evidence is written to `work/out/`: `decoded.json`, `logcat.txt`, `screen-N.png`, and `fail.png` on failure.
- [examples/qr.json](examples/qr.json) shows the payload shape.

### Commands

| Command | What it does |
|---|---|
| `e2e` (default) | scan, provision, assert Device Owner |
| `start` | boot with the QR on the camera and keep running; use `docker exec -it <c> adb shell` |
| `ids` | boot, apply the device identity and print what Android reports |
| `bake` | one-off image preparation, used by the build |

### Options (`-e NAME=value`)

| Name | Default | Purpose |
|---|---|---|
| `VIEW` | `0` | `1` = live view in a browser: add `-p 6080:6080`, then open http://localhost:6080/vnc.html?autoconnect=1 |
| `CAM_SIZE` | `800` | QR size on the camera canvas |
| `CAM_CANVAS` | `2000` | camera canvas size |
| `CAM_XOFF` | `-447` | x offset (the emulator's image camera is rotated and off centre) |

### Device identity

Each container start gets a new random identity, so every run enrols as a new device. Set any of these to fix a value:

| Name | Format | Random default |
|---|---|---|
| `DEVICE_SERIAL` | 1-20 letters/digits (`Build.getSerial()`, `ro.serialno`) | `MDMR` + 12 hex |
| `DEVICE_IMEI` | 15 digits | `35` + 12 random + Luhn check digit |
| `DEVICE_SSAID_KEY` | 64 hex | random |
| `DEVICE_PHONE` | SIM phone number, 3-11 digits, optional `+` (the emulator ignores longer ones) | `1555` + 7 digits |
| `DEVICE_IMSI` | 15 digits | `310260` + 9 digits (keeps the emulator's MCC 310 / MNC 260) |
| `DEVICE_ICCID` | 19-20 digits | `8901` + 15 digits + Luhn check digit |
| `DEVICE_WIFI_MAC` | `aa:bb:cc:dd:ee:ff` | `02:` + 5 random bytes (locally administered) |

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

The GitHub Actions workflow does the same thing on every push to `main` and pushes the image to GHCR.

## Licences

- This repo's code: MIT, see [LICENSE](LICENSE).
- The base image [budtmo/docker-android](https://github.com/budtmo/docker-android) keeps its own licence (custom Apache-2.0).
- The image contains the Android SDK emulator and system image, which are under the Android SDK License, and ZXing, which is under Apache-2.0.
