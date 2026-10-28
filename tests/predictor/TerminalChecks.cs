using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

internal static class TerminalChecks
{
    public static int RunChild(string executable)
    {
        var attributes = new SecurityAttributes { Size = Marshal.SizeOf<SecurityAttributes>(), Inherit = true };
        using var input = CreateFile("CONIN$", 0xC0000000, 3, ref attributes, 3, 0, IntPtr.Zero);
        using var output = CreateFile("CONOUT$", 0xC0000000, 3, ref attributes, 3, 0, IntPtr.Zero);
        if (input.IsInvalid || output.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var startup = new StartupInfoEx
        {
            StartupInfo = new StartupInfo
            {
                Size = Marshal.SizeOf<StartupInfo>(), Flags = 0x100,
                Input = input.DangerousGetHandle(), Output = output.DangerousGetHandle(), Error = output.DangerousGetHandle()
            }
        };
        Environment.SetEnvironmentVariable("ZIGSTORY_TUI_LAUNCH_NS",
            ((decimal)Stopwatch.GetTimestamp() * 1_000_000_000 / Stopwatch.Frequency).ToString("F0", System.Globalization.CultureInfo.InvariantCulture));
        Check(CreateProcess(Path.GetFullPath(executable), new StringBuilder($"\"{Path.GetFullPath(executable)}\" search"),
            IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, Environment.CurrentDirectory, ref startup, out var process), "Launch console child");
        try
        {
            WaitForSingleObject(process.Process, uint.MaxValue);
            Check(GetExitCodeProcess(process.Process, out var exitCode), "Read child exit code");
            return checked((int)exitCode);
        }
        finally { CloseHandle(process.Thread); CloseHandle(process.Process); }
    }

    public static void Run(string executable)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("ConPTY checks require Windows.");
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_terminal_{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var report = Path.Combine(directory, "terminal.json");
        var saved = new[] { "USERPROFILE", "HOME", "ZIGSTORY_TUI_PROFILE", "ZIGSTORY_TUI_LAUNCH_NS" }
            .ToDictionary(key => key, Environment.GetEnvironmentVariable);
        IntPtr inputRead = default, inputWrite = default, outputRead = default, outputWrite = default;
        IntPtr console = default, attributes = default;
        ProcessInfo process = default;
        FileStream? input = null;
        Task? drain = null;
        long bytes = 0;
        var transcript = new StringBuilder();
        try
        {
            Check(CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0), "Create input pipe");
            Check(CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0), "Create output pipe");
            var hr = CreatePseudoConsole(new Coord { X = 100, Y = 30 }, inputRead, outputWrite, 0, out console);
            Marshal.ThrowExceptionForHR(hr);
            CloseHandle(inputRead); inputRead = default;
            CloseHandle(outputWrite); outputWrite = default;
            input = new FileStream(new SafeFileHandle(inputWrite, ownsHandle: true), FileAccess.Write);
            inputWrite = default;
            var output = new FileStream(new SafeFileHandle(outputRead, ownsHandle: true), FileAccess.Read);
            outputRead = default;
            drain = Task.Run(() =>
            {
                using (output)
                {
                    var buffer = new byte[8192];
                    try
                    {
                        int count;
                        while ((count = output.Read(buffer)) > 0)
                        {
                            Interlocked.Add(ref bytes, count);
                            lock (transcript) if (transcript.Length < 8192) transcript.Append(Encoding.UTF8.GetString(buffer, 0, count));
                        }
                    }
                    catch (IOException ex) when ((ex.HResult & 0xFFFF) == 109) { } // ConPTY closes its output pipe.
                }
            });
            nuint size = 0;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            attributes = Marshal.AllocHGlobal(checked((int)size));
            Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref size), "Initialize process attributes");
            Check(UpdateProcThreadAttribute(attributes, 0, (IntPtr)0x20016, console,
                (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero), "Attach pseudoconsole");
            var startup = new StartupInfoEx { StartupInfo = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>() }, Attributes = attributes };
            Environment.SetEnvironmentVariable("USERPROFILE", directory);
            Environment.SetEnvironmentVariable("HOME", directory);
            Environment.SetEnvironmentVariable("ZIGSTORY_TUI_PROFILE", report);
            Environment.SetEnvironmentVariable("ZIGSTORY_TUI_LAUNCH_NS",
                ((decimal)Stopwatch.GetTimestamp() * 1_000_000_000 / Stopwatch.Frequency).ToString("F0", System.Globalization.CultureInfo.InvariantCulture));
            // The child opens read/write console handles explicitly, rather than
            // inheriting a redirected test host's pipe handles.
            var host = Environment.ProcessPath!;
            var arguments = Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase)
                ? $"\"{typeof(TerminalChecks).Assembly.Location}\" " : "";
            Check(CreateProcess(host, new StringBuilder($"\"{host}\" {arguments}--terminal-child \"{Path.GetFullPath(executable)}\""),
                IntPtr.Zero, IntPtr.Zero, false, 0x80000, IntPtr.Zero, directory, ref startup, out process), "Launch TUI");
            foreach (var (key, value) in saved) Environment.SetEnvironmentVariable(key, value);
            var timeout = Stopwatch.StartNew();
            while (!File.Exists(report) && timeout.Elapsed < TimeSpan.FromSeconds(15))
            {
                if (WaitForSingleObject(process.Process, 10) == 0)
                {
                    lock (transcript) throw new InvalidOperationException($"TUI exited before its first frame: {transcript}");
                }
                Thread.Sleep(10);
            }
            if (!File.Exists(report)) throw new TimeoutException("TUI did not flush its first frame.");
            // Exercise a query redraw, then quit without selecting/copying a command.
            input.Write(Encoding.UTF8.GetBytes("match"));
            input.Flush();
            Thread.Sleep(250);
            input.WriteByte(3);
            input.Flush();
            if (WaitForSingleObject(process.Process, 10000) != 0) throw new TimeoutException("TUI did not exit.");
            Check(GetExitCodeProcess(process.Process, out var exitCode), "Read TUI exit code");
            if (exitCode != 0) throw new InvalidOperationException($"TUI failed with exit code {exitCode}.");
            using var json = JsonDocument.Parse(File.ReadAllText(report));
            var root = json.RootElement;
            if (root.GetProperty("frame_count").GetInt32() < 2 ||
                root.GetProperty("cols").GetInt32() != 100 || root.GetProperty("rows").GetInt32() != 30 ||
                root.GetProperty("launch_to_first_frame_ms").GetDouble() <= 0 ||
                root.GetProperty("first_frame_write_ms").GetDouble() < 0 ||
                Interlocked.Read(ref bytes) == 0)
                throw new InvalidOperationException("Terminal timing/output assertions failed.");
            Console.WriteLine(root.GetRawText());
            Console.WriteLine("PASS ConPTY first frame, query redraw, actual tty writes and clean cancellation.");
            Console.WriteLine("ConPTY exercises real Windows console I/O; it does not measure Windows Terminal/WezTerm display composition.");
        }
        finally
        {
            foreach (var (key, value) in saved) Environment.SetEnvironmentVariable(key, value);
            if (process.Process != IntPtr.Zero && WaitForSingleObject(process.Process, 0) != 0)
            {
                using var running = Process.GetProcessById(checked((int)process.Id));
                running.Kill(entireProcessTree: true);
                running.WaitForExit();
            }
            input?.Dispose();
            if (console != IntPtr.Zero) ClosePseudoConsole(console);
            drain?.GetAwaiter().GetResult();
            if (attributes != IntPtr.Zero) { DeleteProcThreadAttributeList(attributes); Marshal.FreeHGlobal(attributes); }
            foreach (var handle in new[] { inputRead, inputWrite, outputRead, outputWrite, process.Thread, process.Process })
                if (handle != IntPtr.Zero) CloseHandle(handle);
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void Check(bool success, string operation)
    {
        if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    [StructLayout(LayoutKind.Sequential)] private struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, ReservedSize;
        public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo StartupInfo; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public uint Id, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes { public int Size; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFile(string name, uint access, uint sharing, ref SecurityAttributes attributes, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out IntPtr read, out IntPtr write, IntPtr attributes, uint size);
    [DllImport("kernel32.dll")] private static extern int CreatePseudoConsole(Coord size, IntPtr input, IntPtr output, uint flags, out IntPtr console);
    [DllImport("kernel32.dll")] private static extern void ClosePseudoConsole(IntPtr console);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref nuint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, nuint size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
}
