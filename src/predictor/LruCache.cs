using System;
using System.Collections.Generic;

namespace zigstoryPredictor;

/// <summary>
/// Thread-safe LRU (Least Recently Used) cache implementation.
/// Provides O(1) access and O(1) eviction for cached prediction results.
/// </summary>
public sealed class LruCache<TKey, TValue> where TKey : notnull
{
    private readonly int _capacity;
    private readonly Dictionary<TKey, LinkedListNode<CacheEntry>> _cache;
    private readonly LinkedList<CacheEntry> _lruList;
    private readonly object _lock = new();

    private struct CacheEntry
    {
        public TKey Key;
        public TValue Value;
        public long Timestamp;
    }

    public LruCache(int capacity)
    {
        if (capacity <= 0)
            throw new ArgumentOutOfRangeException(nameof(capacity), "Capacity must be positive");

        _capacity = capacity;
        _cache = new Dictionary<TKey, LinkedListNode<CacheEntry>>(capacity);
        _lruList = new LinkedList<CacheEntry>();
    }

    /// <summary>
    /// Attempts to get a value from the cache.
    /// Returns true if found, promoting the entry to most-recently-used.
    /// </summary>
    public bool TryGet(TKey key, out TValue? value)
    {
        lock (_lock)
        {
            if (_cache.TryGetValue(key, out var node))
            {
                // Move to front (most recently used)
                _lruList.Remove(node);
                _lruList.AddFirst(node);
                value = node.Value.Value;
                return true;
            }

            value = default;
            return false;
        }
    }

    /// <summary>
    /// Adds or updates a value in the cache.
    /// Evicts least-recently-used entry if at capacity.
    /// </summary>
    public void Set(TKey key, TValue value)
    {
        lock (_lock)
        {
            if (_cache.TryGetValue(key, out var existingNode))
            {
                // Update existing entry
                _lruList.Remove(existingNode);
                var entry = new CacheEntry 
                { 
                    Key = key, 
                    Value = value,
                    Timestamp = Environment.TickCount64
                };
                var newNode = new LinkedListNode<CacheEntry>(entry);
                _lruList.AddFirst(newNode);
                _cache[key] = newNode;
                return;
            }

            // Evict LRU entry if at capacity
            if (_cache.Count >= _capacity)
            {
                var lruNode = _lruList.Last;
                if (lruNode != null)
                {
                    _cache.Remove(lruNode.Value.Key);
                    _lruList.RemoveLast();
                }
            }

            // Add new entry
            var newEntry = new CacheEntry 
            { 
                Key = key, 
                Value = value,
                Timestamp = Environment.TickCount64
            };
            var node = new LinkedListNode<CacheEntry>(newEntry);
            _lruList.AddFirst(node);
            _cache[key] = node;
        }
    }

    /// <summary>
    /// Returns the current number of entries in the cache.
    /// </summary>
    public int Count
    {
        get
        {
            lock (_lock)
            {
                return _cache.Count;
            }
        }
    }

    /// <summary>
    /// Clears all entries from the cache.
    /// </summary>
    public void Clear()
    {
        lock (_lock)
        {
            _cache.Clear();
            _lruList.Clear();
        }
    }
}
