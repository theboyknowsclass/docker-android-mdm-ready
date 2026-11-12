# Ready-to-test Android emulator for QR (Device Owner) enrolment tests.
#
# Contents: Android 14 google_apis x86_64 AVD "mdmtest", the test QR scanner app, the provisioning
# helper (Prov) and emu.sh, which boots the emulator with /work/qr.png as the back camera picture.
#
# The image build needs no KVM. Rooting the system image and disabling GoogleSdkSetup has to run
# inside a booted emulator, so it is a one-off "bake" run followed by docker commit (see README.md).
FROM budtmo/docker-android:emulator_14.0

USER root

ENV ANDROID_AVD_HOME=/opt/avd \
    AVD=mdmtest \
    WORK=/work \
    MT=/opt/mdmtest

ARG SYSIMG="system-images;android-34;google_apis;x86_64"
ARG DEVICE=pixel_6
# 1 = update the emulator binary first (newer Android images can need a newer emulator than the base has)
ARG UPDATE_EMULATOR=0

COPY src/ /opt/mdmtest/src/
COPY emu.sh /opt/mdmtest/emu.sh

# Build the scanner APK, the Prov helper dex and Pad, and create the AVD.
RUN set -eux; \
    cd /opt/mdmtest; \
    python3 -c "import urllib.request; urllib.request.urlretrieve('https://repo1.maven.org/maven2/com/google/zxing/core/3.5.3/core-3.5.3.jar', 'zxing-qr.jar')"; \
    echo "8d8064c1636fdaef7189dd9055c7d59950a8940a12f2293956446ec3c109fd82  zxing-qr.jar" | sha256sum -c -; \
    SDKM=$(ls -d /opt/android/cmdline-tools/*/bin | head -1); \
    [ "$UPDATE_EMULATOR" = 1 ] && yes | $SDKM/sdkmanager emulator || true; \
    [ -f /opt/android/platforms/android-34/android.jar ] || yes | $SDKM/sdkmanager "platforms;android-34"; \
    ls -d /opt/android/build-tools/* >/dev/null 2>&1 || yes | $SDKM/sdkmanager "build-tools;34.0.0"; \
    [ -d "/opt/android/$(echo "$SYSIMG" | tr ';' '/')" ] || yes | $SDKM/sdkmanager "$SYSIMG"; \
    AJ=/opt/android/platforms/android-34/android.jar; \
    BT=$(ls -d /opt/android/build-tools/* | sort -V | tail -1); \
    mkdir -p obj dex pobj; \
    javac --release 11 -nowarn -cp $AJ:zxing-qr.jar -d obj src/ScanActivity.java; \
    $BT/d8 --lib $AJ --min-api 30 --output dex $(find obj -name '*.class') zxing-qr.jar; \
    $BT/aapt2 link -o unsigned.apk -I $AJ --manifest src/AndroidManifest.xml; \
    (cd dex && jar uMf ../unsigned.apk classes.dex); \
    $BT/zipalign -f 4 unsigned.apk aligned.apk; \
    keytool -genkeypair -keystore test.jks -storepass android -keypass android -alias test \
        -keyalg RSA -keysize 2048 -validity 10000 -dname CN=mdmtest; \
    $BT/apksigner sign --ks test.jks --ks-pass pass:android --out qrscan.apk aligned.apk; \
    javac --release 11 -nowarn -cp $AJ -d pobj src/Prov.java; \
    $BT/d8 --lib $AJ --min-api 30 --output pobj pobj/Prov.class; \
    mv pobj/classes.dex prov.dex; \
    javac -d . src/Pad.java; \
    rm -rf obj dex pobj unsigned.apk aligned.apk test.jks; \
    chmod 755 emu.sh; \
    mkdir -p $ANDROID_AVD_HOME; \
    echo no | $SDKM/avdmanager create avd -n $AVD -k "$SYSIMG" -d $DEVICE; \
    printf 'hw.camera.back=emulated\nhw.ramSize=4096\ndisk.dataPartition.size=6G\n' >> $ANDROID_AVD_HOME/$AVD.avd/config.ini; \
    ls -la /opt/mdmtest

# Live view (VIEW=1): Xvfb + x11vnc + noVNC. The base image normally has them; install if not.
# iproute2: emu.sh adds an IPv6 address for the emulator's modem.
RUN if ! command -v Xvfb >/dev/null || ! command -v x11vnc >/dev/null || ! command -v ip >/dev/null \
        || [ -z "$(find /usr/share/novnc /opt/noVNC /opt /home -maxdepth 4 -name vnc.html 2>/dev/null | head -1)" ]; then \
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb x11vnc novnc websockify iproute2 \
        && rm -rf /var/lib/apt/lists/*; \
    fi

EXPOSE 6080
WORKDIR /work
ENTRYPOINT ["/opt/mdmtest/emu.sh"]
CMD ["e2e"]
