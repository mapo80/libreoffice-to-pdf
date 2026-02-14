using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace SlimLO.Internal;

/// <summary>
/// Manages the lifecycle of a single native slimlo_worker subprocess.
/// Handles startup, message exchange, stderr capture, and crash detection.
/// </summary>
internal sealed class WorkerProcess : IAsyncDisposable
{
    private readonly string _workerPath;
    private readonly string _resourcePath;
    private readonly IReadOnlyList<string>? _fontDirectories;
    private Process? _process;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private readonly StringBuilder _stderrBuffer = new();
    private volatile bool _disposed;
    private volatile bool _initialized;
    private int _conversionCount;
    private string? _version;

    public WorkerProcess(string workerPath, string resourcePath, IReadOnlyList<string>? fontDirectories)
    {
        _workerPath = workerPath;
        _resourcePath = resourcePath;
        _fontDirectories = fontDirectories;
    }

    public int ConversionCount => _conversionCount;
    public bool IsAlive => _process is { HasExited: false };
    public string? Version => _version;

    /// <summary>
    /// Start the worker process and send the init message.
    /// </summary>
    public async Task StartAsync(CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        var psi = new ProcessStartInfo
        {
            FileName = _workerPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = null, // binary
            StandardOutputEncoding = null, // binary
        };

        // Ensure the worker can find libslimlo and libmergedlo.
        // Include both the worker's directory and the resource program/ directory,
        // since the worker may be in a different location than the native assets
        // (e.g., during development or when SLIMLO_WORKER_PATH is set).
        var workerDir = Path.GetDirectoryName(_workerPath)!;
        var programDir = Path.Combine(_resourcePath, "program");
        if (OperatingSystem.IsLinux())
        {
            var existing = Environment.GetEnvironmentVariable("LD_LIBRARY_PATH");
            var paths = workerDir == programDir ? workerDir : $"{workerDir}:{programDir}";
            psi.Environment["LD_LIBRARY_PATH"] = string.IsNullOrEmpty(existing)
                ? paths
                : $"{paths}:{existing}";
        }
        else if (OperatingSystem.IsMacOS())
        {
            var existing = Environment.GetEnvironmentVariable("DYLD_LIBRARY_PATH");
            var paths = workerDir == programDir ? workerDir : $"{workerDir}:{programDir}";
            psi.Environment["DYLD_LIBRARY_PATH"] = string.IsNullOrEmpty(existing)
                ? paths
                : $"{paths}:{existing}";
        }

        // Set environment variables for the worker process.
        // On macOS, the SVP (headless) plugin is not available — only the Quartz
        // backend exists. On Linux/Windows, use SVP for headless operation.
        if (!OperatingSystem.IsMacOS())
            psi.Environment["SAL_USE_VCLPLUGIN"] = "svp";

        // On macOS, LOKit must use "unipoll" mode to run VCL initialization on the
        // calling thread. Without this, LOKit spawns a background thread for VCL init,
        // but the Quartz backend creates NSWindow objects which require the main thread.
        if (OperatingSystem.IsMacOS())
            psi.Environment["SAL_LOK_OPTIONS"] = "unipoll";

        // Enable font-related logging so stderr capture can detect font warnings
        psi.Environment["SAL_LOG"] = "+WARN.vcl.fonts+INFO.vcl+WARN.vcl";

        // Set custom font paths
        if (_fontDirectories is { Count: > 0 })
        {
            var separator = OperatingSystem.IsWindows() ? ";" : ":";
            psi.Environment["SAL_FONTPATH"] = string.Join(separator, _fontDirectories);
        }

        // Create a temp directory for LOKit user profile
        var profileDir = Path.Combine(Path.GetTempPath(), $"slimlo_profile_{Environment.ProcessId}_{GetHashCode():x}");
        Directory.CreateDirectory(profileDir);
        psi.Environment["HOME"] = profileDir;

        _process = Process.Start(psi)
            ?? throw new SlimLOException("Failed to start worker process", SlimLOErrorCode.InitFailed);

        // Start capturing stderr asynchronously
        _process.ErrorDataReceived += OnStderrData;
        _process.BeginErrorReadLine();

        // Send init message
        var initRequest = new InitRequest
        {
            ResourcePath = _resourcePath,
            FontPaths = _fontDirectories
        };
        var initBytes = Protocol.Serialize(initRequest);
        await Protocol.WriteMessageAsync(
            _process.StandardInput.BaseStream, initBytes, ct).ConfigureAwait(false);

        // Read init response
        var responseBytes = await Protocol.ReadMessageAsync(
            _process.StandardOutput.BaseStream, ct).ConfigureAwait(false);

        if (responseBytes is null)
        {
            var exitCode = _process.HasExited ? _process.ExitCode : -1;
            var stderr = GetStderrOutput();
            var message = $"Worker process died during initialization (exit code: {exitCode}).";

            if (stderr.Contains("error while loading shared libraries"))
            {
                message += " Missing system library detected. On Ubuntu/Debian, install: " +
                    "apt-get install libfontconfig1 libfreetype6 libexpat1 libcairo2 libpng16-16 " +
                    "libjpeg-turbo8 libxml2 libxslt1.1 libicu74 libnss3 libnspr4. " +
                    "See https://github.com/nicobao/libreoffice-to-pdf#linux-system-dependencies for details.";
            }

            message += $" Stderr: {stderr}";
            throw new SlimLOException(message, SlimLOErrorCode.InitFailed);
        }

        using var doc = Protocol.Deserialize(responseBytes);
        var root = doc.RootElement;
        var type = root.GetProperty("type").GetString();

        if (type == "error")
        {
            var message = root.TryGetProperty("message", out var m) ? m.GetString() : "Unknown error";
            throw new SlimLOException(
                $"Worker initialization failed: {message}",
                SlimLOErrorCode.InitFailed);
        }

        if (type == "ready")
        {
            _version = root.TryGetProperty("version", out var v) ? v.GetString() : null;
            _initialized = true;
        }
        else
        {
            throw new SlimLOException(
                $"Unexpected init response type: {type}",
                SlimLOErrorCode.InitFailed);
        }
    }

