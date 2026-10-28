using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace zigstoryPredictor;

public enum DiagnosticLevel { Error, Warning, Info, Debug, Off }

public static class DiagnosticLog
{
    private static readonly object Gate = new();

    public static void Write(DiagnosticLevel level, string eventName, string? code = null)
    {
        var configured = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_LEVEL");
        var threshold = DiagnosticLevel.Error;
        if (configured is not null &&
            (!Enum.GetNames<DiagnosticLevel>().Contains(configured, StringComparer.OrdinalIgnoreCase) ||
             !Enum.TryParse(configured, true, out threshold)))
        {
            Trace.TraceError("Invalid ZIGSTORY_LOG_LEVEL; using Error.");
            threshold = DiagnosticLevel.Error;
        }
        if (threshold == DiagnosticLevel.Off || level > threshold) return;
        // Call sites pass fixed identifiers and exception types/codes, not exception messages.
        if (!IsIdentifier(eventName) || (code is not null && !IsIdentifier(code)))
            throw new ArgumentException("Log events/codes must be identifiers, not command text.");
        if (OperatingSystem.IsMacOS())
        {
            Trace.TraceError("Zigstory file logging requires Windows or Linux.");
            return;
        }
        try
        {
            lock (Gate)
            {
                var directory = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_DIR") ??
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".zigstory", "logs");
                Directory.CreateDirectory(directory);
                using var processLock = new FileStream(Path.Combine(directory, "predictor.lock"),
                    FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite);
                var acquired = false;
                for (var attempt = 0; attempt < 100; attempt++)
                {
                    try { processLock.Lock(0, 1); acquired = true; break; }
                    catch (IOException) when (attempt < 99) { Thread.Sleep(10); }
                }
                if (!acquired) throw new IOException("Log lock timeout.");
                try
                {
                    var path = Path.Combine(directory, "predictor.log");
                    var line = JsonSerializer.Serialize(new
                    {
                        timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                        level = level.ToString(),
                        component = "predictor",
                        @event = eventName,
                        code
                    }) + "\n";
                    var bytes = Encoding.UTF8.GetBytes(line);
                    if (File.Exists(path) && new FileInfo(path).Length + bytes.Length > 1024 * 1024)
                        File.Move(path, path + ".1", overwrite: true);
                    using var file = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
                    file.Write(bytes);
                }
                finally { processLock.Unlock(0, 1); }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            Trace.TraceError("Zigstory logging failed: {0}", ex.GetType().Name);
        }
    }

    private static bool IsIdentifier(string value) =>
        value.Length is > 0 and <= 128 &&
        value.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.' or '-');
}
