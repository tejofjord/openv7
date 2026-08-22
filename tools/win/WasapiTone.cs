using System;
using System.Runtime.InteropServices;
using System.Threading;

// Minimal WASAPI renderer, used to play a known test signal into a SPECIFIC
// audio endpoint while a USB capture runs - so the capture contains real audio
// on the wire rather than silence.
//
// Targets the endpoint by its MMDevice id, so nothing about the system's
// default playback device is touched.
public static class WasapiTone
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                     [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int stgmAccess, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    // Method order here IS the vtable order - do not rearrange.
    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        int Initialize(int shareMode, int streamFlags, long bufferDuration,
                       long periodicity, IntPtr format, IntPtr sessionGuid);
        int GetBufferSize(out uint numBufferFrames);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out uint numPaddingFrames);
        int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        int GetMixFormat(out IntPtr deviceFormat);
        int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioRenderClient
    {
        int GetBuffer(uint numFramesRequested, out IntPtr data);
        int ReleaseBuffer(uint numFramesWritten, int flags);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    const int RENDER = 0;
    const int SHARE_MODE_SHARED = 0;
    const int CLSCTX_ALL = 23;
    const ushort WAVE_FORMAT_PCM = 1;
    const ushort WAVE_FORMAT_IEEE_FLOAT = 3;
    const ushort WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

    public static string LastFormat = "";

    /*
     * Play a sine tone into the endpoint with the given MMDevice id.
     *
     * A steady sine is deliberate: in the capture it should appear as an
     * obvious periodic pattern, so a bit-interleaved encoding is immediately
     * distinguishable from plain sample packing.
     */
    public static string Play(string deviceId, int seconds, double freqHz, double amplitude)
    {
        var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
        IMMDevice dev;
        int hr = enumerator.GetDevice(deviceId, out dev);
        if (hr != 0) return "GetDevice failed hr=0x" + hr.ToString("X8");

        Guid iidAudioClient = new Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
        object o;
        hr = dev.Activate(ref iidAudioClient, CLSCTX_ALL, IntPtr.Zero, out o);
        if (hr != 0) return "Activate failed hr=0x" + hr.ToString("X8");
        var client = (IAudioClient)o;

        IntPtr pFormat;
        hr = client.GetMixFormat(out pFormat);
        if (hr != 0) return "GetMixFormat failed hr=0x" + hr.ToString("X8");
        var wf = (WAVEFORMATEX)Marshal.PtrToStructure(pFormat, typeof(WAVEFORMATEX));

        // WAVE_FORMAT_EXTENSIBLE carries the real subtype after the base struct;
        // for a mix format it is effectively always float when bits == 32.
        ushort effTag = wf.wFormatTag;
        if (effTag == WAVE_FORMAT_EXTENSIBLE)
            effTag = (wf.wBitsPerSample == 32) ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;

        LastFormat = string.Format("tag={0} ch={1} rate={2} bits={3} blockAlign={4}",
            wf.wFormatTag, wf.nChannels, wf.nSamplesPerSec, wf.wBitsPerSample, wf.nBlockAlign);

        long bufDuration = 10000000L; // 1 second, in 100 ns units
        hr = client.Initialize(SHARE_MODE_SHARED, 0, bufDuration, 0, pFormat, IntPtr.Zero);
        if (hr != 0) return "Initialize failed hr=0x" + hr.ToString("X8") + " (" + LastFormat + ")";

        uint bufFrames;
        client.GetBufferSize(out bufFrames);

        Guid iidRender = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
        object o2;
        hr = client.GetService(ref iidRender, out o2);
        if (hr != 0) return "GetService failed hr=0x" + hr.ToString("X8");
        var render = (IAudioRenderClient)o2;

        double phase = 0.0;
        double step = 2.0 * Math.PI * freqHz / wf.nSamplesPerSec;
        int ch = wf.nChannels;

        // prime the buffer, then start
        IntPtr buf;
        if (render.GetBuffer(bufFrames, out buf) == 0)
        {
            WriteFrames(buf, bufFrames, ch, effTag, wf.wBitsPerSample, ref phase, step, amplitude);
            render.ReleaseBuffer(bufFrames, 0);
        }

        client.Start();
        DateTime end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            Thread.Sleep(10);
            uint padding;
            if (client.GetCurrentPadding(out padding) != 0) break;
            uint avail = bufFrames - padding;
            if (avail == 0) continue;
            if (render.GetBuffer(avail, out buf) != 0) continue;
            WriteFrames(buf, avail, ch, effTag, wf.wBitsPerSample, ref phase, step, amplitude);
            render.ReleaseBuffer(avail, 0);
        }
        client.Stop();
        Marshal.FreeCoTaskMem(pFormat);
        return "OK (" + LastFormat + ", buffer " + bufFrames + " frames)";
    }

    static void WriteFrames(IntPtr buf, uint frames, int ch, ushort tag, ushort bits,
                            ref double phase, double step, double amp)
    {
        for (uint i = 0; i < frames; i++)
        {
            double s = Math.Sin(phase) * amp;
            phase += step;
            if (phase > 2.0 * Math.PI) phase -= 2.0 * Math.PI;
            for (int c = 0; c < ch; c++)
            {
                long off = (long)i * ch * (bits / 8) + (long)c * (bits / 8);
                if (tag == WAVE_FORMAT_IEEE_FLOAT && bits == 32)
                {
                    Marshal.WriteInt32(buf, (int)off, BitConverter.ToInt32(BitConverter.GetBytes((float)s), 0));
                }
                else if (bits == 16)
                {
                    Marshal.WriteInt16(buf, (int)off, (short)(s * 32767.0));
                }
                else if (bits == 32)
                {
                    Marshal.WriteInt32(buf, (int)off, (int)(s * 2147483647.0));
                }
            }
        }
    }
}