    /// <summary>
    /// Execute a conversion. The caller must hold the pool semaphore.
    /// </summary>
    public async Task<ConversionResult> ConvertAsync(
        ConvertRequest request,
        TimeSpan timeout,
        CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!_initialized || _process is null or { HasExited: true })
            return ConversionResult.Fail(
                "Worker process is not running",
                SlimLOErrorCode.NotInitialized, null);

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Clear stderr buffer before conversion
            lock (_stderrBuffer)
                _stderrBuffer.Clear();

            // Create a linked cancellation token with timeout
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(timeout);
            var linkedCt = timeoutCts.Token;

            try
            {
                // Send convert request
                var requestBytes = Protocol.Serialize(request);
                await Protocol.WriteMessageAsync(
                    _process.StandardInput.BaseStream, requestBytes, linkedCt).ConfigureAwait(false);

                // Read response
                var responseBytes = await Protocol.ReadMessageAsync(
                    _process.StandardOutput.BaseStream, linkedCt).ConfigureAwait(false);

                if (responseBytes is null)
                {
                    // Worker died during conversion
                    var exitCode = _process.HasExited ? _process.ExitCode : -1;
                    _initialized = false;
                    return ConversionResult.Fail(
                        $"Worker process crashed during conversion (exit code: {exitCode}). " +
                        "This typically indicates a malformed or corrupted document.",
                        SlimLOErrorCode.Unknown, null);
                }

                // Parse response
                using var doc = Protocol.Deserialize(responseBytes);
                var root = doc.RootElement;

                var diagnostics = root.TryGetProperty("diagnostics", out var diagArray)
                    ? StderrDiagnosticParser.ParseFromJson(diagArray)
                    : Array.Empty<ConversionDiagnostic>();

                var success = root.TryGetProperty("success", out var s) && s.GetBoolean();

                if (success)
                {
                    Interlocked.Increment(ref _conversionCount);
                    return ConversionResult.Ok(diagnostics);
                }
                else
                {
                    var errorMessage = root.TryGetProperty("error_message", out var em)
                        ? em.GetString() ?? "Conversion failed"
                        : "Conversion failed";
                    var errorCode = root.TryGetProperty("error_code", out var ec) && ec.ValueKind == JsonValueKind.Number
                        ? (SlimLOErrorCode)ec.GetInt32()
                        : SlimLOErrorCode.Unknown;

                    Interlocked.Increment(ref _conversionCount);
                    return ConversionResult.Fail(errorMessage, errorCode, diagnostics);
                }
            }
            catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !ct.IsCancellationRequested)
            {
                // Timeout — kill the worker
                KillProcess();
                _initialized = false;
                return ConversionResult.Fail(
                    $"Conversion timed out after {timeout.TotalSeconds:F0} seconds",
                    SlimLOErrorCode.Unknown, null);
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>
    /// Execute a buffer conversion. Sends document bytes, receives PDF bytes.
    /// The caller must hold the pool semaphore.
    /// </summary>
    public async Task<ConversionResult<byte[]>> ConvertBufferAsync(
        ConvertBufferRequest request,
        ReadOnlyMemory<byte> documentData,
        TimeSpan timeout,
        CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!_initialized || _process is null or { HasExited: true })
            return ConversionResult<byte[]>.Fail(
                "Worker process is not running",
                SlimLOErrorCode.NotInitialized, null);

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            lock (_stderrBuffer)
                _stderrBuffer.Clear();

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(timeout);
            var linkedCt = timeoutCts.Token;

            try
            {
                var stdin = _process.StandardInput.BaseStream;
                var stdout = _process.StandardOutput.BaseStream;

                // Send JSON header frame
                var requestBytes = Protocol.Serialize(request);
                await Protocol.WriteMessageAsync(stdin, requestBytes, linkedCt).ConfigureAwait(false);

                // Send binary document frame
                await Protocol.WriteMessageAsync(stdin, documentData, linkedCt).ConfigureAwait(false);

                // Read JSON response frame
                var responseBytes = await Protocol.ReadMessageAsync(stdout, linkedCt).ConfigureAwait(false);

                if (responseBytes is null)
                {
                    var exitCode = _process.HasExited ? _process.ExitCode : -1;
                    _initialized = false;
                    return ConversionResult<byte[]>.Fail(
                        $"Worker process crashed during buffer conversion (exit code: {exitCode}). " +
                        "This typically indicates a malformed or corrupted document.",
                        SlimLOErrorCode.Unknown, null);
                }

                using var doc = Protocol.Deserialize(responseBytes);
                var root = doc.RootElement;

                var diagnostics = root.TryGetProperty("diagnostics", out var diagArray)
                    ? StderrDiagnosticParser.ParseFromJson(diagArray)
                    : Array.Empty<ConversionDiagnostic>();

                var success = root.TryGetProperty("success", out var s) && s.GetBoolean();

                if (success)
                {
                    // Read binary PDF frame
                    var pdfBytes = await Protocol.ReadMessageAsync(stdout, linkedCt).ConfigureAwait(false);
                    if (pdfBytes is null)
                    {
                        _initialized = false;
                        return ConversionResult<byte[]>.Fail(
                            "Worker process crashed while sending PDF data",
                            SlimLOErrorCode.Unknown, diagnostics);
                    }

                    Interlocked.Increment(ref _conversionCount);
                    return ConversionResult<byte[]>.Ok(pdfBytes, diagnostics);
                }
                else
                {
                    var errorMessage = root.TryGetProperty("error_message", out var em)
                        ? em.GetString() ?? "Buffer conversion failed"
                        : "Buffer conversion failed";
                    var errorCode = root.TryGetProperty("error_code", out var ec) && ec.ValueKind == JsonValueKind.Number
                        ? (SlimLOErrorCode)ec.GetInt32()
                        : SlimLOErrorCode.Unknown;

                    Interlocked.Increment(ref _conversionCount);
                    return ConversionResult<byte[]>.Fail(errorMessage, errorCode, diagnostics);
                }
            }
            catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !ct.IsCancellationRequested)
            {
                KillProcess();
                _initialized = false;
                return ConversionResult<byte[]>.Fail(
                    $"Buffer conversion timed out after {timeout.TotalSeconds:F0} seconds",
                    SlimLOErrorCode.Unknown, null);
            }
        }
        finally
        {
            _lock.Release();
        }
    }

    private void OnStderrData(object sender, DataReceivedEventArgs e)
    {
        if (e.Data is null) return;
        lock (_stderrBuffer)
        {
            _stderrBuffer.AppendLine(e.Data);
        }
    }

    private string GetStderrOutput()
    {
        lock (_stderrBuffer)
            return _stderrBuffer.ToString();
    }

    private void KillProcess()
    {
        try
        {
            if (_process is { HasExited: false })
                _process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Best effort — process may have already exited
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;

        if (_process is not null && !_process.HasExited)
        {
            try
            {
                // Try graceful shutdown first
                var quitBytes = Protocol.Serialize(new QuitRequest());
                await Protocol.WriteMessageAsync(
                    _process.StandardInput.BaseStream, quitBytes, CancellationToken.None)
                    .ConfigureAwait(false);

                // Wait up to 5 seconds for graceful exit
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                try
                {
                    await _process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    KillProcess();
                }
            }
            catch
            {
                KillProcess();
            }
        }

        _process?.Dispose();
        _lock.Dispose();
    }
}
