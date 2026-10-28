using System.Diagnostics;
using System.Management.Automation.Subsystem.Prediction;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using zigstoryPredictor;

internal static class HistoryProfiler
{
    public static string Run(string sourcePath, string executable, string tuiProfiler)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_profile_{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var home = Path.Combine(directory, "home");
            Directory.CreateDirectory(Path.Combine(home, ".zigstory"));
            var snapshot = Path.Combine(home, ".zigstory", "history.db");
            using (var source = Open(sourcePath, SqliteOpenMode.ReadOnly))
            using (var destination = Open(snapshot, SqliteOpenMode.ReadWriteCreate))
            {
                source.BackupDatabase(destination);
            }

            var missingDirectory = $"__zigstory_profile_{Guid.NewGuid():N}";
            var cliArgs = new[] { "perf", "--cwd", missingDirectory, "--format", "json" };
            // Migrate only the disposable snapshot, never the source history.
            RunProcess(executable, cliArgs, home);
            var startup = Measure(21, () => RunProcess(executable, cliArgs, home));
            var helpStartup = Measure(21, () => RunProcess(executable, ["help"], home));
            var probe = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(tuiProfiler))!, "zigstory-startup-probe.exe");
            var probeSamples = Enumerable.Range(0, 21).Select(_ => RunProcess(probe, [], home)).ToArray();
            var phaseProfiler = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(tuiProfiler))!, "zigstory-startup-profile.exe");
            var phaseSamples = new List<Dictionary<string, double>>();
            for (var i = 0; i < 21; i++)
            {
                var phases = RunProcess(phaseProfiler, [snapshot], home);
                using var phaseJson = JsonDocument.Parse(phases.Output);
                phaseSamples.Add(phaseJson.RootElement.EnumerateObject()
                    .Where(p => p.Value.ValueKind == JsonValueKind.Number)
                    .ToDictionary(p => p.Name, p => p.Value.GetDouble()));
            }
            var phaseSummaries = phaseSamples[0].Keys.ToDictionary(key => key,
                key => Summary(phaseSamples.Select(sample => sample[key]).ToList()));
            long rows;
            var prefixes = new List<string>();
            using (var connection = Open(snapshot, SqliteOpenMode.ReadOnly))
            {
                using var count = connection.CreateCommand();
                count.CommandText = "SELECT COUNT(*) FROM history";
                rows = (long)count.ExecuteScalar()!;
                using var sample = connection.CreateCommand();
                sample.CommandText = """
                    SELECT substr(cmd,1,8) FROM history
                    WHERE length(trim(cmd)) >= 2
                    GROUP BY substr(cmd,1,8) ORDER BY COUNT(*) DESC LIMIT 20
                    """;
                using var reader = sample.ExecuteReader();
                while (reader.Read()) prefixes.Add(reader.GetString(0));
            }
            if (prefixes.Count == 0) throw new InvalidOperationException("History has no usable prediction prefixes.");
            var client = new PredictionClient("local-profile", PredictionClientKind.Terminal);
            var coldTimes = new List<double>();
            var cachedTimes = new List<double>();
            foreach (var prefix in prefixes)
            {
                var context = PredictionContext.Create(prefix);
                for (var i = 0; i < 3; i++)
                {
                    using var predictor = new ZigstoryPredictor(snapshot);
                    var elapsed = Stopwatch.StartNew();
                    predictor.GetSuggestion(client, context, CancellationToken.None);
                    coldTimes.Add(elapsed.Elapsed.TotalMilliseconds);
                }
                using var cached = new ZigstoryPredictor(snapshot);
                cached.GetSuggestion(client, context, CancellationToken.None);
                for (var i = 0; i < 21; i++)
                {
                    var elapsed = Stopwatch.StartNew();
                    cached.GetSuggestion(client, context, CancellationToken.None);
                    cachedTimes.Add(elapsed.Elapsed.TotalMilliseconds);
                }
            }
            var tui = RunProcess(tuiProfiler, [snapshot], home, sampleWorkingSet: true);
            using var tuiJson = JsonDocument.Parse(tui.Output);
            var report = JsonSerializer.Serialize(new
            {
                history_rows = rows,
                prefix_count = prefixes.Count,
                cli_startup_and_empty_perf = Summary(startup),
                cli_process_and_help = Summary(helpStartup),
                empty_native_process = new
                {
                    launch = Summary(probeSamples.Select(sample => sample.LaunchMs).ToList()),
                    wall = Summary(probeSamples.Select(sample => sample.WallMs).ToList()),
                    cpu = Summary(probeSamples.Select(sample => sample.CpuMs).ToList()),
                },
                startup_phases = phaseSummaries,
                prediction_connection_cold = Summary(coldTimes),
                prediction_cached = Summary(cachedTimes),
                tui_data_path = tuiJson.RootElement,
                tui_process_sampled_peak_working_set_bytes = tui.PeakWorkingSet,
                note = "Local read-only backup; command text and prefixes are never printed. Warm OS cache; CLI timings include process startup and empty-directory metrics. TUI includes paging and headless rendering, not terminal I/O/input thread.",
            }, new JsonSerializerOptions { WriteIndented = true });
            Console.WriteLine(report);
            return report;
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, recursive: true);
        }
    }

    private static SqliteConnection Open(string path, SqliteOpenMode mode)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = mode,
            Pooling = false,
        }.ToString());
        connection.Open();
        return connection;
    }

    private static (string Output, long? PeakWorkingSet, double LaunchMs, double WallMs, double CpuMs) RunProcess(
        string exe, string[] arguments, string home, bool sampleWorkingSet = false)
    {
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo(Path.GetFullPath(exe))
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        process.StartInfo.Environment["USERPROFILE"] = home;
        process.StartInfo.Environment["HOME"] = home;
        foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
        var lifetime = Stopwatch.StartNew();
        if (!process.Start()) throw new InvalidOperationException("Could not start profiling process.");
        var launchMs = lifetime.Elapsed.TotalMilliseconds;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        long? peakWorkingSet = null;
        var timeout = Stopwatch.StartNew();
        while (sampleWorkingSet && !process.WaitForExit(5) && timeout.Elapsed < TimeSpan.FromSeconds(30))
        {
            try
            {
                process.Refresh();
                peakWorkingSet = Math.Max(peakWorkingSet ?? 0, process.PeakWorkingSet64);
            }
            catch (InvalidOperationException) when (process.HasExited)
            {
                break;
            }
        }
        if (!process.WaitForExit(Math.Max(0, 30000 - (int)timeout.ElapsedMilliseconds)))
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
            throw new TimeoutException("Profiling process exceeded 30 seconds.");
        }
        var stderr = error.GetAwaiter().GetResult();
        if (process.ExitCode != 0) throw new InvalidOperationException($"Profiling process failed ({process.ExitCode}): {stderr}");
        return (output.GetAwaiter().GetResult(), peakWorkingSet, launchMs,
            lifetime.Elapsed.TotalMilliseconds, process.TotalProcessorTime.TotalMilliseconds);
    }

    private static List<double> Measure(int count, Action action)
    {
        for (var i = 0; i < 3; i++) action();
        var times = new List<double>(count);
        for (var i = 0; i < count; i++)
        {
            var elapsed = Stopwatch.StartNew();
            action();
            times.Add(elapsed.Elapsed.TotalMilliseconds);
        }
        return times;
    }

    private static object Summary(List<double> times)
    {
        times.Sort();
        return new { samples = times.Count, median_ms = times[times.Count / 2], p95_ms = times[(times.Count - 1) * 95 / 100] };
    }
}
