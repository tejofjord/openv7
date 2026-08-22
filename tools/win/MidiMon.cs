using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Minimal winmm MIDI monitor for mapping the Numark V7's control surface
// through the stock Windows vendor driver.
//
// The V7 emits a heavy continuous stream, so aggregation happens HERE rather
// than in PowerShell: the callback folds each message into a per-(status,data1)
// bucket. Callers poll cheap counters and pull a summary, instead of marshalling
// tens of thousands of objects per second across the interop boundary.
public static class MidiMon
{
    const int CALLBACK_FUNCTION = 0x00030000;
    const int MIM_DATA = 0x3C3;
    const int MIM_LONGDATA = 0x3C4;

    delegate void MidiInProc(IntPtr hMidiIn, uint wMsg, IntPtr dwInstance,
                             IntPtr dwParam1, IntPtr dwParam2);

    [StructLayout(LayoutKind.Sequential)]
    struct MIDIHDR
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public IntPtr lpNext;
        public IntPtr reserved;
        public uint dwOffset;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
        public IntPtr[] dwReserved;
    }

    [DllImport("winmm.dll")] static extern uint midiInOpen(out IntPtr h, uint id, MidiInProc cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] static extern uint midiInStart(IntPtr h);
    [DllImport("winmm.dll")] static extern uint midiInStop(IntPtr h);
    [DllImport("winmm.dll")] static extern uint midiInReset(IntPtr h);
    [DllImport("winmm.dll")] static extern uint midiInClose(IntPtr h);
    [DllImport("winmm.dll")] static extern uint midiInPrepareHeader(IntPtr h, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint midiInUnprepareHeader(IntPtr h, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint midiInAddBuffer(IntPtr h, IntPtr hdr, uint size);

    [DllImport("winmm.dll")] static extern uint midiOutOpen(out IntPtr h, uint id, IntPtr cb, IntPtr inst, uint flags);
    [DllImport("winmm.dll")] static extern uint midiOutShortMsg(IntPtr h, uint msg);
    [DllImport("winmm.dll")] static extern uint midiOutLongMsg(IntPtr h, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint midiOutPrepareHeader(IntPtr h, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint midiOutUnprepareHeader(IntPtr h, IntPtr hdr, uint size);
    [DllImport("winmm.dll")] static extern uint midiOutReset(IntPtr h);
    [DllImport("winmm.dll")] static extern uint midiOutClose(IntPtr h);

    class Agg
    {
        public long Count;
        public int Min = int.MaxValue, Max = -1;
        public long FirstMs = -1, LastMs = -1;
        public HashSet<int> Seen = new HashSet<int>();
        public List<string> Samples = new List<string>();
    }

    // Which byte identifies the control, and which byte(s) carry its value,
    // depends on the message type. Channel-pressure and program-change have a
    // single data byte; pitch-bend's two bytes are one 14-bit value, NOT an
    // identifier plus a value. Bucketing those on data1 would shatter a single
    // stream into up to 128 phantom controls.
    static int KeyFor(int status, int d1)
    {
        int type = status & 0xF0;
        if (status >= 0xF0) return status << 8;            // system messages
        if (type == 0xC0 || type == 0xD0 || type == 0xE0) return status << 8;
        return (status << 8) | d1;                          // note / poly-AT / CC
    }

    static int ValueFor(int status, int d1, int d2)
    {
        int type = status & 0xF0;
        if (type == 0xC0 || type == 0xD0) return d1;
        if (type == 0xE0) return d1 | (d2 << 7);            // 14-bit, LSB first
        return d2;
    }

    static IntPtr _hIn = IntPtr.Zero;
    static IntPtr _hOut = IntPtr.Zero;
    static MidiInProc _proc;                 // held so the GC cannot collect the delegate
    static IntPtr _sysexHdr = IntPtr.Zero;
    static IntPtr _sysexBuf = IntPtr.Zero;
    const int SYSEX_LEN = 1024;

    static readonly object _lock = new object();
    static Dictionary<int, Agg> _stats = new Dictionary<int, Agg>();
    static List<string> _sysex = new List<string>();
    static long _total = 0;

    // Optional raw log. Aggregates lose ordering, but sequence matters for
    // anything rate-derived - e.g. how far the platter counter advances per
    // USB frame, which is what gives the encoder resolution.
    static bool _recordRaw = false;
    static int _rawCap = 0;
    static List<int> _rawStatus, _rawD1, _rawD2;
    static List<long> _rawMs;

    public static void RecordRaw(int capacity)
    {
        lock (_lock)
        {
            _recordRaw = capacity > 0;
            _rawCap = capacity;
            _rawStatus = new List<int>(); _rawD1 = new List<int>();
            _rawD2 = new List<int>(); _rawMs = new List<long>();
        }
    }

    // "ms status d1 d2" in arrival order, at most `capacity` entries.
    public static string[] Raw()
    {
        lock (_lock)
        {
            if (_rawStatus == null) return new string[0];
            var outp = new string[_rawStatus.Count];
            for (int i = 0; i < _rawStatus.Count; i++)
                outp[i] = _rawMs[i] + " " + _rawStatus[i] + " " + _rawD1[i] + " " + _rawD2[i];
            return outp;
        }
    }

    // cheap poll target for gesture detection
    public static long Total { get { return Interlocked.Read(ref _total); } }

    public static void Reset()
    {
        lock (_lock)
        {
            _stats = new Dictionary<int, Agg>();
            _sysex = new List<string>();
            if (_recordRaw)
            {
                _rawStatus = new List<int>(); _rawD1 = new List<int>();
                _rawD2 = new List<int>(); _rawMs = new List<long>();
            }
        }
        Interlocked.Exchange(ref _total, 0);
    }

    static void Callback(IntPtr h, uint wMsg, IntPtr inst, IntPtr p1, IntPtr p2)
    {
        if (wMsg == MIM_DATA)
        {
            uint packed = (uint)p1.ToInt64();
            long ms = p2.ToInt64();
            int status = (int)(packed & 0xFF);
            int d1 = (int)((packed >> 8) & 0x7F);
            int d2 = (int)((packed >> 16) & 0x7F);
            int key = KeyFor(status, d1);
            int val = ValueFor(status, d1, d2);

            lock (_lock)
            {
                Agg a;
                if (!_stats.TryGetValue(key, out a)) { a = new Agg(); _stats[key] = a; }
                a.Count++;
                if (val < a.Min) a.Min = val;
                if (val > a.Max) a.Max = val;
                if (a.Seen.Count < 16384) a.Seen.Add(val);
                if (a.FirstMs < 0) a.FirstMs = ms;
                a.LastMs = ms;
                if (a.Samples.Count < 8)
                    a.Samples.Add(status.ToString("X2") + " " + d1.ToString("X2") + " " + d2.ToString("X2"));

                if (_recordRaw && _rawStatus.Count < _rawCap)
                {
                    _rawStatus.Add(status); _rawD1.Add(d1); _rawD2.Add(d2); _rawMs.Add(ms);
                }
            }
            Interlocked.Increment(ref _total);
        }
        else if (wMsg == MIM_LONGDATA)
        {
            try
            {
                MIDIHDR hdr = (MIDIHDR)Marshal.PtrToStructure(p1, typeof(MIDIHDR));
                int n = (int)hdr.dwBytesRecorded;
                if (n > 0)
                {
                    byte[] buf = new byte[n];
                    Marshal.Copy(hdr.lpData, buf, 0, n);
                    var sb = new StringBuilder();
                    foreach (byte b in buf) sb.Append(b.ToString("x2"));
                    lock (_lock) { if (_sysex.Count < 64) _sysex.Add(sb.ToString()); }
                    Interlocked.Increment(ref _total);
                }
                if (_hIn != IntPtr.Zero)
                    midiInAddBuffer(_hIn, p1, (uint)Marshal.SizeOf(typeof(MIDIHDR)));
            }
            catch { }
        }
    }

    public static uint OpenIn(uint deviceId)
    {
        _proc = new MidiInProc(Callback);
        uint r = midiInOpen(out _hIn, deviceId, _proc, IntPtr.Zero, CALLBACK_FUNCTION);
        if (r != 0) return r;

        _sysexBuf = Marshal.AllocHGlobal(SYSEX_LEN);
        MIDIHDR hdr = new MIDIHDR();
        hdr.lpData = _sysexBuf;
        hdr.dwBufferLength = SYSEX_LEN;
        hdr.dwReserved = new IntPtr[8];
        _sysexHdr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(MIDIHDR)));
        Marshal.StructureToPtr(hdr, _sysexHdr, false);
        midiInPrepareHeader(_hIn, _sysexHdr, (uint)Marshal.SizeOf(typeof(MIDIHDR)));
        midiInAddBuffer(_hIn, _sysexHdr, (uint)Marshal.SizeOf(typeof(MIDIHDR)));

        return midiInStart(_hIn);
    }

    public static void CloseIn()
    {
        if (_hIn == IntPtr.Zero) return;
        IntPtr h = _hIn;
        _hIn = IntPtr.Zero;                  // stop the callback re-arming the buffer
        midiInStop(h);
        midiInReset(h);
        if (_sysexHdr != IntPtr.Zero)
        {
            midiInUnprepareHeader(h, _sysexHdr, (uint)Marshal.SizeOf(typeof(MIDIHDR)));
            Marshal.FreeHGlobal(_sysexHdr); _sysexHdr = IntPtr.Zero;
        }
        if (_sysexBuf != IntPtr.Zero) { Marshal.FreeHGlobal(_sysexBuf); _sysexBuf = IntPtr.Zero; }
        midiInClose(h);
    }

    public static uint OpenOut(uint deviceId)
    {
        return midiOutOpen(out _hOut, deviceId, IntPtr.Zero, IntPtr.Zero, 0);
    }

    public static uint Send(byte status, byte d1, byte d2)
    {
        if (_hOut == IntPtr.Zero) return 0xFFFFFFFF;
        return midiOutShortMsg(_hOut, (uint)(status | (d1 << 8) | (d2 << 16)));
    }

    // Send a SysEx (or any long) message. `hex` is a plain hex string and must
    // include the leading F0 and trailing F7.
    public static uint SendSysex(string hex)
    {
        if (_hOut == IntPtr.Zero) return 0xFFFFFFFF;
        int n = hex.Length / 2;
        byte[] data = new byte[n];
        for (int i = 0; i < n; i++)
            data[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);

        IntPtr buf = Marshal.AllocHGlobal(n);
        Marshal.Copy(data, 0, buf, n);

        MIDIHDR hdr = new MIDIHDR();
        hdr.lpData = buf;
        hdr.dwBufferLength = (uint)n;
        hdr.dwBytesRecorded = (uint)n;
        hdr.dwReserved = new IntPtr[8];
        IntPtr pHdr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(MIDIHDR)));
        Marshal.StructureToPtr(hdr, pHdr, false);

        uint size = (uint)Marshal.SizeOf(typeof(MIDIHDR));
        uint r = midiOutPrepareHeader(_hOut, pHdr, size);
        if (r == 0)
        {
            r = midiOutLongMsg(_hOut, pHdr, size);
            // the device may still be draining the buffer; wait for the done flag
            for (int i = 0; i < 100; i++)
            {
                MIDIHDR back = (MIDIHDR)Marshal.PtrToStructure(pHdr, typeof(MIDIHDR));
                if ((back.dwFlags & 0x00000001) != 0) break;   // MHDR_DONE
                Thread.Sleep(5);
            }
            midiOutUnprepareHeader(_hOut, pHdr, size);
        }
        Marshal.FreeHGlobal(pHdr);
        Marshal.FreeHGlobal(buf);
        return r;
    }

    public static void CloseOut()
    {
        if (_hOut == IntPtr.Zero) return;
        IntPtr h = _hOut;
        _hOut = IntPtr.Zero;
        midiOutReset(h);
        midiOutClose(h);
    }

    // One line per (status,data1) bucket:
    //   status,data1,count,min,max,distinct,spanMs,sample1|sample2|...
    // SysEx lines:  SYSEX,hex
    public static string[] Summary()
    {
        var outp = new List<string>();
        lock (_lock)
        {
            foreach (var kv in _stats)
            {
                int status = (kv.Key >> 8) & 0xFF;
                int d1 = kv.Key & 0xFF;
                Agg a = kv.Value;
                long span = (a.FirstMs >= 0 && a.LastMs >= a.FirstMs) ? (a.LastMs - a.FirstMs) : 0;
                outp.Add(string.Join(",", new string[] {
                    status.ToString(), d1.ToString(), a.Count.ToString(),
                    (a.Max < 0 ? 0 : a.Min).ToString(), (a.Max < 0 ? 0 : a.Max).ToString(),
                    a.Seen.Count.ToString(), span.ToString(),
                    string.Join("|", a.Samples.ToArray())
                }));
            }
            foreach (string s in _sysex) outp.Add("SYSEX," + s);
        }
        return outp.ToArray();
    }

    // Distinct values seen for one bucket, sorted (for value-range work).
    // 7-bit for note/CC, 14-bit for pitch-bend.
    public static int[] Values(int status, int d1)
    {
        var list = new List<int>();
        lock (_lock)
        {
            Agg a;
            if (_stats.TryGetValue(KeyFor(status, d1), out a)) list.AddRange(a.Seen);
        }
        list.Sort();
        return list.ToArray();
    }
}
