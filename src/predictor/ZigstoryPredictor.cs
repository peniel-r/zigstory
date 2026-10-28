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
    private bool _disposed;
    
    // LRU cache: max 100 entries for prediction results
    private readonly LruCache<string, List<string>> _resultCache = new(100);
    
    private const string PredictionQuery = @"
        SELECT DISTINCT cmd 
        FROM history 
        WHERE cmd LIKE @pattern ESCAPE '\'
        ORDER BY rank DESC, timestamp DESC 
        LIMIT 5";
    private const int CandidateLimit = 128;
    private const string CandidateCountQuery = @"
        SELECT COUNT(*) FROM (
            SELECT 1 FROM history WHERE cmd LIKE @pattern ESCAPE '\' LIMIT @limit)";
    private const string RankedPredictionQuery = @"
        SELECT DISTINCT cmd FROM history
        WHERE cmd LIKE (@pattern || '') ESCAPE '\'
        ORDER BY rank DESC, timestamp DESC LIMIT 5";
    
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
                    if (!ReferenceEquals(connection, _cacheConnection) || version != _cacheDataVersion)
                    {
                        _resultCache.Clear();
                        _cacheConnection = connection;
                        _cacheDataVersion = version;
                    }
                    cancellationToken.ThrowIfCancellationRequested();
                    if (_resultCache.TryGet(input, out var cachedResults) && cachedResults != null)
                    {
                        return BuildSuggestionPackage(cachedResults);
                    }

                    var suggestions = GetSuggestionsFromDatabase(connection, input, cancellationToken);
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
            Trace.TraceWarning("Zigstory prediction query failed: {0}", ex.Message);
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
    {
        var results = new List<string>(5);
        var pattern = input.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
        using var probe = new SqliteCommand(CandidateCountQuery, connection);
        probe.Parameters.AddWithValue("@pattern", pattern);
        probe.Parameters.AddWithValue("@limit", CandidateLimit);
        var candidates = (long)probe.ExecuteScalar()!;
        cancellationToken.ThrowIfCancellationRequested();
        if (candidates == 0) return results;
        // Broad prefixes favor the rank index; selective prefixes favor the text index.
        using var command = new SqliteCommand(
            candidates < CandidateLimit ? PredictionQuery : RankedPredictionQuery, connection);
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
            _dbManager.Dispose();
        }
        finally
        {
            _requestGate.Release();
        }
    }
}
