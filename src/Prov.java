import android.content.ComponentName;
import android.content.Intent;
import android.os.PersistableBundle;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Iterator;
import org.json.JSONObject;

// Fires the same intent the setup wizard sends after scanning a provisioning QR.
// Run as root: CLASSPATH=/data/local/tmp/prov.dex app_process / Prov /data/local/tmp/qr.json
public class Prov {
    public static void main(String[] args) throws Exception {
        JSONObject json = new JSONObject(new String(Files.readAllBytes(Paths.get(args[0])), "UTF-8"));
        Intent intent = new Intent("android.app.action.PROVISION_MANAGED_DEVICE_FROM_TRUSTED_SOURCE");
        Iterator<String> keys = json.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            Object value = json.get(key);
            if (value instanceof JSONObject) {
                JSONObject inner = (JSONObject) value;
                PersistableBundle bundle = new PersistableBundle();
                Iterator<String> innerKeys = inner.keys();
                while (innerKeys.hasNext()) {
                    String k = innerKeys.next();
                    bundle.putString(k, String.valueOf(inner.get(k)));
                }
                intent.putExtra(key, bundle);
            } else if (value instanceof Boolean) {
                intent.putExtra(key, (Boolean) value);
            } else if (key.endsWith("COMPONENT_NAME")) {
                intent.putExtra(key, ComponentName.unflattenFromString(String.valueOf(value)));
            } else {
                intent.putExtra(key, String.valueOf(value));
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        Object am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null);
        for (Method m : am.getClass().getMethods()) {
            if (!m.getName().equals("startActivityAsUser")) {
                continue;
            }
            Class<?>[] types = m.getParameterTypes();
            Object[] values = new Object[types.length];
            boolean packageSet = false;
            for (int i = 0; i < types.length; i++) {
                if (types[i] == Intent.class) {
                    values[i] = intent;
                } else if (types[i] == String.class && !packageSet) {
                    values[i] = "com.android.shell";
                    packageSet = true;
                } else if (types[i] == int.class) {
                    values[i] = 0;
                } else if (types[i] == boolean.class) {
                    values[i] = false;
                }
            }
            Object result = m.invoke(am, values);
            System.out.println("startActivityAsUser(" + types.length + " args) result=" + result + " extras=" + intent.getExtras().keySet());
            return;
        }
        System.out.println("startActivityAsUser not found");
    }
}
