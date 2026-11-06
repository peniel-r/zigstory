using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;
using System.Threading;
using Microsoft.Data.Sqlite;

namespace zigstoryPredictor;

/// <summary>
/// PowerShell command predictor that provides ghost text suggestions based on command history.
/// Uses committed-write cache invalidation and cancellable prefix queries.
/// </summary>
public class ZigstoryPredictor : ICommandPredictor, IDisposable
{
    private readonly Guid _guid = new Guid("a8c5e3f1-2b4d-4e9a-8f1c-3d5e7b9a1c2f");
    private readonly DatabaseManager _dbManager;
    private readonly SemaphoreSlim _requestGate = new(1, 1);
    private SqliteConnection? _cacheConnection;
    private long? _cacheDataVersion;
    private long? _cacheSchemaVersion;
    private bool _disposed;
    
    // LRU cache: max 100 entries for prediction results
    private readonly LruCache<string, List<string>> _resultCache = new(100);
    
    private const string PredictionQuery = @"
        SELECT DISTINCT cmd 
        FROM history 
        WHERE cmd LIKE @pattern ESCAPE '\'
        ORDER BY rank DESC, timestamp DESC 
        LIMIT 5";
    // Moderately selective prefixes (e.g. 400 matching history rows) can be very
    // expensive via the rank index on a fresh connection. Bound the text-index
    // probe at 1024; truly broad prefixes still use the fast rank-first plan.
    private const int CandidateLimit = 1024;
    private const string CandidateCountQuery = @"
        SELECT COUNT(*) FROM (
            SELECT 1 FROM history WHERE cmd LIKE @pattern ESCAPE '\' LIMIT @limit)";
    private const string RankedPredictionQuery = @"
        SELECT DISTINCT cmd FROM history
        WHERE cmd LIKE (@pattern || '') ESCAPE '\'
        ORDER BY rank DESC, timestamp DESC LIMIT 5";
    private const string CatalogCandidateCountQuery = @"
        SELECT COUNT(*) FROM (SELECT 1 FROM commands WHERE cmd LIKE @pattern ESCAPE '\' LIMIT @limit)";
    private const string CatalogPredictionQuery = @"
        SELECT cmd FROM commands WHERE cmd LIKE @pattern ESCAPE '\'
        ORDER BY score_key DESC,last_used DESC,latest_history_id DESC LIMIT 5";
    private const string CatalogRankedQuery = @"
        SELECT cmd FROM commands WHERE cmd LIKE (@pattern || '') ESCAPE '\'
        ORDER BY score_key DESC,last_used DESC,latest_history_id DESC LIMIT 5";
    
    public Guid Id => _guid;
    public string Name => "Zigstory";
    public string Description => "Zig-based shell history predictor with frecency ranking";

    public ZigstoryPredictor() : this(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".zigstory", "history.db"))
    {
    }

    public ZigstoryPredictor(string dbPath)
    {
        _dbManager = new DatabaseManager(dbPath, maxPoolSize: 1);
    }

    /// <summary>
    /// Opens the read-only history connection on a worker thread. Optional: normal
    /// predictions still initialize lazily. Uses the same gate as queries/disposal
    /// so no connection is used concurrently or reopened after disposal.
    /// </summary>
    public Task WarmUpAsync(CancellationToken cancellationToken = default) => Task.Run(() =>
    {
        try
        {
            _requestGate.Wait(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
        try
        {
            if (_disposed || cancellationToken.IsCancellationRequested) return;
            var connection = _dbManager.GetConnection();
            _dbManager.ReturnConnection(connection);
        }
        catch (SqliteException)
        {
            // History may not exist yet. Do not log on every shell startup;
            // GetSuggestion retries normally and emits the usual diagnostic.
        }
        finally { _requestGate.Release(); }
    });

    public SuggestionPackage GetSuggestion(
        PredictionClient client,
        PredictionContext context,
        CancellationToken cancellationToken)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var input = context.InputAst.Extent.Text;

            // Optimization: Don't query on very short input
            if (string.IsNullOrWhiteSpace(input) || input.Length < 2)
            {
                return default;
            }

            _requestGate.Wait(cancellationToken);
            try
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                var connection = _dbManager.GetConnection();
                try
                {
                    using var registration = cancellationToken.Register(
                        () => SQLitePCL.raw.sqlite3_interrupt(connection.Handle));
                    cancellationToken.ThrowIfCancellationRequested();
                    using var versionCommand = connection.CreateCommand();
                    versionCommand.CommandText = "PRAGMA data_version";
                    var version = (long)versionCommand.ExecuteScalar()!;
                    if (!ReferenceEquals(connection, _cacheConnection) || version != _cacheDataVersion || _cacheSchemaVersion is null)
                    {
                        _resultCache.Clear();
                        _cacheConnection = connection;
                        _cacheDataVersion = version;
                        _cacheSchemaVersion = null;
                        _cacheSchemaVersion = ReadSupportedSchema(connection);
                    }
                    cancellationToken.ThrowIfCancellationRequested();
                    if (_resultCache.TryGet(input, out var cachedResults) && cachedResults != null)
                    {
                        return BuildSuggestionPackage(cachedResults);
                    }

                    var suggestions = QuerySuggestions(connection, input, cancellationToken, _cacheSchemaVersion.Value);
                    cancellationToken.ThrowIfCancellationRequested();
                    _resultCache.Set(input, suggestions);
                    return BuildSuggestionPackage(suggestions);
                }
                finally
                {
                    _dbManager.ReturnConnection(connection);
                }
            }
            finally
            {
                _requestGate.Release();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return default;
        }
        catch (SqliteException ex) when (cancellationToken.IsCancellationRequested && ex.SqliteErrorCode == SQLitePCL.raw.SQLITE_INTERRUPT)
        {
            return default;
        }
        catch (SqliteException ex)
        {
            Trace.TraceError("Zigstory prediction query failed: SQLite code {0}", ex.SqliteErrorCode);
            DiagnosticLog.Write(DiagnosticLevel.Error, "prediction_query_failed", $"SQLite_{ex.SqliteErrorCode}");
            return default;
        }
        catch (NotSupportedException)
        {
            Trace.TraceError("Zigstory prediction schema or ranking policy is unsupported.");
            DiagnosticLog.Write(DiagnosticLevel.Error, "prediction_schema_unsupported", "UnsupportedSchemaOrPolicy");
            return default;
        }
    }

    /// <summary>
    /// Builds a SuggestionPackage from a list of command strings.
    /// Returned packages own their lists, including across subsequent requests.
    /// </summary>
    private static SuggestionPackage BuildSuggestionPackage(List<string> suggestions)
    {
        if (suggestions.Count == 0) return default;
        var entries = new List<PredictiveSuggestion>(suggestions.Count);

        foreach (var suggestion in suggestions)
        {
            entries.Add(new PredictiveSuggestion(suggestion));
        }

        return new SuggestionPackage(entries);
    }

    /// <summary>
    /// Queries the database for literal prefix matches.
    /// </summary>
    private static List<string> GetSuggestionsFromDatabase(
        SqliteConnection connection, string input, CancellationToken cancellationToken)
        => QuerySuggestions(connection, input, cancellationToken, ReadSupportedSchema(connection));

    private static long ReadSupportedSchema(SqliteConnection connection)
    {
        using var version = new SqliteCommand("PRAGMA user_version", connection);
        var schema = (long)version.ExecuteScalar()!;
        if (schema is < 0 or > 3) throw new NotSupportedException("Unsupported schema.");
        if (schema == 3)
        {
            using var metadata = new SqliteCommand("SELECT layout_version,ranking_version,half_life_seconds,typeof(layout_version),typeof(ranking_version),typeof(half_life_seconds) FROM catalog_metadata WHERE id=1", connection);
            using var row = metadata.ExecuteReader();
            if (!row.Read() || row.IsDBNull(0) || row.IsDBNull(1) || row.IsDBNull(2) ||
                row.GetString(3) != "integer" || row.GetString(4) != "integer" || row.GetString(5) != "integer" ||
                row.GetInt64(0) != 2 || row.GetInt64(1) != 1 || row.GetInt64(2) != 2592000)
                throw new NotSupportedException("Unsupported ranking policy or layout.");
        }
        return schema;
    }

    private static List<string> QuerySuggestions(
        SqliteConnection connection, string input, CancellationToken cancellationToken, long schema)
    {
        var results = new List<string>(5);
        var pattern = input.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
        using var probe = new SqliteCommand(schema == 3 ? CatalogCandidateCountQuery : CandidateCountQuery, connection);
        probe.Parameters.AddWithValue("@pattern", pattern);
        probe.Parameters.AddWithValue("@limit", CandidateLimit);
        var candidates = (long)probe.ExecuteScalar()!;
        cancellationToken.ThrowIfCancellationRequested();
        if (candidates == 0) return results;
        // Broad prefixes favor the rank index; selective prefixes favor the text index.
        using var command = new SqliteCommand(
            schema == 3
                ? (candidates < CandidateLimit ? CatalogPredictionQuery : CatalogRankedQuery)
                : (candidates < CandidateLimit ? PredictionQuery : RankedPredictionQuery), connection);
        command.Parameters.AddWithValue("@pattern", pattern);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var cmd = reader.GetString(0);
            if (!string.IsNullOrWhiteSpace(cmd))
            {
                results.Add(cmd);
            }
        }
        return results;
    }

    public void Dispose()
    {
        _requestGate.Wait();
        try
        {
            if (_disposed) return;
            _disposed = true;
            _resultCache.Clear();
            _cacheConnection = null;
            _cacheDataVersion = null;
            _cacheSchemaVersion = null;
            _dbManager.Dispose();
        }
        finally
        {
            _requestGate.Release();
        }
    }
}
