using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using zigstoryPredictor;

internal static class RecordingChecks
{
    public static async Task Benchmark(string executable)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_launch_profile_{Guid.NewGuid():N}");
        var pending = Path.Combine(directory, ".zigstory", "pending");
        Directory.CreateDirectory(pending);
        var savedHome = Environment.GetEnvironmentVariable("USERPROFILE");
        var savedUnixHome = Environment.GetEnvironmentVariable("HOME");
        var submissions = new List<double>();
        var launches = new List<double>();
        var completions = new List<double>();
        var directLaunches = new List<double>();
        try
        {
            Environment.SetEnvironmentVariable("USERPROFILE", directory);
            Environment.SetEnvironmentVariable("HOME", directory);
            // Warm the database/JIT paths; the first sample is excluded in both modes.
            for (var i = 0; i < 22; i++)
            {
                var path = Payload(pending);
                var clock = Stopwatch.StartNew();
                var operation = RecordingImporter.Start(executable, path);
                var submission = clock.Elapsed.TotalMilliseconds;
                Require(await operation.Launched.WaitAsync(TimeSpan.FromSeconds(15)), "Benchmark worker launched");
                var launch = clock.Elapsed.TotalMilliseconds;
                Require((await operation.Completion.WaitAsync(TimeSpan.FromSeconds(15))).Success, "Benchmark worker imported");
                if (i > 0)
                {
                    submissions.Add(submission);
                    launches.Add(launch);
                    completions.Add(clock.Elapsed.TotalMilliseconds);
                }

                path = Payload(pending);
                var info = new ProcessStartInfo(executable)
                {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardError = true, RedirectStandardOutput = true
                };
                foreach (var argument in new[] { "import", "--file", path, "--consume" }) info.ArgumentList.Add(argument);
                _ = info.Environment.Count;
                clock.Restart();
                using var process = Process.Start(info)!;
                if (i > 0) directLaunches.Add(clock.Elapsed.TotalMilliseconds);
                var stdout = process.StandardOutput.ReadToEndAsync();
                var stderr = process.StandardError.ReadToEndAsync();
                await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
                await Task.WhenAll(stdout, stderr);
                Require(process.ExitCode == 0 && !File.Exists(path), "Benchmark direct importer succeeded");
            }
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                samples = submissions.Count,
                worker_submission = Summary(submissions),
                worker_launch = Summary(launches),
                worker_import_complete = Summary(completions),
                direct_process_start = Summary(directLaunches),
                note = "Warm .NET helper and database; submission excludes payload serialization/write and PowerShell prompt logic. Each sample immediately imports one synthetic event. Launch and import completion are separate from prompt blocking."
            }));
        }
        finally
        {
            RecordingImporter.WaitForPendingLaunches();
            Environment.SetEnvironmentVariable("USERPROFILE", savedHome);
            Environment.SetEnvironmentVariable("HOME", savedUnixHome);
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string Payload(string directory)
    {
        var id = Guid.NewGuid().ToString();
        var path = Path.Combine(directory, id + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(new[] { new { cmd = "echo launch benchmark", cwd = "launch-benchmark", event_id = id } }));
        return path;
    }

    private static object Summary(List<double> values)
    {
        values.Sort();
        return new { median_ms = values[values.Count / 2], p95_ms = values[(int)Math.Ceiling(values.Count * 0.95) - 1] };
    }

    public static async Task Run(string directory)
    {
        var path = Path.Combine(directory, "launch blocked.json");
        File.WriteAllText(path, "[]");
        var saved = Environment.GetEnvironmentVariable("ZIGSTORY_RECORDING_SNAPSHOT_TEST");
        var savedLogs = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_DIR");
        var savedLevel = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_LEVEL");
        try
        {
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", Path.Combine(directory, "recording-logs"));
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_LEVEL", "Error");
            Environment.SetEnvironmentVariable("ZIGSTORY_RECORDING_SNAPSHOT_TEST", "before");
            using var started = new ManualResetEventSlim();
            using var release = new ManualResetEventSlim();
            string? capturedEnvironment = null;
            string[]? capturedArguments = null;
            var operation = RecordingImporter.StartWithLauncher("not-used.exe", path, info =>
            {
                started.Set();
                release.Wait();
                capturedEnvironment = info.Environment["ZIGSTORY_RECORDING_SNAPSHOT_TEST"];
                capturedArguments = info.ArgumentList.ToArray();
                throw new Win32Exception(2, "DO_NOT_PERSIST_THIS_SECRET");
            });
            try
            {
                Require(started.Wait(10000), "Worker begins process creation without a batching delay");
                Require(!operation.Launched.IsCompleted && !operation.Completion.IsCompleted,
                    "Submission returned while process creation was blocked");
                Require(!RecordingImporter.WaitForPendingLaunches(1), "Exit drain sees pending process creation");
                Environment.SetEnvironmentVariable("ZIGSTORY_RECORDING_SNAPSHOT_TEST", "after");
            }
            finally { release.Set(); }
            var result = await operation.Completion.WaitAsync(TimeSpan.FromSeconds(15));
            Require(!result.Success && !await operation.Launched, "Launch errors complete both operation handles");
            Require(capturedEnvironment == "before", "Launcher snapshots the request-time environment");
            Require(capturedArguments!.SequenceEqual(["import", "--file", path, "--consume"]), "Payload paths are passed as literal process arguments");
            Require(RecordingImporter.WaitForPendingLaunches(1000), "Finished launch is removed from the exit drain");
            Require(File.Exists(path) && File.Exists(path + ".error"), "Launch failures retain payloads and persistent diagnostics");
            Require(!File.ReadAllText(path + ".error").Contains("DO_NOT_PERSIST_THIS_SECRET") &&
                !File.ReadAllText(Path.Combine(directory, "recording-logs", "predictor.log")).Contains("DO_NOT_PERSIST_THIS_SECRET"),
                "Worker diagnostics contain exception types, not private messages");
        }
        finally
        {
            Environment.SetEnvironmentVariable("ZIGSTORY_RECORDING_SNAPSHOT_TEST", saved);
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", savedLogs);
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_LEVEL", savedLevel);
        }
    }

    private static void Require(bool success, string message)
    {
        if (!success) throw new InvalidOperationException(message);
        Console.WriteLine($"PASS {message}");
    }
}
