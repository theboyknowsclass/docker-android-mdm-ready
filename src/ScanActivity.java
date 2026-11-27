package dev.mdmready.qrscan;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.SurfaceTexture;
import android.hardware.Camera;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.view.TextureView;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.google.zxing.Binarizer;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.InvertedLuminanceSource;
import com.google.zxing.LuminanceSource;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.GlobalHistogramBinarizer;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.EnumMap;
import java.util.Map;

/**
 * Test-only QR scanner: reads frames from the back camera (the emulator's
 * virtual scene) and decodes the first QR code it sees with ZXing.
 * The decoded text goes to files/qr.txt and to logcat as QRSCAN RESULT:<base64>.
 */
public class ScanActivity extends Activity implements TextureView.SurfaceTextureListener, Camera.PreviewCallback {
    private static final String TAG = "QRSCAN";
    private static final double[] SCALES = {1.0, 0.75, 0.6, 0.9};
    private Camera camera;
    private TextView status;
    private final QRCodeReader reader = new QRCodeReader();
    private final Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
    private int width;
    private int height;
    private int frames;
    private boolean done;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
        hints.put(DecodeHintType.CHARACTER_SET, "UTF-8");
        FrameLayout root = new FrameLayout(this);
        TextureView preview = new TextureView(this);
        preview.setSurfaceTextureListener(this);
        status = new TextView(this);
        status.setText("Scanning...");
        status.setTextColor(0xFFFFFF00);
        status.setBackgroundColor(0x80000000);
        root.addView(preview);
        root.addView(status);
        setContentView(root);
        new File(getFilesDir(), "qr.txt").delete();
        new File(getFilesDir(), "frame.png").delete();
    }

    @Override
    public void onSurfaceTextureAvailable(SurfaceTexture texture, int w, int h) {
        try {
            camera = Camera.open(0);
            Camera.Parameters p = camera.getParameters();
            // The largest preview: a dense QR (version 20+, 100+ modules) needs every pixel it can get.
            Camera.Size best = p.getPreviewSize();
            StringBuilder sizes = new StringBuilder();
            for (Camera.Size s : p.getSupportedPreviewSizes()) {
                sizes.append(' ').append(s.width).append('x').append(s.height);
                if ((long) s.width * s.height > (long) best.width * best.height) {
                    best = s;
                }
            }
            Log.i(TAG, "preview sizes:" + sizes);
            p.setPreviewSize(best.width, best.height);
            camera.setParameters(p);
            width = best.width;
            height = best.height;
            Log.i(TAG, "camera open, preview " + width + "x" + height);
            camera.setPreviewTexture(texture);
            camera.setPreviewCallback(this);
            camera.startPreview();
        } catch (Exception e) {
            Log.e(TAG, "camera failed", e);
            status.setText("Camera failed: " + e);
        }
    }

    @Override
    public void onPreviewFrame(byte[] data, Camera cam) {
        if (done) {
            return;
        }
        frames++;
        if (frames == 15 || frames % 150 == 0) {
            saveFrame(data);
        }
        try {
            // On dense QRs (version 20+) ZXing can misjudge the module size in the emulator's camera
            // picture and throw FormatException; a rescaled frame usually decodes. Tested on the laptop.
            Result r = null;
            for (double scale : SCALES) {
                LuminanceSource src = scaled(data, scale);
                r = decode(new HybridBinarizer(src));
                if (r == null && scale == 1.0) {
                    r = decode(new GlobalHistogramBinarizer(src));
                }
                if (r == null && scale == 1.0) {
                    // grey-on-black pictures: try the negative too
                    r = decode(new HybridBinarizer(new InvertedLuminanceSource(src)));
                }
                if (r != null) {
                    Log.i(TAG, "decoded at scale " + scale);
                    break;
                }
            }
            if (r == null) {
                if (frames % 30 == 0) {
                    Log.i(TAG, "no QR yet, frames=" + frames + " " + stats(data));
                }
                return;
            }
            done = true;
            saveFrame(data);
            String text = r.getText();
            byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
            try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), "qr.txt"))) {
                out.write(bytes);
            }
            Log.i(TAG, "RESULT:" + Base64.encodeToString(bytes, Base64.NO_WRAP));
            status.setText("QR after " + frames + " frames:\n" + text);
        } catch (Exception e) {
            Log.e(TAG, "frame " + frames + " failed", e);
        }
    }

    // The frame's luminance, scaled by `scale` (box average when shrinking).
    private LuminanceSource scaled(byte[] y, double scale) {
        if (scale == 1.0) {
            return new PlanarYUVLuminanceSource(y, width, height, 0, 0, width, height, false);
        }
        int w = (int) (width * scale), h = (int) (height * scale);
        int[] px = new int[w * h];
        for (int j = 0; j < h; j++) {
            int y0 = (int) (j / scale), y1 = Math.max(y0 + 1, Math.min(height, (int) ((j + 1) / scale)));
            for (int i = 0; i < w; i++) {
                int x0 = (int) (i / scale), x1 = Math.max(x0 + 1, Math.min(width, (int) ((i + 1) / scale)));
                int sum = 0, n = 0;
                for (int yy = y0; yy < y1; yy++) {
                    for (int xx = x0; xx < x1; xx++) {
                        sum += y[yy * width + xx] & 0xff;
                        n++;
                    }
                }
                int v = sum / n;
                px[j * w + i] = 0xff000000 | (v << 16) | (v << 8) | v;
            }
        }
        return new RGBLuminanceSource(w, h, px);
    }

    private Result decode(Binarizer b) {
        try {
            return reader.decode(new BinaryBitmap(b), hints);
        } catch (Exception e) {
            return null;
        } finally {
            reader.reset();
        }
    }

    // Luminance range of the frame: a washed-out camera picture shows up as a narrow range.
    private String stats(byte[] y) {
        int min = 255, max = 0;
        long sum = 0;
        int n = width * height;
        for (int i = 0; i < n; i += 7) {
            int v = y[i] & 0xff;
            min = Math.min(min, v);
            max = Math.max(max, v);
            sum += v;
        }
        return "luma min=" + min + " max=" + max + " mean=" + (sum * 7 / n);
    }

    // What the camera delivers, as a grey PNG in files/frame.png (pulled by emu.sh for debugging).
    private void saveFrame(byte[] y) {
        try {
            int[] px = new int[width * height];
            for (int i = 0; i < px.length; i++) {
                int v = y[i] & 0xff;
                px[i] = 0xff000000 | (v << 16) | (v << 8) | v;
            }
            Bitmap bm = Bitmap.createBitmap(px, width, height, Bitmap.Config.ARGB_8888);
            try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), "frame.png"))) {
                bm.compress(Bitmap.CompressFormat.PNG, 100, out);
            }
            bm.recycle();
            Log.i(TAG, "frame " + frames + " saved, " + stats(y));
        } catch (Exception e) {
            Log.e(TAG, "frame save failed", e);
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (camera != null) {
            camera.setPreviewCallback(null);
            camera.stopPreview();
            camera.release();
            camera = null;
        }
    }

    @Override
    public void onSurfaceTextureSizeChanged(SurfaceTexture t, int w, int h) {
    }

    @Override
    public boolean onSurfaceTextureDestroyed(SurfaceTexture t) {
        return true;
    }

    @Override
    public void onSurfaceTextureUpdated(SurfaceTexture t) {
    }
}
