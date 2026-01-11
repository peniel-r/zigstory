using System;
using System.Collections.Concurrent;
using Microsoft.Data.Sqlite;

namespace zigstoryPredictor;

public sealed class DatabaseManager : IDisposable
{
    private readonly string _connectionString;
    private readonly ConcurrentBag<SqliteConnection> _connectionPool;
    private readonly int _maxPoolSize;
    private int _currentPoolSize;
    private bool _disposed;

    public DatabaseManager(string dbPath, int maxPoolSize = 5)
    {
        if (string.IsNullOrWhiteSpace(dbPath))
            throw new ArgumentException("Database path cannot be null or empty", nameof(dbPath));

        _maxPoolSize = maxPoolSize;
        _currentPoolSize = 0;
        _connectionPool = new ConcurrentBag<SqliteConnection>();
        _connectionString = $"Data Source={dbPath};Mode=ReadOnly;Pooling=True;Cache=Shared";
    }

    public SqliteConnection GetConnection()
    {
        if (_disposed)
            throw new ObjectDisposedException(nameof(DatabaseManager));

        if (_connectionPool.TryTake(out var connection))
        {
            if (connection.State == System.Data.ConnectionState.Open)
            {
                return connection;
            }
            else
            {
                connection.Dispose();
                Interlocked.Decrement(ref _currentPoolSize);
            }
        }

        if (_currentPoolSize < _maxPoolSize)
        {
            Interlocked.Increment(ref _currentPoolSize);
            var newConnection = new SqliteConnection(_connectionString);
            
            try
            {
                newConnection.Open();
                
                using var command = newConnection.CreateCommand();
                command.CommandText = "PRAGMA busy_timeout = 1000";
                command.ExecuteNonQuery();

                return newConnection;
            }
            catch
            {
                Interlocked.Decrement(ref _currentPoolSize);
                newConnection?.Dispose();
                throw;
            }
        }

        if (_connectionPool.TryTake(out connection))
        {
            return connection;
        }

        throw new InvalidOperationException("Unable to obtain database connection from pool");
    }

    public void ReturnConnection(SqliteConnection connection)
    {
        if (_disposed)
        {
            connection?.Dispose();
            return;
        }

        if (connection == null)
            return;

        if (connection.State == System.Data.ConnectionState.Open)
        {
            _connectionPool.Add(connection);
        }
        else
        {
            connection.Dispose();
            Interlocked.Decrement(ref _currentPoolSize);
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;

        while (_connectionPool.TryTake(out var connection))
        {
            connection?.Dispose();
        }

        _currentPoolSize = 0;
    }
}
