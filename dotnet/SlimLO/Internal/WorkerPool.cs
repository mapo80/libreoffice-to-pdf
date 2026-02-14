namespace SlimLO.Internal;

/// <summary>
/// Thread-safe pool of native worker processes.
/// Provides round-robin dispatch, automatic crash recovery,
/// and worker recycling.
/// </summary>
internal sealed class WorkerPool : IAsyncDisposable
{
    private readonly string _workerPath;
    private readonly string _resourcePath;
    private readonly IReadOnlyList<string>? _fontDirectories;
    private readonly int _maxWorkers;
    private readonly int _maxConversionsPerWorker;
    private readonly TimeSpan _timeout;
    private readonly SemaphoreSlim _gate;
    private readonly WorkerProcess?[] _workers;
    private readonly SemaphoreSlim[] _workerLocks;
    private int _nextWorkerIndex;
    private volatile bool _disposed;
    private string? _version;

    public WorkerPool(
        string workerPath,
        string resourcePath,
        IReadOnlyList<string>? fontDirectories,
        int maxWorkers,
        int maxConversionsPerWorker,
        TimeSpan timeout)
    {
        _workerPath = workerPath;
        _resourcePath = resourcePath;
        _fontDirectories = fontDirectories;
        _maxWorkers = maxWorkers;
        _maxConversionsPerWorker = maxConversionsPerWorker;
        _timeout = timeout;
        _gate = new SemaphoreSlim(maxWorkers, maxWorkers);
        _workers = new WorkerProcess?[maxWorkers];
        _workerLocks = new SemaphoreSlim[maxWorkers];
        for (int i = 0; i < maxWorkers; i++)
            _workerLocks[i] = new SemaphoreSlim(1, 1);
    }

    public string? Version => _version;

    /// <summary>
    /// Pre-start all worker processes (for WarmUp mode).
    /// </summary>
    public async Task WarmUpAsync(CancellationToken ct)
    {
        var tasks = new Task[_maxWorkers];
        for (int i = 0; i < _maxWorkers; i++)
        {
            int index = i;
            tasks[i] = EnsureWorkerAsync(index, ct);
        }
        await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// Execute a conversion on the next available worker.
    /// Thread-safe: multiple threads can call this concurrently.
    /// </summary>
    public async Task<ConversionResult> ExecuteAsync(
        ConvertRequest request,
        CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        // Wait for a worker slot
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Pick a worker via round-robin
            int index = (int)((uint)Interlocked.Increment(ref _nextWorkerIndex) % (uint)_maxWorkers);

            // Ensure worker is alive (start or restart if needed)
            await EnsureWorkerAsync(index, ct).ConfigureAwait(false);

            var worker = _workers[index];
            if (worker is null)
                return ConversionResult.Fail("Failed to start worker", SlimLOErrorCode.InitFailed, null);

            // Execute conversion
            var result = await worker.ConvertAsync(request, _timeout, ct).ConfigureAwait(false);

            // Check if worker needs recycling
            if (_maxConversionsPerWorker > 0 && worker.ConversionCount >= _maxConversionsPerWorker)
            {
                await RecycleWorkerAsync(index).ConfigureAwait(false);
            }

            // If worker crashed during conversion, mark for replacement
            if (!worker.IsAlive)
            {
                await _workerLocks[index].WaitAsync(ct).ConfigureAwait(false);
                try
                {
                    if (_workers[index] == worker)
                    {
                        await worker.DisposeAsync().ConfigureAwait(false);
                        _workers[index] = null;
                    }
                }
                finally
                {
                    _workerLocks[index].Release();
                }
            }

            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Execute a buffer conversion on the next available worker.
    /// Thread-safe: multiple threads can call this concurrently.
    /// </summary>
    public async Task<ConversionResult<byte[]>> ExecuteBufferAsync(
        ConvertBufferRequest request,
        ReadOnlyMemory<byte> documentData,
        CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            int index = (int)((uint)Interlocked.Increment(ref _nextWorkerIndex) % (uint)_maxWorkers);

            await EnsureWorkerAsync(index, ct).ConfigureAwait(false);

            var worker = _workers[index];
            if (worker is null)
                return ConversionResult<byte[]>.Fail("Failed to start worker", SlimLOErrorCode.InitFailed, null);

            var result = await worker.ConvertBufferAsync(request, documentData, _timeout, ct).ConfigureAwait(false);

            if (_maxConversionsPerWorker > 0 && worker.ConversionCount >= _maxConversionsPerWorker)
            {
                await RecycleWorkerAsync(index).ConfigureAwait(false);
            }

            if (!worker.IsAlive)
            {
                await _workerLocks[index].WaitAsync(ct).ConfigureAwait(false);
                try
                {
                    if (_workers[index] == worker)
                    {
                        await worker.DisposeAsync().ConfigureAwait(false);
                        _workers[index] = null;
                    }
                }
                finally
                {
                    _workerLocks[index].Release();
                }
            }

            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task EnsureWorkerAsync(int index, CancellationToken ct)
    {
        if (_workers[index] is { IsAlive: true })
            return;

        await _workerLocks[index].WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Double-check after acquiring lock
            if (_workers[index] is { IsAlive: true })
                return;

            // Dispose old worker if exists
            if (_workers[index] is not null)
            {
                await _workers[index]!.DisposeAsync().ConfigureAwait(false);
                _workers[index] = null;
            }

            // Start new worker
            var worker = new WorkerProcess(_workerPath, _resourcePath, _fontDirectories);
            await worker.StartAsync(ct).ConfigureAwait(false);
            _workers[index] = worker;
            _version ??= worker.Version;
        }
        finally
        {
            _workerLocks[index].Release();
        }
    }

    private async Task RecycleWorkerAsync(int index)
    {
        await _workerLocks[index].WaitAsync().ConfigureAwait(false);
        try
        {
            if (_workers[index] is not null)
            {
                await _workers[index]!.DisposeAsync().ConfigureAwait(false);
                _workers[index] = null;
            }
        }
        finally
        {
            _workerLocks[index].Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;

        // Dispose all workers in parallel
        var tasks = new List<ValueTask>();
        for (int i = 0; i < _maxWorkers; i++)
        {
            if (_workers[i] is not null)
                tasks.Add(_workers[i]!.DisposeAsync());
        }

        foreach (var task in tasks)
            await task.ConfigureAwait(false);

        _gate.Dispose();
        foreach (var l in _workerLocks)
            l.Dispose();
    }
}
