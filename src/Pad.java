import javax.imageio.ImageIO;
import java.awt.Color;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.io.File;

// Places the QR on a white canvas so the emulator's imagefile back camera shows all of it.
// The imagefile camera shows the picture rotated 90 degrees and off centre; the x offset makes up for that
// (measured on the spike emulator: QR 800 on a 2000x2000 canvas, shifted -447 in x).
// Usage: java -Djava.awt.headless=true Pad in.png out.png size canvasW canvasH xOffset
public class Pad {
    public static void main(String[] a) throws Exception {
        BufferedImage q = ImageIO.read(new File(a[0]));
        int s = Integer.parseInt(a[2]);
        int w = Integer.parseInt(a[3]);
        int h = Integer.parseInt(a[4]);
        int dx = a.length > 5 ? Integer.parseInt(a[5]) : 0;
        BufferedImage c = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
        Graphics2D g = c.createGraphics();
        g.setColor(Color.WHITE);
        g.fillRect(0, 0, w, h);
        g.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_NEAREST_NEIGHBOR);
        g.drawImage(q, (w - s) / 2 + dx, (h - s) / 2, s, s, null);
        ImageIO.write(c, "png", new File(a[1]));
        System.out.println("camera image " + q.getWidth() + "x" + q.getHeight() + " -> " + w + "x" + h + " dx=" + dx);
    }
}
