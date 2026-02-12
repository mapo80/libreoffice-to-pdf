using SlimLO.Internal;

namespace SlimLO;

/// <summary>
/// Enterprise-grade PDF converter for OOXML documents (DOCX, XLSX, PPTX).
///
/// <para><b>Thread safety:</b> All methods are fully thread-safe. Multiple threads
/// can call <see cref="ConvertAsync(string, string, ConversionOptions?, CancellationToken)"/>
/// concurrently. With <see cref="PdfConverterOptions.MaxWorkers"/> greater than 1,
/// conversions run in parallel across separate worker processes.</para>
///
/// <para><b>Crash resilience:</b> Conversions run in isolated worker processes.
/// If LibreOffice crashes on a malformed document, the worker is automatically
/// replaced and the conversion returns a failure result. The host .NET process
/// is never affected.</para>
///
/// <para><b>Font support:</b> Custom font directories can be specified via
/// <see cref="PdfConverterOptions.FontDirectories"/>. Font substitution warnings
/// are reported in <see cref="ConversionResult.Diagnostics"/>.</para>
///
/// <example>
/// <code>
/// await using var converter = PdfConverter.Create(new PdfConverterOptions
/// {
///     FontDirectories = ["/usr/share/fonts/custom"],
///     MaxWorkers = 2
/// });
///
/// var result = await converter.ConvertAsync("input.docx", "output.pdf");
/// if (result.HasFontWarnings)
///     foreach (var d in result.Diagnostics)
///         Console.WriteLine($"  {d.Severity}: {d.Message}");
/// </code>
/// </example>
/// </summary>
public sealed class PdfConverter : IAsyncDisposable, IDisposable
{
    private readonly WorkerPool _pool;
    private volatile bool _disposed;
    private int _requestId;

    private PdfConverter(WorkerPool pool)
    {
        _pool = pool;
    }

    /// <summary>
    /// Create a new PdfConverter instance.
    /// Multiple instances with different configurations are allowed.
    /// Workers start lazily on first conversion unless <see cref="PdfConverterOptions.WarmUp"/> is true.
    /// </summary>
    /// <param name="options">Converter configuration. Null for defaults (auto-detect paths, 1 worker).</param>
    /// <returns>A new PdfConverter instance. Dispose when no longer needed.</returns>
    /// <exception cref="FileNotFoundException">Worker executable not found.</exception>
    /// <exception cref="InvalidOperationException">Resource path could not be auto-detected.</exception>
    public static PdfConverter Create(PdfConverterOptions? options = null)
    {
        options ??= new PdfConverterOptions();

        if (options.MaxWorkers < 1)
            throw new ArgumentOutOfRangeException(
                nameof(options), "MaxWorkers must be at least 1");

        var workerPath = WorkerLocator.FindWorkerExecutable();
        var resourcePath = options.ResourcePath ?? WorkerLocator.FindResourcePath();

        var pool = new WorkerPool(
            workerPath,
            resourcePath,
            options.FontDirectories,
            options.MaxWorkers,
            options.MaxConversionsPerWorker,
            options.ConversionTimeout);

        var converter = new PdfConverter(pool);

        if (options.WarmUp)
        {
            pool.WarmUpAsync(CancellationToken.None).GetAwaiter().GetResult();
        }

        return converter;
    }

