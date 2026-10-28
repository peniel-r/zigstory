using System.Diagnostics;
using System.Text.Json;
using Microsoft.Data.Sqlite;

internal static class PerformanceChecks
{
    public static void Run(string executable, string tuiProfiler, string searchBenchmark)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_performance_{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "synthetic.db");
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = path, Pooling = false
            }.ToString()))
            {
                connection.Open();
                using var command = connection.CreateCommand();
                command.CommandText = """
                    CREATE TABLE history(id INTEGER PRIMARY KEY,cmd TEXT,cwd TEXT,
                      exit_code INTEGER,duration_ms INTEGER,timestamp INTEGER,rank REAL);
                    WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i < 100000)
                    INSERT INTO history SELECT i,printf('cmd %06d',i % 25000),
                      CASE WHEN i % 2=0 THEN 'local' ELSE 'other' END,0,i % 5000,i % 70000,i % 1000 FROM n;
                    CREATE INDEX idx_history_time ON history(timestamp DESC,id DESC);
                    CREATE INDEX idx_history_cwd_time ON history(cwd,timestamp DESC,id DESC);
                    CREATE INDEX idx_cmd_prefix ON history(cmd COLLATE NOCASE);
                    CREATE INDEX idx_rank ON history(rank DESC,timestamp DESC);
                    PRAGMA user_version=2;
                    """;
                command.ExecuteNonQuery();
            }
            using var profile = JsonDocument.Parse(HistoryProfiler.Run(path, executable, tuiProfiler));
            var root = profile.RootElement;
            Require(root.GetProperty("history_rows").GetInt64() == 100000, "100k-row profile fixture");
            Below(root, "cli_startup_and_empty_perf", "p95_ms", 1000);
            Below(root, "prediction_connection_cold", "p95_ms", 50);
            Below(root, "prediction_cached", "p95_ms", 10);
            Below(root, "tui_data_path", "headless_frame_p95_ms", 50);
            var tui = root.GetProperty("tui_data_path");
            Require(tui.GetProperty("max_rows_loaded").GetInt32() <= 237, "bounded TUI rows");
            Require(tui.GetProperty("peak_result_arena_bytes").GetInt64() < 1024 * 1024, "result arena under 1 MiB");
            Require(tui.GetProperty("second_half_peak_bytes").GetInt64() <=
                tui.GetProperty("first_half_peak_bytes").GetInt64(), "no retained-result growth after warmup");
            var memory = root.GetProperty("tui_process_sampled_peak_working_set_bytes");
            Require(memory.ValueKind == JsonValueKind.Number && memory.GetInt64() < 128 * 1024 * 1024,
                "sampled TUI working set under 128 MiB");

            var searchOutput = RunBenchmark(searchBenchmark);
            Console.WriteLine(searchOutput);
            using var search = JsonDocument.Parse(searchOutput);
            var result = search.RootElement;
            Require(result.GetProperty("rows").GetInt32() == 100000 &&
                result.GetProperty("unique_matches").GetInt32() == 25000, "substring fixture/count correctness");
            Require(result.GetProperty("initial_p95_ms").GetDouble() < 100, "substring initial p95 under 100 ms");
            Require(result.GetProperty("deep_page_p95_ms").GetDouble() < 10, "cached deep-page p95 under 10 ms");
            Require(result.GetProperty("sqlite_peak_bytes").GetInt64() is > 0 and < 64 * 1024 * 1024,
                "SQLite fixture/cache peak under 64 MiB");
            Console.WriteLine("Performance budgets passed (warm synthetic data; not universal latency promises).");
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, recursive: true);
        }
    }

    private static void Below(JsonElement root, string group, string field, double budget)
    {
        var value = root.GetProperty(group).GetProperty(field).GetDouble();
        Require(double.IsFinite(value) && value < budget, $"{group}.{field} below {budget} ms (actual {value:F3})");
    }

    private static void Require(bool condition, string label)
    {
        if (!condition) throw new InvalidOperationException($"Performance regression: {label}");
        Console.WriteLine($"PASS {label}");
    }

    private static string RunBenchmark(string executable)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo(Path.GetFullPath(executable))
            {
                UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true
            }
        };
        if (!process.Start()) throw new InvalidOperationException("Benchmark failed to start.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(60000))
        {
            process.Kill(entireProcessTree: true);
            process.WaitForExit();
            throw new TimeoutException("Substring benchmark exceeded 60 seconds.");
        }
        if (process.ExitCode != 0) throw new InvalidOperationException(error.GetAwaiter().GetResult());
        return output.GetAwaiter().GetResult();
    }
}
