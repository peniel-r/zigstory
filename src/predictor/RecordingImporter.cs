using System.Diagnostics;
using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("PredictorRegressionTests")]

namespace zigstoryPredictor;

/// <summary>A per-event launch and completion handle; no PowerShell code runs on the worker.</summary>
public sealed class RecordingImport
{
    internal readonly TaskCompletionSource<bool> LaunchSource = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<bool> Launched => LaunchSource.Task;
    public Task<RecordingImportResult> Completion { get; internal set; } = null!;
}

public sealed record RecordingImportResult(bool Success, int? ExitCode, string? ErrorCode);

/// <summary>
/// Immediately schedules one importer per durable event. Only process creation
/// moves off the prompt; there is no batching, timer or persistent writer.
/// </summary>
public static class RecordingImporter
{
    private static readonly object Gate = new();
    private static readonly HashSet<Task<bool>> PendingLaunches = [];

    public static RecordingImport Start(string executable, string payload) =>
        StartWithLauncher(executable, payload, info => Process.Start(info) ?? throw new InvalidOperationException("Importer did not start."));

    internal static RecordingImport StartWithLauncher(string executable, string payload, Func<ProcessStartInfo, Process> launch)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        ArgumentException.ThrowIfNullOrWhiteSpace(payload);
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Environment.CurrentDirectory
        };
        foreach (var argument in new[] { "import", "--file", payload, "--consume" }) info.ArgumentList.Add(argument);
        // ProcessStartInfo reads the environment lazily. Freeze it now, not after
        // the shell has changed directory/environment or begun another command.
        _ = info.Environment.Count;
        var operation = new RecordingImport();
        lock (Gate) PendingLaunches.Add(operation.Launched);
        operation.Completion = Task.Run(async () =>
        {
            try
            {
                using var process = launch(info);
                // Drain both streams without retaining command text/error output.
                var stdout = Drain(process.StandardOutput);
                var stderr = Drain(process.StandardError);
                operation.LaunchSource.TrySetResult(true);
                lock (Gate) PendingLaunches.Remove(operation.Launched);
                await process.WaitForExitAsync().ConfigureAwait(false);
                await Task.WhenAll(stdout, stderr).ConfigureAwait(false);
                var success = process.ExitCode == 0 && !File.Exists(payload);
                var code = success ? null : $"Exit_{process.ExitCode}";
                if (!success) PersistFailure(payload, "recording_import_failed", code!);
                return new RecordingImportResult(success, process.ExitCode, code);
            }
            catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException or NotSupportedException)
            {
                var code = ex.GetType().Name;
                PersistFailure(payload, "recording_launch_or_wait_failed", code);
                return new RecordingImportResult(false, null, code);
            }
            finally
            {
                // A failed launch is signaled only after its durable diagnostic
                // is attempted, so normal exit cannot race that diagnostic.
                operation.LaunchSource.TrySetResult(false);
                lock (Gate) PendingLaunches.Remove(operation.Launched);
            }
        });
        return operation;
    }

    /// <summary>Normal shell exit waits for process creation only; importers finish independently.</summary>
    public static bool WaitForPendingLaunches(int timeoutMilliseconds = 10000)
    {
        Task[] pending;
        lock (Gate) pending = PendingLaunches.Cast<Task>().ToArray();
        return Task.WaitAll(pending, timeoutMilliseconds);
    }

    private static async Task Drain(StreamReader reader)
    {
        var buffer = new char[4096];
        while (await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false) > 0) { }
    }

    private static void PersistFailure(string payload, string eventName, string code)
    {
        try
        {
            // Preserve the Zig importer's more specific diagnostic when present.
            using var file = new FileStream(payload + ".error", FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            using var writer = new StreamWriter(file);
            writer.Write($"{eventName}: {code}. Payload retained; retry after resolving the error.");
        }
        catch (IOException) when (File.Exists(payload + ".error")) { }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            Trace.TraceError("Zigstory recording diagnostic failed: {0}", ex.GetType().Name);
        }
        DiagnosticLog.Write(DiagnosticLevel.Error, eventName, code);
    }
}
