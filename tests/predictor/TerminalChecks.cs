using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

internal static class TerminalChecks
{
    /// <summary>
    /// Runs inside a pseudoconsole and launches the target with explicitly opened console
    /// handles, so it never inherits a redirected test host's pipe handles.
    /// </summary>
    public static int RunChild(string application, IReadOnlyList<string> arguments)
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
        var path = Path.GetFullPath(application);
        var commandLine = new StringBuilder(Quote(path));
        foreach (var argument in arguments) commandLine.Append(' ').Append(Quote(argument));
        Check(CreateProcess(path, commandLine, IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, Environment.CurrentDirectory, ref startup, out var process), "Launch console child");
        try
        {
            WaitForSingleObject(process.Process, uint.MaxValue);
            Check(GetExitCodeProcess(process.Process, out var exitCode), "Read child exit code");
            return checked((int)exitCode);
        }
        finally { CloseHandle(process.Thread); CloseHandle(process.Process); }
    }

    /// <summary>
    /// Reports the attached console's output code page as the process exit code,
    /// after optionally switching the console to <paramref name="codePage"/>.
    /// </summary>
    public static int ConsoleCodePage(string? codePage)
    {
        if (codePage is not null && !SetConsoleOutputCP(uint.Parse(codePage, System.Globalization.CultureInfo.InvariantCulture)))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Set console code page");
        return checked((int)GetConsoleOutputCP());
    }

    public static void Run(string executable)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("ConPTY checks require Windows.");
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_terminal_{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var saved = new[] { "USERPROFILE", "HOME", "ZIGSTORY_TUI_PROFILE", "ZIGSTORY_TUI_LAUNCH_NS" }
            .ToDictionary(key => key, Environment.GetEnvironmentVariable);
        try
        {
            Environment.SetEnvironmentVariable("USERPROFILE", directory);
            Environment.SetEnvironmentVariable("HOME", directory);
            CheckFirstFrameAndCancel(executable, directory);
            CheckSelectionFile(executable, directory);
            CheckUtf8Report(executable, directory);
            Console.WriteLine("ConPTY exercises real Windows console I/O; it does not measure Windows Terminal/WezTerm display composition.");
        }
        finally
        {
            foreach (var (key, value) in saved) Environment.SetEnvironmentVariable(key, value);
            Directory.Delete(directory, recursive: true);
        }
    }

    public static void RunIdleStop(string executable)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("ConPTY checks require Windows.");
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_idle_stop_{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            foreach (var arguments in new string[][] { [], ["--full-queue"] })
            {
                using var console = new PseudoConsoleSession(100, 30);
                var process = console.LaunchChild(directory, executable, arguments);
                var exitCode = console.WaitForExit(process, TimeSpan.FromSeconds(5));
                var transcript = console.CloseAndReadTranscript();
                if (exitCode != 0 || !transcript.Contains("ZS_IDLE_STOP_BEGIN") || !transcript.Contains("ZS_IDLE_STOP_END"))
                    throw new InvalidOperationException($"Idle reader shutdown failed: {transcript}");
                Console.WriteLine(arguments.Length == 0
                    ? "PASS Idle Windows console input reader stops without a key or terminal DSR response."
                    : "PASS Windows input producer stops while its event queue is full.");
            }
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static void CheckFirstFrameAndCancel(string executable, string directory)
    {
        var report = Path.Combine(directory, "terminal.json");
        Environment.SetEnvironmentVariable("ZIGSTORY_TUI_PROFILE", report);
        using var console = new PseudoConsoleSession(100, 30);
        var process = console.LaunchChild(directory, executable, ["search"]);
        WaitForFirstFrame(console, process, report);
        // Exercise a query redraw, then quit without selecting/copying a command.
        console.Write("match");
        Thread.Sleep(250);
        console.Write("\u0003");
        var exitCode = console.WaitForExit(process, TimeSpan.FromSeconds(10));
        if (exitCode != 0) throw new InvalidOperationException($"TUI failed with exit code {exitCode}.");
        using var json = JsonDocument.Parse(File.ReadAllText(report));
        var root = json.RootElement;
        if (root.GetProperty("frame_count").GetInt32() < 2 ||
            root.GetProperty("cols").GetInt32() != 100 || root.GetProperty("rows").GetInt32() != 30 ||
            root.GetProperty("launch_to_first_frame_ms").GetDouble() <= 0 ||
            root.GetProperty("first_frame_write_ms").GetDouble() < 0 ||
            console.Bytes == 0)
            throw new InvalidOperationException("Terminal timing/output assertions failed.");
        Console.WriteLine(root.GetRawText());
        Console.WriteLine("PASS ConPTY first frame, query redraw, actual tty writes and clean cancellation.");
    }

    private static void CheckSelectionFile(string executable, string directory)
    {
        const string command = "echo selected via conpty";
        RunHidden(executable, "add", "--cmd", command, "--cwd", @"C:\conpty");
        var report = Path.Combine(directory, "selection-frame.json");
        // A stale file with a space in its path: the TUI must replace the contents.
        var selection = Path.Combine(directory, "selection output.txt");
        File.WriteAllText(selection, "stale selection");
        Environment.SetEnvironmentVariable("ZIGSTORY_TUI_PROFILE", report);
        using var console = new PseudoConsoleSession(100, 30);
        var process = console.LaunchChild(directory, executable, ["search", "--output", selection]);
        WaitForFirstFrame(console, process, report);
        console.Write("selected via");
        Thread.Sleep(250);
        console.Write("\r");
        var exitCode = console.WaitForExit(process, TimeSpan.FromSeconds(10));
        if (exitCode != 0) throw new InvalidOperationException($"TUI failed with exit code {exitCode}.");
        var selected = File.ReadAllText(selection);
        if (selected != command) throw new InvalidOperationException($"Selection file contained '{selected}'.");
        Console.WriteLine("PASS ConPTY Enter writes the selected command to the requested file.");
    }

    private static void CheckUtf8Report(string executable, string directory)
    {
        const string command = "echo r\u00e9port \u2713";
        RunHidden(executable, "add", "--cmd", command, "--cwd", @"C:\conpty");
        Environment.SetEnvironmentVariable("ZIGSTORY_TUI_PROFILE", null);
        // The default console code page and an already-UTF-8 console.
        foreach (var initialCodePage in new string?[] { null, "65001" })
        {
            using var console = new PseudoConsoleSession(120, 60);
            var timeout = TimeSpan.FromSeconds(15);
            if (initialCodePage is not null)
                console.WaitForExit(console.LaunchHost(directory, ["--console-code-page", initialCodePage]), timeout);
            var before = console.WaitForExit(console.LaunchHost(directory, ["--console-code-page"]), timeout);
            var exitCode = console.WaitForExit(console.LaunchChild(directory, executable, ["stats"]), timeout);
            var after = console.WaitForExit(console.LaunchHost(directory, ["--console-code-page"]), timeout);
            if (exitCode != 0) throw new InvalidOperationException($"stats failed with exit code {exitCode}.");
            if (after != before) throw new InvalidOperationException($"stats changed the console code page from {before} to {after}.");
            var transcript = console.CloseAndReadTranscript();
            if (!transcript.Contains("OVERVIEW") || !transcript.Contains('\u2588') || !transcript.Contains("r\u00e9port") ||
                transcript.Contains('\uFFFD'))
                throw new InvalidOperationException($"Report text did not render as UTF-8 on code page {before}: {transcript}");
            Console.WriteLine($"PASS ConPTY report renders UTF-8 text and bars on code page {before} and restores it.");
        }
    }

    private static void WaitForFirstFrame(PseudoConsoleSession console, ProcessInfo process, string report)
    {
        var timeout = Stopwatch.StartNew();
        while (!File.Exists(report) && timeout.Elapsed < TimeSpan.FromSeconds(15))
        {
            if (console.HasExited(process))
                throw new InvalidOperationException($"TUI exited before its first frame: {console.Transcript}");
            Thread.Sleep(10);
        }
        if (!File.Exists(report)) throw new TimeoutException("TUI did not flush its first frame.");
    }

    private static void RunHidden(string executable, params string[] arguments)
    {
        var start = new ProcessStartInfo(Path.GetFullPath(executable))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(15000)) throw new TimeoutException($"zigstory {arguments[0]} did not exit.");
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"zigstory {arguments[0]} failed: {output.Result}{error.Result}");
    }

    // Windows command-line quoting, matching how CommandLineToArgvW parses arguments.
    private static string Quote(string argument)
    {
        if (argument.Length > 0 && argument.IndexOfAny([' ', '\t', '\n', '\v', '"']) < 0) return argument;
        var quoted = new StringBuilder("\"");
        var backslashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\') { backslashes++; continue; }
            quoted.Append('\\', c == '"' ? backslashes * 2 + 1 : backslashes).Append(c);
            backslashes = 0;
        }
        return quoted.Append('\\', backslashes * 2).Append('"').ToString();
    }

    private static void Check(bool success, string operation)
    {
        if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    /// <summary>An isolated pseudoconsole that drains its output into a transcript.</summary>
    private sealed class PseudoConsoleSession : IDisposable
    {
        private readonly IntPtr _console;
        private readonly IntPtr _attributes;
        private readonly FileStream _input;
        private readonly Task _drain;
        private readonly StringBuilder _transcript = new();
        private readonly List<ProcessInfo> _processes = [];
        private long _bytes;
        private bool _closed;

        public PseudoConsoleSession(short columns, short rows)
        {
            Check(CreatePipe(out var inputRead, out var inputWrite, IntPtr.Zero, 0), "Create input pipe");
            Check(CreatePipe(out var outputRead, out var outputWrite, IntPtr.Zero, 0), "Create output pipe");
            var hr = CreatePseudoConsole(new Coord { X = columns, Y = rows }, inputRead, outputWrite, 0, out _console);
            CloseHandle(inputRead);
            CloseHandle(outputWrite);
            _input = new FileStream(new SafeFileHandle(inputWrite, ownsHandle: true), FileAccess.Write);
            var output = new FileStream(new SafeFileHandle(outputRead, ownsHandle: true), FileAccess.Read);
            if (hr != 0)
            {
                _input.Dispose();
                output.Dispose();
                Marshal.ThrowExceptionForHR(hr);
            }
            _drain = Task.Run(() => Drain(output));
            nuint size = 0;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            _attributes = Marshal.AllocHGlobal(checked((int)size));
            Check(InitializeProcThreadAttributeList(_attributes, 1, 0, ref size), "Initialize process attributes");
            Check(UpdateProcThreadAttribute(_attributes, 0, (IntPtr)0x20016, _console,
                (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero), "Attach pseudoconsole");
        }

        public long Bytes => Interlocked.Read(ref _bytes);

        public string Transcript
        {
            get { lock (_transcript) return _transcript.ToString(); }
        }

        /// <summary>Launches the target through --terminal-child inside this pseudoconsole.</summary>
        public ProcessInfo LaunchChild(string directory, string executable, IReadOnlyList<string> arguments) =>
            LaunchHost(directory, ["--terminal-child", Path.GetFullPath(executable), .. arguments]);

        /// <summary>Launches this test host inside the pseudoconsole with the given arguments.</summary>
        public ProcessInfo LaunchHost(string directory, IReadOnlyList<string> arguments)
        {
            var host = Environment.ProcessPath!;
            var commandLine = new StringBuilder(Quote(host));
            if (Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                commandLine.Append(' ').Append(Quote(typeof(TerminalChecks).Assembly.Location));
            foreach (var argument in arguments) commandLine.Append(' ').Append(Quote(argument));
            var startup = new StartupInfoEx { StartupInfo = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>() }, Attributes = _attributes };
            Check(CreateProcess(host, commandLine, IntPtr.Zero, IntPtr.Zero, false, 0x80000, IntPtr.Zero, directory, ref startup, out var process), "Launch pseudoconsole process");
            _processes.Add(process);
            return process;
        }

        public void Write(string text)
        {
            _input.Write(Encoding.UTF8.GetBytes(text));
            _input.Flush();
        }

        public bool HasExited(ProcessInfo process) => WaitForSingleObject(process.Process, 0) == 0;

        public uint WaitForExit(ProcessInfo process, TimeSpan timeout)
        {
            if (WaitForSingleObject(process.Process, checked((uint)timeout.TotalMilliseconds)) != 0)
                throw new TimeoutException($"Pseudoconsole process did not exit. Isolated fixture output: {Transcript}");
            Check(GetExitCodeProcess(process.Process, out var exitCode), "Read exit code");
            return exitCode;
        }

        /// <summary>Closes the pseudoconsole and returns everything it rendered.</summary>
        public string CloseAndReadTranscript()
        {
            Close();
            return Transcript;
        }

        public void Dispose()
        {
            Close();
            DeleteProcThreadAttributeList(_attributes);
            Marshal.FreeHGlobal(_attributes);
            foreach (var process in _processes)
            {
                CloseHandle(process.Thread);
                CloseHandle(process.Process);
            }
        }

        private void Close()
        {
            if (_closed) return;
            _closed = true;
            foreach (var process in _processes)
            {
                if (HasExited(process)) continue;
                using var running = Process.GetProcessById(checked((int)process.Id));
                running.Kill(entireProcessTree: true);
                running.WaitForExit();
            }
            _input.Dispose();
            ClosePseudoConsole(_console);
            _drain.GetAwaiter().GetResult();
        }

        private void Drain(FileStream output)
        {
            using (output)
            {
                var buffer = new byte[8192];
                try
                {
                    int count;
                    while ((count = output.Read(buffer)) > 0)
                    {
                        Interlocked.Add(ref _bytes, count);
                        lock (_transcript) if (_transcript.Length < 65536) _transcript.Append(Encoding.UTF8.GetString(buffer, 0, count));
                    }
                }
                catch (IOException ex) when ((ex.HResult & 0xFFFF) == 109) { } // ConPTY closes its output pipe.
            }
        }
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
    [DllImport("kernel32.dll")] private static extern uint GetConsoleOutputCP();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetConsoleOutputCP(uint codePage);
}
