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
/// Optimized for sub-5ms query performance with LRU caching and pre-compiled queries.
/// </summary>
public class ZigstoryPredictor : ICommandPredictor
{
    private readonly Guid _guid = new Guid("a8c5e3f1-2b4d-4e9a-8f1c-3d5e7b9a1c2f");
    private readonly DatabaseManager _dbManager;
    
    // LRU cache: max 100 entries for prediction results
    private readonly LruCache<string, List<string>> _resultCache = new(100);
    
    // Pre-compiled query string (const for zero allocation)
    // Use rank-based sorting for frecency ranking
    private const string PredictionQuery = @"
        SELECT DISTINCT cmd 
        FROM history 
        WHERE cmd LIKE @input || '%' 
        ORDER BY rank DESC, timestamp DESC 
        LIMIT 5";
    
    // Reusable list to minimize allocations (thread-local would be better for true thread safety)
    [ThreadStatic]
    private static List<PredictiveSuggestion>? _suggestionBuffer;
    
    public Guid Id => _guid;
    public string Name => "Zigstory";
    public string Description => "Zig-based shell history predictor with frecency ranking and sub-5ms query performance";

    public ZigstoryPredictor()
    {
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var dbPath = Path.Combine(userProfile, ".zigstory", "history.db");
        _dbManager = new DatabaseManager(dbPath);
    }

    public SuggestionPackage GetSuggestion(
        PredictionClient client,
        PredictionContext context,
        CancellationToken cancellationToken)
    {
        try
        {
            var input = context.InputAst.Extent.Text;

            // Optimization: Don't query on very short input
            if (string.IsNullOrWhiteSpace(input) || input.Length < 2)
            {
                return default;
            }

            // Check cache first (target: <1ms for cache hit)
            if (_resultCache.TryGet(input, out var cachedResults) && cachedResults != null)
            {
                return BuildSuggestionPackage(cachedResults);
            }

            // Cache miss: query database (target: <5ms)
            var suggestions = GetSuggestionsFromDatabase(input, cancellationToken);
            
            if (suggestions.Count == 0)
            {
                return default;
            }

            // Store in cache for future hits
            _resultCache.Set(input, suggestions);

            return BuildSuggestionPackage(suggestions);
        }
        catch
        {
            return default;
        }
    }

    /// <summary>
    /// Builds a SuggestionPackage from a list of command strings.
    /// Uses thread-static buffer to minimize allocations in hot path.
    /// </summary>
    private static SuggestionPackage BuildSuggestionPackage(List<string> suggestions)
    {
        _suggestionBuffer ??= new List<PredictiveSuggestion>(5);
        _suggestionBuffer.Clear();

        foreach (var suggestion in suggestions)
        {
            _suggestionBuffer.Add(new PredictiveSuggestion(suggestion));
        }

        return new SuggestionPackage(_suggestionBuffer);
    }

    /// <summary>
    /// Queries the database for matching commands using pre-compiled query.
    /// Optimized for <5ms p95 latency.
    /// </summary>
    private List<string> GetSuggestionsFromDatabase(string input, CancellationToken cancellationToken)
    {
        // Pre-allocate with expected capacity to avoid resizing
        var results = new List<string>(5);
        SqliteConnection? connection = null;

        try
        {
            connection = _dbManager.GetConnection();

            using var command = new SqliteCommand(PredictionQuery, connection);
            command.Parameters.AddWithValue("@input", input);

            using var reader = command.ExecuteReader();
            while (reader.Read() && !cancellationToken.IsCancellationRequested)
            {
                var cmd = reader.GetString(0);
                if (!string.IsNullOrWhiteSpace(cmd))
                {
                    results.Add(cmd);
                }
            }
        }
        catch
        {
            // Swallow exceptions to prevent PowerShell disruption
        }
        finally
        {
            if (connection != null)
            {
                _dbManager.ReturnConnection(connection);
            }
        }

        return results;
    }
}
