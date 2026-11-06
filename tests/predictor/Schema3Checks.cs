using System.Diagnostics;
using System.Management.Automation.Subsystem.Prediction;
using Microsoft.Data.Sqlite;
using zigstoryPredictor;

internal static class Schema3Checks
{
    public static void Run(string executable)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"zigstory_schema3_{Guid.NewGuid():N}");
        var history = Path.Combine(directory, ".zigstory");
        Directory.CreateDirectory(history);
        var path = Path.Combine(history, "history.db");
        var savedLog = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_DIR");
        try
        {
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", Path.Combine(directory, "logs"));
            using var writer = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
            writer.Open();
            Execute(writer, """
                PRAGMA journal_mode=WAL;
                CREATE TABLE history(id INTEGER PRIMARY KEY AUTOINCREMENT,cmd TEXT NOT NULL,cwd TEXT NOT NULL,
                  exit_code INTEGER,duration_ms INTEGER,session_id TEXT,hostname TEXT,timestamp INTEGER,
                  cmd_hash TEXT,event_id TEXT,rank REAL DEFAULT 0);
                CREATE INDEX idx_cmd_prefix ON history(cmd COLLATE NOCASE);
                CREATE INDEX idx_rank ON history(rank DESC,timestamp DESC);
                INSERT INTO history(cmd,cwd,exit_code,duration_ms,session_id,hostname,timestamp,event_id,rank)
                  VALUES('git old','local',0,1,'s','h',0,'old',1000);
                PRAGMA user_version=2;
                """);
            using (var command = writer.CreateCommand())
            {
                command.CommandText = "INSERT INTO history(cmd,cwd,timestamp,event_id,rank) VALUES('git recent','local',@now,'recent',1)";
                command.Parameters.AddWithValue("@now", DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                command.ExecuteNonQuery();
            }
            using var predictor = new ZigstoryPredictor(path);
            Require(Text(predictor, "git")[0] == "git old", "Predictor reads schema 2 during the transition");
            RunCli(executable, directory, "perf", "--cwd", "unknown", "--format", "json");
            Require(Scalar(writer, "PRAGMA user_version") == 3, "Actual CLI atomically migrates the fixture to schema 3");
            Require(Text(predictor, "git")[0] == "git recent", "Live predictor detects migration and ranks normalized commands by decayed score");
            Require(Scalar(writer, "SELECT COUNT(*) FROM history_events") == 2 &&
                Scalar(writer, "SELECT COUNT(*) FROM commands") == 2, "Migration preserves both executions and exact command identities");
            RunCli(executable, directory, "add", "--cmd", "git newest", "--cwd", "local");
            Require(Text(predictor, "git")[0] == "git newest", "Committed schema-3 writes invalidate cached suggestions");
            foreach (var text in new[] { "a% literal", "a_ literal", @"C:\tools\run" })
                RunCli(executable, directory, "add", "--cmd", text, "--cwd", "local");
            Require(Text(predictor, "a%").SequenceEqual(["a% literal"]) &&
                Text(predictor, "a_").SequenceEqual(["a_ literal"]) &&
                Text(predictor, @"C:\").SequenceEqual([@"C:\tools\run"]), "Schema-3 predictor preserves literal wildcard and path matching");
            Execute(writer, "UPDATE catalog_metadata SET half_life_seconds=1");
            Require(Text(predictor, "git").Length == 0, "Predictor refuses mismatched ranking policy instead of returning stale cached results");
            Execute(writer, "UPDATE catalog_metadata SET half_life_seconds=2592000; PRAGMA user_version=4");
            Require(Text(predictor, "git").Length == 0, "Predictor refuses future schemas without writing or downgrading");
            Require(Scalar(writer, "PRAGMA user_version") == 4, "Unsupported predictor requests preserve the database version");
        }
        finally
        {
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", savedLog);
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string[] Text(ZigstoryPredictor predictor, string input) =>
        predictor.GetSuggestion(new PredictionClient("schema3", PredictionClientKind.Terminal), PredictionContext.Create(input), default)
            .SuggestionEntries?.Select(item => item.SuggestionText).ToArray() ?? [];

    private static void Execute(SqliteConnection connection, string sql)
    {
        using var command = new SqliteCommand(sql, connection);
        command.ExecuteNonQuery();
    }

    private static long Scalar(SqliteConnection connection, string sql)
    {
        using var command = new SqliteCommand(sql, connection);
        return (long)command.ExecuteScalar()!;
    }

    private static void RunCli(string executable, string home, params string[] arguments)
    {
        var info = new ProcessStartInfo(Path.GetFullPath(executable))
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        info.Environment["USERPROFILE"] = home;
        info.Environment["HOME"] = home;
        info.Environment["ZIGSTORY_LOG_LEVEL"] = "Off";
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info)!;
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(15000)) { process.Kill(entireProcessTree: true); throw new TimeoutException("Schema test CLI timed out."); }
        Task.WhenAll(stdout, stderr).GetAwaiter().GetResult();
        if (process.ExitCode != 0) throw new InvalidOperationException($"Schema test CLI failed: {stdout.Result}{stderr.Result}");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
        Console.WriteLine($"PASS {message}");
    }
}
