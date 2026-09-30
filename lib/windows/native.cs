// Windows-only helpers for takwerx, compiled at run time by PowerShell's Add-Type (so C# 5:
// the .NET Framework compiler that ships with Windows PowerShell 5.1). What PowerShell cannot
// do by itself: a shortcut that carries an AppUserModelID, the same ID and relaunch details
// on the emulator's windows (one taskbar button, "TAKwerx ATAK Terminal", ATAK's icon), the
// window title and icon, the screen's work area in real pixels, and keeping the display on.
// The emulator binary is Google's and is never modified on Windows (DECISIONS 2026-09-27).
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace Takwerx
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
        public PropertyKey(Guid f, uint p) { FormatId = f; PropertyId = p; }
    }

    // A PROPVARIANT holding a string (VT_LPWSTR). 24 bytes, the x64 size, so the native side
    // never writes past it.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort VarType;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    public interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    public interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int max, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idl);
        void SetIDList(IntPtr idl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLink { }

    /// <summary>Reads an APK's resource table (resources.arsc). Release builds of ATAK store
    /// their resources under scrambled file names (res/3k.png), so a file named
    /// ic_atak_launcher.png exists only in the SDK's development build; the table still maps
    /// the name to the file (DECISIONS 2026-09-27).</summary>
    public static class Apk
    {
        static int U16(byte[] d, int o) { return d[o] | (d[o + 1] << 8); }
        static long U32(byte[] d, int o) { return (uint)(d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)); }

        static string[] Pool(byte[] d, int o)
        {
            int hsz = U16(d, o + 2);
            int count = (int)U32(d, o + 8);
            bool utf8 = (U32(d, o + 16) & 0x100) != 0;
            int start = (int)U32(d, o + 20);
            string[] result = new string[count];
            for (int i = 0; i < count; i++)
            {
                int p = o + start + (int)U32(d, o + hsz + 4 * i);
                if (utf8)
                {
                    int n = d[p]; p++; if ((n & 0x80) != 0) p++;
                    n = d[p]; p++; if ((n & 0x80) != 0) { n = ((n & 0x7f) << 8) | d[p]; p++; }
                    result[i] = Encoding.UTF8.GetString(d, p, n);
                }
                else
                {
                    int n = U16(d, p); p += 2;
                    if ((n & 0x8000) != 0) { n = ((n & 0x7fff) << 16) | U16(d, p); p += 2; }
                    result[i] = Encoding.Unicode.GetString(d, p, 2 * n);
                }
            }
            return result;
        }

        /// <summary>The PNG file behind the resource entry named <paramref name="name"/>, at the
        /// highest density the table has it in; null when there is none.</summary>
        public static string ResourcePath(byte[] d, string name)
        {
            try { return Find(d, name); }
            catch (IndexOutOfRangeException) { return null; }   // a table this reader does not know
            catch (ArgumentException) { return null; }
        }

        static string Find(byte[] d, string name)
        {
            if (d == null || d.Length < 12) return null;
            int o = U16(d, 2);
            string[] values = Pool(d, o);
            o += (int)U32(d, o + 4);
            string best = null; int bestDensity = -1;
            while (o + 8 <= d.Length)
            {
                int type = U16(d, o); int size = (int)U32(d, o + 4);
                if (size <= 0) break;
                if (type == 0x0200)
                {
                    string[] keys = Pool(d, o + (int)U32(d, o + 276));
                    int p = o + U16(d, o + 2);
                    while (p + 8 <= o + size)
                    {
                        int t = U16(d, p); int tsize = (int)U32(d, p + 4);
                        if (tsize <= 0) break;
                        if (t == 0x0201)
                        {
                            int th = U16(d, p + 2); int flags = d[p + 9];
                            int count = (int)U32(d, p + 12); int start = (int)U32(d, p + 16);
                            int density = U16(d, p + 20 + 14);
                            if (density >= 0xfff0) density = 0;
                            for (int i = 0; i < count; i++)
                            {
                                long eo;
                                if ((flags & 0x01) != 0) eo = U16(d, p + th + 4 * i + 2) * 4L;            // sparse
                                else if ((flags & 0x02) != 0) { eo = U16(d, p + th + 2 * i); if (eo == 0xFFFF) continue; eo *= 4; } // 16-bit offsets
                                else { eo = U32(d, p + th + 4 * i); if (eo == 0xFFFFFFFFL) continue; }
                                int e = p + start + (int)eo;
                                int ef = U16(d, e + 2);
                                int key; int vtype; long vdata;
                                if ((ef & 0x08) != 0) { key = U16(d, e); vtype = (ef >> 8) & 0xff; vdata = U32(d, e + 4); } // compact
                                else
                                {
                                    if ((ef & 0x01) != 0) continue;   // a bag, not a value
                                    int esz = U16(d, e); key = (int)U32(d, e + 4);
                                    vtype = d[e + esz + 3]; vdata = U32(d, e + esz + 4);
                                }
                                if (key < 0 || key >= keys.Length || keys[key] != name) continue;
                                if (vtype != 0x03 || vdata >= values.Length) continue;
                                string path = values[vdata];
                                if (!path.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) continue;
                                if (density > bestDensity) { best = path; bestDensity = density; }
                            }
                        }
                        p += tsize;
                    }
                }
                o += size;
            }
            return best;
        }
    }

    public static class Native
    {
        // System.AppUserModel.* (propkey.h): ID 5, RelaunchCommand 2, RelaunchIconResource 3,
        // RelaunchDisplayNameResource 4.
        static readonly Guid AppModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        static readonly Guid PropertyStoreId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        const ushort VT_LPWSTR = 31;

        delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowText(IntPtr hwnd, string text);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr hinst, string name, uint type, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, ref Rect rect, uint winIni);
        [DllImport("user32.dll")] static extern uint GetDpiForSystem();
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect { public int Left, Top, Right, Bottom; }

        /// <summary>A shortcut with an icon, a show state and an AppUserModelID, so the taskbar
        /// treats the windows that carry the same ID as this app.</summary>
        public static void CreateShortcut(string lnk, string target, string args, string workDir,
                                          string icon, string description, string appId, int showCmd)
        {
            IShellLinkW link = (IShellLinkW)new ShellLink();
            link.SetPath(target);
            link.SetArguments(args);
            link.SetWorkingDirectory(workDir);
            link.SetIconLocation(icon, 0);
            link.SetDescription(description);
            link.SetShowCmd(showCmd);
            IPropertyStore store = (IPropertyStore)link;
            SetString(store, 5, appId);
            store.Commit();
            ((IPersistFile)link).Save(lnk, true);
            Marshal.ReleaseComObject(store);
            Marshal.ReleaseComObject(link);
        }

        static void SetString(IPropertyStore store, uint pid, string value)
        {
            PropertyKey key = new PropertyKey(AppModel, pid);
            PropVariant pv = new PropVariant();
            pv.VarType = VT_LPWSTR;
            pv.Pointer = Marshal.StringToCoTaskMemUni(value);
            try { store.SetValue(ref key, ref pv); }
            finally { Marshal.FreeCoTaskMem(pv.Pointer); }
        }

        /// <summary>Visible top-level windows belonging to a process, the emulator's main
        /// window and its side toolbar among them.</summary>
        public static IntPtr[] WindowsOf(int pid)
        {
            List<IntPtr> found = new List<IntPtr>();
            EnumWindows(delegate (IntPtr h, IntPtr l)
            {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner == (uint)pid && IsWindowVisible(h))
                    found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        public static string TitleOf(IntPtr hwnd)
        {
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static void SetTitle(IntPtr hwnd, string title) { SetWindowText(hwnd, title); }

        /// <summary>Taskbar identity for a window: the app's ID, and what a pin of its button
        /// relaunches, under which name and icon.</summary>
        public static bool SetAppIdentity(IntPtr hwnd, string appId, string relaunchCommand,
                                          string displayName, string iconResource)
        {
            Guid iid = PropertyStoreId;
            IPropertyStore store;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null)
                return false;
            try
            {
                SetString(store, 2, relaunchCommand);
                SetString(store, 4, displayName);
                SetString(store, 3, iconResource);
                SetString(store, 5, appId);
                return true;
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        /// <summary>Loads an .ico at a size. The handle belongs to this process and dies with
        /// it, which is why the long-running watcher sets the icon, not a one-shot command.</summary>
        public static IntPtr LoadIcon(string path, int size)
        {
            return LoadImage(IntPtr.Zero, path, 1 /* IMAGE_ICON */, size, size, 0x10 /* LR_LOADFROMFILE */);
        }

        public static void SetIcons(IntPtr hwnd, IntPtr small, IntPtr big)
        {
            if (small != IntPtr.Zero) SendMessage(hwnd, 0x0080 /* WM_SETICON */, IntPtr.Zero /* ICON_SMALL */, small);
            if (big != IntPtr.Zero) SendMessage(hwnd, 0x0080, new IntPtr(1) /* ICON_BIG */, big);
        }

        public static void Front(IntPtr hwnd)
        {
            if (IsIconic(hwnd)) ShowWindow(hwnd, 9 /* SW_RESTORE */);
            SetForegroundWindow(hwnd);
        }

        /// <summary>The primary screen's work area (without the taskbar) in real pixels, and the
        /// system DPI: "width height dpi".</summary>
        public static string WorkArea()
        {
            SetProcessDPIAware();
            Rect r = new Rect();
            SystemParametersInfo(0x0030 /* SPI_GETWORKAREA */, 0, ref r, 0);
            uint dpi = 96;
            try { dpi = GetDpiForSystem(); } catch (EntryPointNotFoundException) { }
            return (r.Right - r.Left) + " " + (r.Bottom - r.Top) + " " + dpi;
        }

        /// <summary>Display and system stay on for as long as the calling thread lives.</summary>
        public static void StayAwake()
        {
            SetThreadExecutionState(0x80000000 | 0x00000002 | 0x00000001); // CONTINUOUS | DISPLAY | SYSTEM
        }

        // ---- full screen --------------------------------------------------------------------
        // The emulator has no full-screen mode, so its main window is made one from outside,
        // the way Windows programs do it themselves: the frame styles off, the window over the
        // whole monitor (Windows then hides the taskbar), the side toolbar hidden where it
        // lands on that monitor. Android is sized to the monitor for this at start, so the
        // emulator's picture fits it exactly; F11, while the window is in front, switches to
        // the normal window and back, restoring the placement it had.
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr hwnd, ref WindowPlacement wp);
        [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr hwnd, ref WindowPlacement wp);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo mi);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);

        [StructLayout(LayoutKind.Sequential)]
        public struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)]
        public struct WindowPlacement { public int Length, Flags, ShowCmd; public Point MinPosition, MaxPosition; public Rect NormalPosition; }
        [StructLayout(LayoutKind.Sequential)]
        public struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }

        const int GWL_STYLE = -16;
        const int WS_OVERLAPPEDWINDOW = 0x00CF0000; // caption, system menu, sizing frame, min/max boxes
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_FRAMECHANGED = 0x20, SWP_NOOWNERZORDER = 0x200;

        /// <summary>Whether the emulator's window should be full screen now; F11 flips it.</summary>
        public static volatile bool Fullscreen;
        static readonly object Gate = new object();
        static IntPtr fsWindow = IntPtr.Zero;
        static int fsStyle;
        static WindowPlacement fsPlacement;
        static readonly List<IntPtr> fsHidden = new List<IntPtr>();
        // Re-applications left for this entry into full screen. The first try (2026-09-29, the
        // Dell) re-applied every 3 seconds without limit, and ATAK stopped responding twice:
        // each resize rebuilds the emulator's swapchain, which has stalled ATAK's GL thread
        // before (DECISIONS 2026-09-26). So a few tries, each logged, then leave it be.
        static int fsTries;
        static readonly List<string> notes = new List<string>();

        static string Show(Rect r) { return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top); }
        static void Note(string s) { lock (notes) { notes.Add(s); } }

        /// <summary>What the full-screen code did since the last call, for the watcher's log.</summary>
        public static string[] TakeNotes()
        {
            lock (notes) { string[] a = notes.ToArray(); notes.Clear(); return a; }
        }

        /// <summary>The primary screen's full size in real pixels, and the system DPI:
        /// "width height dpi".</summary>
        public static string ScreenSize()
        {
            SetProcessDPIAware();
            uint dpi = 96;
            try { dpi = GetDpiForSystem(); } catch (EntryPointNotFoundException) { }
            return GetSystemMetrics(0 /* SM_CXSCREEN */) + " " + GetSystemMetrics(1 /* SM_CYSCREEN */) + " " + dpi;
        }

        // The main window is the process's largest; the toolbar and Extended Controls are smaller.
        static IntPtr MainWindowOf(int pid)
        {
            IntPtr best = IntPtr.Zero; long bestArea = 0;
            foreach (IntPtr h in WindowsOf(pid))
            {
                Rect r;
                if (!GetWindowRect(h, out r)) continue;
                long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
                if (area > bestArea) { best = h; bestArea = area; }
            }
            return best;
        }

        /// <summary>Puts the emulator's main window in the state Fullscreen asks for. Called
        /// every few seconds by the watcher; re-applies only a few times per entry.</summary>
        public static void ApplyScreenMode(int pid)
        {
            lock (Gate)
            {
                SetProcessDPIAware();
                IntPtr main = fsWindow != IntPtr.Zero && Fullscreen ? fsWindow : MainWindowOf(pid);
                if (main == IntPtr.Zero) return;
                int style = GetWindowLong(main, GWL_STYLE);
                if (Fullscreen)
                {
                    MonitorInfo mi = new MonitorInfo();
                    mi.Size = Marshal.SizeOf(typeof(MonitorInfo));
                    if (!GetMonitorInfo(MonitorFromWindow(main, 2 /* MONITOR_DEFAULTTONEAREST */), ref mi)) return;
                    if (fsWindow != main)
                    {
                        WindowPlacement wp = new WindowPlacement();
                        wp.Length = Marshal.SizeOf(typeof(WindowPlacement));
                        if (!GetWindowPlacement(main, ref wp)) return;
                        fsWindow = main; fsStyle = style; fsPlacement = wp; fsTries = 5;
                    }
                    Rect r;
                    GetWindowRect(main, out r);
                    Rect m = mi.Monitor;
                    if (fsTries > 0 && ((style & WS_OVERLAPPEDWINDOW) != 0 || r.Left != m.Left || r.Top != m.Top || r.Right != m.Right || r.Bottom != m.Bottom))
                    {
                        fsTries--;
                        SetWindowLong(main, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
                        SetWindowPos(main, IntPtr.Zero, m.Left, m.Top, m.Right - m.Left, m.Bottom - m.Top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
                        Rect after;
                        GetWindowRect(main, out after);
                        Note(string.Format("full screen: window {0} style 0x{1:x8} -> {2} on monitor {3}; {4} tries left{5}",
                            Show(r), style, Show(after), Show(m), fsTries,
                            fsTries == 0 ? ", then the window is left as the emulator has it" : ""));
                    }
                    foreach (IntPtr h in WindowsOf(pid))
                    {
                        if (h == main) continue;
                        Rect t;
                        if (!GetWindowRect(h, out t)) continue;
                        bool narrow = (t.Right - t.Left) * 3 < (t.Bottom - t.Top);
                        bool onScreen = t.Left < m.Right && t.Right > m.Left && t.Top < m.Bottom && t.Bottom > m.Top;
                        if (narrow && onScreen) { ShowWindow(h, 0 /* SW_HIDE */); if (!fsHidden.Contains(h)) fsHidden.Add(h); }
                    }
                }
                else if (fsWindow != IntPtr.Zero)
                {
                    IntPtr w = fsWindow;
                    fsWindow = IntPtr.Zero;
                    SetWindowLong(w, GWL_STYLE, fsStyle);
                    WindowPlacement wp = fsPlacement;
                    SetWindowPlacement(w, ref wp);
                    SetWindowPos(w, IntPtr.Zero, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
                    foreach (IntPtr h in fsHidden) ShowWindow(h, 4 /* SW_SHOWNOACTIVATE */);
                    fsHidden.Clear();
                    Rect back;
                    GetWindowRect(w, out back);
                    // Android is the whole screen's size in this mode, so the window it
                    // opened with is the screen plus a frame, 1938x1222 on a 1920x1200 Dell,
                    // over the taskbar and off the edges. Scaled into the work area instead,
                    // the picture's proportions kept, centred.
                    MonitorInfo wmi = new MonitorInfo();
                    wmi.Size = Marshal.SizeOf(typeof(MonitorInfo));
                    Rect client;
                    if (GetMonitorInfo(MonitorFromWindow(w, 2 /* MONITOR_DEFAULTTONEAREST */), ref wmi) && GetClientRect(w, out client))
                    {
                        Rect wa = wmi.Work;
                        int waW = wa.Right - wa.Left, waH = wa.Bottom - wa.Top;
                        int outW = back.Right - back.Left, outH = back.Bottom - back.Top;
                        int cw = client.Right - client.Left, ch = client.Bottom - client.Top;
                        int fw = outW - cw, fh = outH - ch;
                        if ((outW > waW || outH > waH) && cw > 0 && ch > 0 && waW > fw && waH > fh)
                        {
                            double k = Math.Min((double)(waW - fw) / cw, (double)(waH - fh) / ch);
                            int nw = (int)(cw * k) + fw, nh = (int)(ch * k) + fh;
                            SetWindowPos(w, IntPtr.Zero, wa.Left + (waW - nw) / 2, wa.Top + (waH - nh) / 2, nw, nh, SWP_NOZORDER | SWP_NOOWNERZORDER);
                            Note(string.Format("full screen off: {0} is bigger than the work area {1}; fitted", Show(back), Show(wa)));
                            GetWindowRect(w, out back);
                        }
                    }
                    Note("full screen off: window back at " + Show(back));
                }
            }
        }

        static bool KeyDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

        /// <summary>F11, or Ctrl+Alt+F for keyboards whose F-keys are media keys, while one of
        /// the emulator's windows is in front, flips full screen. The keys still reach Android,
        /// which does nothing with them.</summary>
        public static void WatchKeys(int pid)
        {
            System.Threading.Thread t = new System.Threading.Thread(delegate ()
            {
                bool down = false;
                while (true)
                {
                    System.Threading.Thread.Sleep(40);
                    bool f11 = KeyDown(0x7A /* VK_F11 */);
                    bool combo = KeyDown(0x11 /* VK_CONTROL */) && KeyDown(0x12 /* VK_MENU */) && KeyDown(0x46 /* F */);
                    bool now = f11 || combo;
                    if (now && !down)
                    {
                        uint owner;
                        GetWindowThreadProcessId(GetForegroundWindow(), out owner);
                        if (owner == (uint)pid)
                        {
                            Fullscreen = !Fullscreen;
                            Note(string.Format("{0}: full screen {1}", f11 ? "F11" : "Ctrl+Alt+F", Fullscreen ? "on" : "off"));
                            try { ApplyScreenMode(pid); } catch (Exception e) { Note("full screen: " + e.Message); }
                        }
                    }
                    down = now;
                }
            });
            t.IsBackground = true;
            t.Start();
        }
    }
}