    /// <summary>
    /// Convert a document file to PDF.
    /// </summary>
    /// <param name="inputPath">Path to input document (.docx, .xlsx, .pptx).</param>
    /// <param name="outputPath">Path for output PDF file.</param>
    /// <param name="options">PDF conversion options. Null for defaults.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>
    /// Conversion result with diagnostics. Check <see cref="ConversionResult.Success"/>
    /// or use implicit bool conversion. Call <see cref="ConversionResult.ThrowIfFailed"/>
    /// to throw on failure.
    /// </returns>
    public async Task<ConversionResult> ConvertAsync(
        string inputPath,
        string outputPath,
        ConversionOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrEmpty(inputPath);
        ArgumentException.ThrowIfNullOrEmpty(outputPath);

        inputPath = Path.GetFullPath(inputPath);
        outputPath = Path.GetFullPath(outputPath);

        if (!File.Exists(inputPath))
            return ConversionResult.Fail(
                $"Input file not found: {inputPath}",
                SlimLOErrorCode.FileNotFound, null);

        var format = DetectFormat(inputPath);
        var requestId = Interlocked.Increment(ref _requestId);

        var request = new ConvertRequest
        {
            Id = requestId,
            Input = inputPath,
            Output = outputPath,
            Format = (int)format,
            Options = ConvertRequestOptions.FromConversionOptions(options)
        };

        return await _pool.ExecuteAsync(request, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Convert an in-memory document to PDF bytes.
    /// </summary>
    /// <param name="input">Input document bytes.</param>
    /// <param name="format">Document format (required — cannot auto-detect from bytes).</param>
    /// <param name="options">PDF conversion options. Null for defaults.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>
    /// Conversion result with PDF bytes in <see cref="ConversionResult{T}.Data"/>.
    /// Data is null if conversion failed.
    /// </returns>
    public async Task<ConversionResult<byte[]>> ConvertAsync(
        ReadOnlyMemory<byte> input,
        DocumentFormat format,
        ConversionOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (input.IsEmpty)
            return ConversionResult<byte[]>.Fail(
                "Input data is empty",
                SlimLOErrorCode.InvalidArgument, null);

        if (format == DocumentFormat.Unknown)
            return ConversionResult<byte[]>.Fail(
                "Format must be specified for buffer conversion",
                SlimLOErrorCode.InvalidFormat, null);

        var ext = format switch
        {
            DocumentFormat.Docx => ".docx",
            DocumentFormat.Xlsx => ".xlsx",
            DocumentFormat.Pptx => ".pptx",
            _ => ".tmp"
        };

        var tempDir = Path.Combine(Path.GetTempPath(), "slimlo");
        Directory.CreateDirectory(tempDir);

        var tempInput = Path.Combine(tempDir, $"{Guid.NewGuid():N}{ext}");
        var tempOutput = Path.Combine(tempDir, $"{Guid.NewGuid():N}.pdf");

        try
        {
            await File.WriteAllBytesAsync(tempInput, input.ToArray(), cancellationToken)
                .ConfigureAwait(false);

            var result = await ConvertAsync(tempInput, tempOutput, options, cancellationToken)
                .ConfigureAwait(false);

            if (result.Success && File.Exists(tempOutput))
            {
                var pdfBytes = await File.ReadAllBytesAsync(tempOutput, cancellationToken)
                    .ConfigureAwait(false);
                return ConversionResult<byte[]>.Ok(pdfBytes, result.Diagnostics);
            }

            return ConversionResult<byte[]>.Fail(
                result.ErrorMessage ?? "Conversion failed",
                result.ErrorCode ?? SlimLOErrorCode.Unknown,
                result.Diagnostics);
        }
        finally
        {
            try { File.Delete(tempInput); } catch { /* best effort */ }
            try { File.Delete(tempOutput); } catch { /* best effort */ }
        }
    }

    /// <summary>
    /// Get the SlimLO library version string.
    /// Falls back to native in-process call if no workers are running.
    /// </summary>
    public static string? Version
    {
        get
        {
            try
            {
                return NativeMethods.GetVersion();
            }
            catch
            {
                return null;
            }
        }
    }

    /// <summary>Dispose the converter and all worker processes.</summary>
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await _pool.DisposeAsync().ConfigureAwait(false);
    }

    /// <summary>Synchronous dispose fallback.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _pool.DisposeAsync().AsTask().GetAwaiter().GetResult();
    }

    private static DocumentFormat DetectFormat(string path)
    {
        var ext = Path.GetExtension(path);
        return ext?.ToLowerInvariant() switch
        {
            ".docx" => DocumentFormat.Docx,
            ".xlsx" => DocumentFormat.Xlsx,
            ".pptx" => DocumentFormat.Pptx,
            _ => DocumentFormat.Unknown
        };
    }
}
