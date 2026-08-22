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

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        int GetBuffer(out IntPtr data, out uint numFrames, out uint flags,
                      out long devicePosition, out long qpcPosition);
        int ReleaseBuffer(uint numFramesRead);
        int GetNextPacketSize(out uint numFrames);
    }

    // Method order IS vtable order.
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        int RegisterControlChangeNotify(IntPtr notify);
        int UnregisterControlChangeNotify(IntPtr notify);
        int GetChannelCount(out uint count);
        int SetMasterVolumeLevel(float level, IntPtr ctx);
        int SetMasterVolumeLevelScalar(float level, IntPtr ctx);
        int GetMasterVolumeLevel(out float level);
        int GetMasterVolumeLevelScalar(out float level);
        int SetChannelVolumeLevel(uint ch, float level, IntPtr ctx);
        int SetChannelVolumeLevelScalar(uint ch, float level, IntPtr ctx);
        int GetChannelVolumeLevel(uint ch, out float level);
        int GetChannelVolumeLevelScalar(uint ch, out float level);
        int SetMute(int mute, IntPtr ctx);
        int GetMute(out int mute);
        int GetVolumeStepInfo(out uint step, out uint stepCount);
        int VolumeStepUp(IntPtr ctx);
        int VolumeStepDown(IntPtr ctx);
        int QueryHardwareSupport(out uint mask);
        int GetVolumeRange(out float min, out float max, out float inc);
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

    /*
     * Open a capture stream on an input endpoint and report whether any
     * non-zero samples arrive.
     *
     * The point is not the audio itself but its side effect on the wire: the
     * V7's PCM-in endpoint streams continuously yet reads as all zeros, which
     * suggests the ADC is muted until something actually opens the input. If
     * opening it makes the USB payload non-zero, the input encoding becomes
     * readable from a capture even with nothing plugged in.
     */
    public static string Record(string deviceId, int seconds)
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
        string fmt = string.Format("ch={0} rate={1} bits={2}", wf.nChannels, wf.nSamplesPerSec, wf.wBitsPerSample);

        hr = client.Initialize(SHARE_MODE_SHARED, 0, 10000000L, 0, pFormat, IntPtr.Zero);
        if (hr != 0) return "Initialize failed hr=0x" + hr.ToString("X8") + " (" + fmt + ")";

        Guid iidCapture = new Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317");
        object o2;
        hr = client.GetService(ref iidCapture, out o2);
        if (hr != 0) return "GetService failed hr=0x" + hr.ToString("X8");
        var cap = (IAudioCaptureClient)o2;

        client.Start();
        long totalFrames = 0, nonZeroBytes = 0;
        int bytesPerFrame = wf.nBlockAlign;
        DateTime end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            Thread.Sleep(10);
            uint packet;
            if (cap.GetNextPacketSize(out packet) != 0) break;
            while (packet > 0)
            {
                IntPtr data; uint frames, flags; long dp, qp;
                if (cap.GetBuffer(out data, out frames, out flags, out dp, out qp) != 0) break;
                if (data != IntPtr.Zero && frames > 0)
                {
                    int n = (int)frames * bytesPerFrame;
                    for (int i = 0; i < n; i++) if (Marshal.ReadByte(data, i) != 0) nonZeroBytes++;
                }
                totalFrames += frames;
                cap.ReleaseBuffer(frames);
                if (cap.GetNextPacketSize(out packet) != 0) break;
            }
        }
        client.Stop();
        Marshal.FreeCoTaskMem(pFormat);
        return string.Format("OK ({0}) frames={1} nonZeroBytes={2}", fmt, totalFrames, nonZeroBytes);
    }

    /*
     * Report an endpoint's mute/level, and optionally unmute and raise it.
     *
     * The V7's PCM-in endpoint streams continuously but reads as all zeros even
     * with a capture stream open. If that is because the endpoint is muted or
     * at zero gain, clearing it should let ADC noise through - and noise, unlike
     * silence, reveals the frame layout.
     */
    public static string EndpointVolume(string deviceId, bool unmuteAndMax)
    {
        var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
        IMMDevice dev;
        int hr = enumerator.GetDevice(deviceId, out dev);
        if (hr != 0) return "GetDevice failed hr=0x" + hr.ToString("X8");

        Guid iid = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        object o;
        hr = dev.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o);
        if (hr != 0) return "Activate(IAudioEndpointVolume) failed hr=0x" + hr.ToString("X8");
        var vol = (IAudioEndpointVolume)o;

        int muted; float scalar; uint chCount; uint hw;
        vol.GetMute(out muted);
        vol.GetMasterVolumeLevelScalar(out scalar);
        vol.GetChannelCount(out chCount);
        vol.QueryHardwareSupport(out hw);
        string before = string.Format("mute={0} level={1:P1} channels={2} hwSupport=0x{3:X}",
                                      muted, scalar, chCount, hw);

        for (uint c = 0; c < chCount; c++)
        {
            float cv;
            if (vol.GetChannelVolumeLevelScalar(c, out cv) == 0)
                before += string.Format(" ch{0}={1:P1}", c, cv);
        }

        if (!unmuteAndMax) return before;

        vol.SetMute(0, IntPtr.Zero);
        vol.SetMasterVolumeLevelScalar(1.0f, IntPtr.Zero);
        for (uint c = 0; c < chCount; c++) vol.SetChannelVolumeLevelScalar(c, 1.0f, IntPtr.Zero);

        vol.GetMute(out muted);
        vol.GetMasterVolumeLevelScalar(out scalar);
        return before + string.Format("  ->  after: mute={0} level={1:P1}", muted, scalar);
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
