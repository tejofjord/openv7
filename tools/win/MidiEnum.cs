using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MidiEnum
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct MIDIINCAPS
    {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public uint dwSupport;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct MIDIOUTCAPS
    {
        public ushort wMid;
        public ushort wPid;
        public uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szPname;
        public ushort wTechnology;
        public ushort wVoices;
        public ushort wNotes;
        public ushort wChannelMask;
        public uint dwSupport;
    }

    [DllImport("winmm.dll")] public static extern uint midiInGetNumDevs();
    [DllImport("winmm.dll")] public static extern uint midiOutGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Ansi)]
    public static extern uint midiInGetDevCapsA(IntPtr id, ref MIDIINCAPS caps, uint size);
    [DllImport("winmm.dll", CharSet = CharSet.Ansi)]
    public static extern uint midiOutGetDevCapsA(IntPtr id, ref MIDIOUTCAPS caps, uint size);

    // Index of the first MIDI IN / OUT port whose name contains `match`, or -1.
    public static int FindIn(string match)
    {
        uint n = midiInGetNumDevs();
        for (uint i = 0; i < n; i++)
        {
            var c = new MIDIINCAPS();
            if (midiInGetDevCapsA((IntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(MIDIINCAPS))) == 0
                && c.szPname != null
                && c.szPname.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0)
                return (int)i;
        }
        return -1;
    }

    public static int FindOut(string match)
    {
        uint n = midiOutGetNumDevs();
        for (uint i = 0; i < n; i++)
        {
            var c = new MIDIOUTCAPS();
            if (midiOutGetDevCapsA((IntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(MIDIOUTCAPS))) == 0
                && c.szPname != null
                && c.szPname.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0)
                return (int)i;
        }
        return -1;
    }

    public static string ListAll()
    {
        var sb = new StringBuilder();
        uint nIn = midiInGetNumDevs();
        sb.AppendLine("MIDI IN devices: " + nIn);
        for (uint i = 0; i < nIn; i++)
        {
            var c = new MIDIINCAPS();
            uint r = midiInGetDevCapsA((IntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(MIDIINCAPS)));
            sb.AppendLine(string.Format("  [{0}] {1}   (mid={2} pid={3} rc={4})",
                i, c.szPname, c.wMid, c.wPid, r));
        }
        uint nOut = midiOutGetNumDevs();
        sb.AppendLine("MIDI OUT devices: " + nOut);
        for (uint i = 0; i < nOut; i++)
        {
            var c = new MIDIOUTCAPS();
            uint r = midiOutGetDevCapsA((IntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(MIDIOUTCAPS)));
            sb.AppendLine(string.Format("  [{0}] {1}   (tech={2} rc={3})",
                i, c.szPname, c.wTechnology, r));
        }
        return sb.ToString();
    }
}
