using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;
using System.Threading;
using Microsoft.Data.Sqlite;

namespace zigstoryPredictor;

public class ZigstoryPredictor : ICommandPredictor
{
    private readonly Guid _guid = new Guid("a8c5e3f1-2b4d-4e9a-8f1c-3d5e7b9a1c2f");
    private readonly DatabaseManager _dbManager;
    
    public Guid Id => _guid;
    public string Name => "ZigstoryPredictor";
    public string Description => "Zig-based shell history predictor with sub-5ms query performance";

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

            if (string.IsNullOrWhiteSpace(input) || input.Length < 2)
            {
                return default;
            }

            var suggestions = GetSuggestionsFromDatabase(input, cancellationToken);
            
            if (suggestions.Count == 0)
            {
                return default;
            }

            var predictiveSuggestions = new List<PredictiveSuggestion>();
            foreach (var suggestion in suggestions)
            {
                predictiveSuggestions.Add(new PredictiveSuggestion(suggestion));
            }

            return new SuggestionPackage(predictiveSuggestions);
        }
        catch
        {
            return default;
        }
    }

    private List<string> GetSuggestionsFromDatabase(string input, CancellationToken cancellationToken)
    {
        var results = new List<string>();
        SqliteConnection? connection = null;

        try
        {
            connection = _dbManager.GetConnection();

            var query = @"
                SELECT DISTINCT cmd 
                FROM history 
                WHERE cmd LIKE @input || '%' 
                ORDER BY timestamp DESC 
                LIMIT 5";

            using var command = new SqliteCommand(query, connection);
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
