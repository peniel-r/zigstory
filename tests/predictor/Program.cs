using System.Diagnostics;
using System.Management.Automation.Subsystem.Prediction;
using Microsoft.Data.Sqlite;
using zigstoryPredictor;

if (args.Length > 0 && args[0] == "--profile")
{
    if (args.Length != 4) throw new ArgumentException("Usage: --profile <history.db> <zigstory.exe> <zigstory-tui-profile.exe>");
    HistoryProfiler.Run(args[1], args[2], args[3]);
    return;
}

var directory = Path.Combine(Path.GetTempPath(), $"zigstory_predictor_{Guid.NewGuid():N}");
Directory.CreateDirectory(directory);
try
{
    var savedLogDirectory = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_DIR");
    var savedLogLevel = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_LEVEL");
    try
    {
        var logs = Path.Combine(directory, "logs");
        Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", logs);
        Environment.SetEnvironmentVariable("ZIGSTORY_LOG_LEVEL", null);
        DiagnosticLog.Write(DiagnosticLevel.Warning, "not_persisted");
        Check(!Directory.Exists(logs), "Predictor logs only Error entries by default");
        DiagnosticLog.Write(DiagnosticLevel.Error, "test_error", "TestError");
        var logPath = Path.Combine(logs, "predictor.log");
        Check(File.ReadAllText(logPath).Contains("\"level\":\"Error\""), "Predictor persists structured Error entries");
        File.WriteAllText(logPath, new string('x', 1024 * 1024));
        DiagnosticLog.Write(DiagnosticLevel.Error, "rotate");
        Check(File.Exists(logPath + ".1") && new FileInfo(logPath).Length < 1024 * 1024, "Predictor log rotation is bounded");
        Environment.SetEnvironmentVariable("ZIGSTORY_LOG_LEVEL", "Off");
        var before = File.ReadAllText(logPath);
        DiagnosticLog.Write(DiagnosticLevel.Error, "disabled");
        Check(File.ReadAllText(logPath) == before, "Predictor honors Off");
    }
    finally
    {
        Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", savedLogDirectory);
        Environment.SetEnvironmentVariable("ZIGSTORY_LOG_LEVEL", savedLogLevel);
    }
    var path = Path.Combine(directory, "history;test.db");
    using var writer = OpenDatabase(path);
    Execute(writer, """
        CREATE TABLE history (id INTEGER PRIMARY KEY, cmd TEXT, rank REAL, timestamp INTEGER);
        CREATE INDEX idx_cmd_prefix ON history(cmd COLLATE NOCASE);
        CREATE INDEX idx_rank ON history(rank DESC, timestamp DESC);
        INSERT INTO history VALUES
          (1,'git status',10,1),(2,'git log',20,2),(3,'echo hello',1,3),
          (4,'a% literal',1,4),(5,'a_ literal',1,5),(6,'abc',100,6),
          (7,'C:\tools\run',1,7);
        """);
    using var predictor = new ZigstoryPredictor(path);
    Check(Get(predictor, "g").SuggestionEntries is null, "Short input avoids prediction queries");
    var first = Get(predictor, "git");
    Check(Text(first).SequenceEqual(["git log", "git status"]), "Predictions preserve frecency ordering");
    Get(predictor, "echo");
    Check(Text(first).SequenceEqual(["git log", "git status"]), "Returned suggestion packages retain their contents");
    Check(Text(Get(predictor, "a%")).SequenceEqual(["a% literal"]), "Percent signs match literally");
    Check(Text(Get(predictor, "a_")).SequenceEqual(["a_ literal"]), "Underscores match literally");
    Check(Text(Get(predictor, @"C:\")).SequenceEqual([@"C:\tools\run"]), "Backslashes match literally");
    Execute(writer, "INSERT INTO history VALUES (8,'git newest',100,8)");
    Check(Text(Get(predictor, "git"))[0] == "git newest", "Committed writes invalidate positive cache entries");
    Execute(writer, "UPDATE history SET rank = 200 WHERE cmd = 'git status'");
    Check(Text(Get(predictor, "git"))[0] == "git status", "Committed rank changes invalidate cached ordering");
    Check(Text(Get(predictor, "zz")).Length == 0, "Empty results are supported");
    Execute(writer, "INSERT INTO history VALUES (9,'zz new',100,9)");
    Check(Text(Get(predictor, "zz")).SequenceEqual(["zz new"]), "Committed writes invalidate empty cache entries");
    using (var cancellation = new CancellationTokenSource())
    {
        cancellation.Cancel();
        Check(Text(Get(predictor, "git", cancellation.Token)).Length == 0, "Cancelled requests do not return cached suggestions");
    }
    var concurrent = await Task.WhenAll(Enumerable.Range(0, 20).Select(i => Task.Run(() =>
        Text(Get(predictor, i % 2 == 0 ? "git" : "echo")).Length > 0)));
    Check(concurrent.All(success => success), "Concurrent predictions complete without pool exhaustion");

    var slowPath = Path.Combine(directory, "slow.db");
    using (var slowWriter = OpenDatabase(slowPath))
    using (var slowPredictor = new ZigstoryPredictor(slowPath))
    {
        Execute(slowWriter, """
            CREATE VIEW history AS
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i < 1000000)
            SELECT printf('git %07d',i) AS cmd, i AS rank, i AS timestamp FROM n;
            """);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(30));
        var elapsed = Stopwatch.StartNew();
        Check(Text(Get(slowPredictor, "git", cancellation.Token)).Length == 0, "In-flight SQLite work is cancelled");
        Check(elapsed.Elapsed < TimeSpan.FromSeconds(1), "Cancellation interrupts expensive SQLite queries promptly");
        Check(Text(Get(slowPredictor, "git")).Length == 5, "Cancelled results are not cached and the connection remains usable");
    }
    using (var missing = new ZigstoryPredictor(Path.Combine(directory, "missing.db")))
    {
        using var log = new StringWriter();
        using var listener = new TextWriterTraceListener(log);
        Trace.Listeners.Add(listener);
        var previousDirectory = Environment.GetEnvironmentVariable("ZIGSTORY_LOG_DIR");
        Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", Path.Combine(directory, "failure-logs"));
        try
        {
            Check(Text(Get(missing, "git")).Length == 0, "Unavailable history does not disrupt prediction");
            Trace.Flush();
            Check(log.ToString().Contains("prediction query failed"), "Database failures emit a diagnostic");
            Check(File.ReadAllText(Path.Combine(directory, "failure-logs", "predictor.log")).Contains("prediction_query_failed"),
                "Prediction failures reach the persistent Error log");
        }
        finally
        {
            Trace.Listeners.Remove(listener);
            Environment.SetEnvironmentVariable("ZIGSTORY_LOG_DIR", previousDirectory);
        }
    }
    if (args.Contains("--benchmark"))
    {
        var predictionQuery = typeof(ZigstoryPredictor)
            .GetMethod("GetSuggestionsFromDatabase", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!
            .CreateDelegate<Func<SqliteConnection, string, CancellationToken, List<string>>>();
        using var benchmark = OpenDatabase(Path.Combine(directory, "benchmark.db"));
        Execute(benchmark, """
            CREATE TABLE history (id INTEGER PRIMARY KEY, cmd TEXT, rank REAL, timestamp INTEGER);
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i < 100000)
            INSERT INTO history SELECT i,
              CASE WHEN i % 4 = 0 THEN 'git status ' || i ELSE 'echo item ' || i END,
              i % 1000, i FROM n;
            CREATE INDEX idx_cmd_prefix ON history(cmd COLLATE NOCASE);
            CREATE INDEX idx_rank ON history(rank DESC,timestamp DESC);
            """);
        foreach (var prefix in new[] { "git", "notfound", "git status 10000" })
        {
            const string baseline = "SELECT DISTINCT cmd FROM history WHERE cmd LIKE @pattern || '%' ORDER BY rank DESC,timestamp DESC LIMIT 5";
            const string bound = "SELECT DISTINCT cmd FROM history WHERE cmd LIKE @pattern ESCAPE '\\' ORDER BY rank DESC,timestamp DESC LIMIT 5";
            var oldResult = Query(benchmark, baseline, prefix);
            Check(Query(benchmark, bound, prefix + "%").SequenceEqual(oldResult), $"Benchmark output matches for '{prefix}'");
            Check(predictionQuery(benchmark, prefix, default).SequenceEqual(oldResult), $"Production query output matches for '{prefix}'");
            Console.WriteLine($"BENCH {prefix,-18} baseline={Measure(() => Query(benchmark, baseline, prefix)):F3}ms bound={Measure(() => Query(benchmark, bound, prefix + "%")):F3}ms adaptive={Measure(() => predictionQuery(benchmark, prefix, default)):F3}ms");
        }
    }
    Console.WriteLine("Predictor regressions passed.");
}
finally
{
    SqliteConnection.ClearAllPools();
    Directory.Delete(directory, recursive: true);
}

static SqliteConnection OpenDatabase(string path)
{
    var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
    connection.Open();
    Execute(connection, "PRAGMA journal_mode=WAL");
    return connection;
}

static void Execute(SqliteConnection connection, string sql)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    command.ExecuteNonQuery();
}

static SuggestionPackage Get(ZigstoryPredictor predictor, string input, CancellationToken token = default) =>
    predictor.GetSuggestion(new PredictionClient("regressions", PredictionClientKind.Terminal), PredictionContext.Create(input), token);

static string[] Text(SuggestionPackage package) =>
    package.SuggestionEntries?.Select(entry => entry.SuggestionText).ToArray() ?? [];

static void Check(bool success, string message)
{
    if (!success) throw new InvalidOperationException(message);
    Console.WriteLine($"PASS {message}");
}

static string[] Query(SqliteConnection connection, string sql, string pattern)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    command.Parameters.AddWithValue("@pattern", pattern);
    using var reader = command.ExecuteReader();
    var result = new List<string>();
    while (reader.Read()) result.Add(reader.GetString(0));
    return result.ToArray();
}

static double Measure(Action action)
{
    for (var i = 0; i < 3; i++) action();
    var times = new double[21];
    for (var i = 0; i < times.Length; i++)
    {
        var elapsed = Stopwatch.StartNew();
        action();
        times[i] = elapsed.Elapsed.TotalMilliseconds;
    }
    Array.Sort(times);
    return times[times.Length / 2];
}
