using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

// Locate which part of a photo changed between two frames.
//
// Used to map the V7's LED commands automatically: photograph the panel with
// all lamps off, send one LED command, photograph again, and the brightest
// changed cluster is the lamp that command drives. Beats a human tapping the
// spacebar - no reaction-time error, and it catches dim or simultaneous
// changes a person would miss.
//
// LockBits rather than GetPixel: a 1280x720 frame is ~921k pixels and GetPixel
// would take minutes per comparison.
public static class ImageDiff
{
    /*
     * Compare two images and describe the region that got BRIGHTER.
     *
     * Only increases count: an LED turning on adds light. Ignoring decreases
     * makes the result robust against the webcam's auto-exposure pulling the
     * whole frame down a notch when a lamp lights.
     *
     * Returns "count,cx,cy,minX,minY,maxX,maxY,peak" or "0,0,0,0,0,0,0,0".
     */
    /*
     * Find the densest CLUSTER of brightening, not the global centroid.
     *
     * Webcam sensor noise scatters thousands of slightly-brighter pixels across
     * the whole frame, so a global count and centroid is meaningless - measured
     * noise floor was ~1900 stray pixels between two identical static frames,
     * spanning the entire image. An LED is the opposite: a few dozen pixels in
     * one tight spot. Bucketing into cells and taking the best one separates
     * the two cleanly, and the cell count is a usable signal-to-noise measure.
     *
     * Returns "total,best,cx,cy,peak,cellX,cellY".
     */
    public static string Hotspot(string pathA, string pathB, int threshold, int cell)
    {
        using (var a = new Bitmap(pathA))
        using (var b = new Bitmap(pathB))
        {
            if (a.Width != b.Width || a.Height != b.Height) return "ERR,size mismatch";
            int w = a.Width, h = a.Height;
            var rect = new Rectangle(0, 0, w, h);
            var da = a.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            var db = b.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);

            int cols = (w + cell - 1) / cell, rows = (h + cell - 1) / cell;
            int[] cnt = new int[cols * rows];
            long[] sx = new long[cols * rows];
            long[] sy = new long[cols * rows];
            int total = 0, peak = 0;

            int stride = da.Stride;
            byte[] rowA = new byte[stride];
            byte[] rowB = new byte[stride];

            // Cancel global exposure drift. Each camera capture restarts the
            // device and auto-exposure settles slightly differently, which
            // shifts the WHOLE frame's brightness - enough to saturate cells
            // and swamp any real LED. Subtracting the mean difference makes the
            // comparison about local changes only, which is what an LED is.
            long sumA = 0, sumB = 0;
            for (int y = 0; y < h; y++)
            {
                Marshal.Copy(da.Scan0 + y * stride, rowA, 0, stride);
                Marshal.Copy(db.Scan0 + y * stride, rowB, 0, stride);
                for (int x = 0; x < w; x++)
                {
                    int i = x * 3;
                    sumA += (rowA[i] * 29 + rowA[i + 1] * 150 + rowA[i + 2] * 77) >> 8;
                    sumB += (rowB[i] * 29 + rowB[i + 1] * 150 + rowB[i + 2] * 77) >> 8;
                }
            }
            int offset = (int)((sumB - sumA) / ((long)w * h));

            for (int y = 0; y < h; y++)
            {
                Marshal.Copy(da.Scan0 + y * stride, rowA, 0, stride);
                Marshal.Copy(db.Scan0 + y * stride, rowB, 0, stride);
                int cy = y / cell;
                for (int x = 0; x < w; x++)
                {
                    int i = x * 3;
                    int la = (rowA[i] * 29 + rowA[i + 1] * 150 + rowA[i + 2] * 77) >> 8;
                    int lb = (rowB[i] * 29 + rowB[i + 1] * 150 + rowB[i + 2] * 77) >> 8;
                    int d = lb - offset - la;
                    if (d > threshold)
                    {
                        int idx = cy * cols + (x / cell);
                        cnt[idx]++; sx[idx] += x; sy[idx] += y;
                        total++;
                        if (d > peak) peak = d;
                    }
                }
            }
            a.UnlockBits(da);
            b.UnlockBits(db);

            int best = 0, bi = -1;
            for (int i = 0; i < cnt.Length; i++) if (cnt[i] > best) { best = cnt[i]; bi = i; }
            if (bi < 0 || best == 0) return "0,0,0,0,0,0,0";

            return string.Format("{0},{1},{2},{3},{4},{5},{6}",
                total, best, sx[bi] / best, sy[bi] / best, peak, bi % cols, bi / cols);
        }
    }

    public static string BrighterRegion(string pathA, string pathB, int threshold)
    {
        using (var a = new Bitmap(pathA))
        using (var b = new Bitmap(pathB))
        {
            if (a.Width != b.Width || a.Height != b.Height) return "ERR,size mismatch";

            var rect = new Rectangle(0, 0, a.Width, a.Height);
            var da = a.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            var db = b.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);

            long count = 0, sumX = 0, sumY = 0;
            int minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1, peak = 0;

            int stride = da.Stride;
            int h = a.Height, w = a.Width;
            byte[] rowA = new byte[stride];
            byte[] rowB = new byte[stride];

            for (int y = 0; y < h; y++)
            {
                Marshal.Copy(da.Scan0 + y * stride, rowA, 0, stride);
                Marshal.Copy(db.Scan0 + y * stride, rowB, 0, stride);
                for (int x = 0; x < w; x++)
                {
                    int i = x * 3;
                    // luma-ish, integer: B G R order in 24bpp
                    int la = (rowA[i] * 29 + rowA[i + 1] * 150 + rowA[i + 2] * 77) >> 8;
                    int lb = (rowB[i] * 29 + rowB[i + 1] * 150 + rowB[i + 2] * 77) >> 8;
                    int d = lb - la;
                    if (d > threshold)
                    {
                        count++; sumX += x; sumY += y;
                        if (x < minX) minX = x;
                        if (y < minY) minY = y;
                        if (x > maxX) maxX = x;
                        if (y > maxY) maxY = y;
                        if (d > peak) peak = d;
                    }
                }
            }

            a.UnlockBits(da);
            b.UnlockBits(db);

            if (count == 0) return "0,0,0,0,0,0,0,0";
            return string.Format("{0},{1},{2},{3},{4},{5},{6},{7}",
                count, sumX / count, sumY / count, minX, minY, maxX, maxY, peak);
        }
    }

    /*
     * Draw labelled markers on a copy of an image, so a single annotated photo
     * can show which command lit which lamp.
     * `marks` entries are "x:y:label".
     */
    public static string Annotate(string srcPath, string outPath, string[] marks)
    {
        using (var src = new Bitmap(srcPath))
        using (var bmp = new Bitmap(src.Width, src.Height))
        using (var g = Graphics.FromImage(bmp))
        {
            g.DrawImage(src, 0, 0, src.Width, src.Height);
            using (var pen = new Pen(Color.Lime, 2))
            using (var font = new Font("Consolas", 11, FontStyle.Bold))
            using (var back = new SolidBrush(Color.FromArgb(190, 0, 0, 0)))
            using (var fore = new SolidBrush(Color.Lime))
            {
                foreach (var m in marks)
                {
                    var p = m.Split(':');
                    if (p.Length < 3) continue;
                    int x = int.Parse(p[0]), y = int.Parse(p[1]);
                    string label = p[2];
                    g.DrawEllipse(pen, x - 14, y - 14, 28, 28);
                    var sz = g.MeasureString(label, font);
                    g.FillRectangle(back, x + 16, y - 9, sz.Width, sz.Height);
                    g.DrawString(label, font, fore, x + 16, y - 9);
                }
            }
            bmp.Save(outPath, ImageFormat.Png);
        }
        return outPath;
    }
}
