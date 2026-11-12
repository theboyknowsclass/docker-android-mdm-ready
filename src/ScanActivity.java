package dev.mdmready.qrscan;

import android.app.Activity;
import android.graphics.SurfaceTexture;
import android.hardware.Camera;
import android.os.Bundle;
import android.util.Base64;
import android.util.Log;
import android.view.TextureView;
import android.widget.FrameLayout;
import android.widget.TextView;

import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
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
    }

    @Override
    public void onSurfaceTextureAvailable(SurfaceTexture texture, int w, int h) {
        try {
            camera = Camera.open(0);
            Camera.Parameters p = camera.getParameters();
            Camera.Size best = p.getPreviewSize();
            for (Camera.Size s : p.getSupportedPreviewSizes()) {
                if (s.width <= 1280 && (long) s.width * s.height > (long) best.width * best.height) {
                    best = s;
                }
            }
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
        try {
            PlanarYUVLuminanceSource src = new PlanarYUVLuminanceSource(data, width, height, 0, 0, width, height, false);
            Result r = reader.decode(new BinaryBitmap(new HybridBinarizer(src)), hints);
            done = true;
            String text = r.getText();
            byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
            try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), "qr.txt"))) {
                out.write(bytes);
            }
            Log.i(TAG, "RESULT:" + Base64.encodeToString(bytes, Base64.NO_WRAP));
            status.setText("QR after " + frames + " frames:\n" + text);
        } catch (Exception e) {
            if (frames % 30 == 0) {
                Log.i(TAG, "no QR yet, frames=" + frames);
            }
        } finally {
            reader.reset();
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
