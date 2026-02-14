using SlimLO.Internal;

namespace SlimLO;

/// <summary>
/// Enterprise-grade PDF converter for DOCX-to-PDF conversion.
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
/// <para><b>Conversion modes:</b> The converter uses two IPC strategies depending on the overload:
/// <list type="bullet">
/// <item><b>File-path mode</b> — <see cref="ConvertAsync(string, string, ConversionOptions?, CancellationToken)"/>
/// sends only file paths to the worker. The worker reads/writes files directly via LibreOffice's
/// <c>file://</c> URLs. The .NET process never loads document or PDF bytes into memory.
/// Best for batch processing and large files.</item>
/// <item><b>Buffer mode</b> — All other overloads send document bytes as binary frames over the
/// IPC pipe. LibreOffice loads via <c>private:stream</c> (pure in-memory, zero disk I/O) and
/// returns PDF bytes the same way. Best for web servers and in-memory pipelines.</item>
/// </list></para>
///
/// <para><b>Supported formats:</b> SlimLO currently supports DOCX only.
/// <see cref="DocumentFormat.Xlsx"/> and <see cref="DocumentFormat.Pptx"/> are kept for
/// binary compatibility but return <see cref="SlimLOErrorCode.InvalidFormat"/> at runtime.</para>
///
/// <example>
/// <code>
/// await using var converter = PdfConverter.Create(new PdfConverterOptions
/// {
///     FontDirectories = ["/usr/share/fonts/custom"],
///     MaxWorkers = 2
/// });
///
/// // File to file
/// var result = await converter.ConvertAsync("input.docx", "output.pdf");
///
/// // Stream to stream (e.g., ASP.NET controller)
/// var result = await converter.ConvertAsync(
///     Request.Body, Response.Body, DocumentFormat.Docx);
///
/// // Buffer to buffer
/// var result = await converter.ConvertAsync(docxBytes, DocumentFormat.Docx);
/// byte[] pdf = result.Data;
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
    /// <param name="inputPath">Path to input document (.docx only).</param>
    /// <param name="outputPath">Path for output PDF file.</param>
    /// <param name="options">PDF conversion options. Null for defaults.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>
    /// Conversion result with diagnostics. Check <see cref="ConversionResult.Success"/>
    /// or use implicit bool conversion. Call <see cref="ConversionResult.ThrowIfFailed"/>
    /// to throw on failure.
    /// </returns>
    /// <remarks>
    /// Uses <b>file-path IPC</b>: only file paths are sent to the worker process.
    /// The worker reads the input and writes the PDF directly — the .NET process never
    /// loads the document or PDF bytes into memory. This is the most memory-efficient
    /// overload and is recommended for batch processing and large files.
    /// The document format is auto-detected from the file extension.
    /// </remarks>
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
        if (!IsSupportedFormat(format))
            return InvalidFormatFailure(format, "file conversion");

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
    /// <remarks>
    /// Uses <b>buffer IPC</b>: document bytes are sent as binary frames to the worker, which
    /// loads them via LibreOffice's <c>private:stream</c> (pure in-memory, zero disk I/O).
    /// PDF bytes are returned the same way. Both input and output are held in .NET memory.
    /// Ideal for in-memory pipelines (database blobs, message queues, blob storage).
    /// </remarks>
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

        if (!IsSupportedFormat(format))
            return InvalidFormatFailureBytes(format, "buffer conversion");

        return await ConvertBufferCoreAsync(input, format, options, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Convert a document stream to PDF, writing to an output stream.
    /// </summary>
    /// <param name="input">Readable stream containing input document bytes.</param>
    /// <param name="output">Writable stream where PDF bytes will be written.</param>
    /// <param name="format">Document format (required — cannot auto-detect from a stream).</param>
    /// <param name="options">PDF conversion options. Null for defaults.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Conversion result with diagnostics. PDF bytes are written to <paramref name="output"/>.</returns>
    /// <remarks>
    /// Uses <b>buffer IPC</b>: the input stream is fully read into memory, sent as binary frames
    /// to the worker, and the resulting PDF bytes are written to the output stream.
    /// No temporary files are created. Ideal for ASP.NET controllers piping
    /// <c>Request.Body</c> to <c>Response.Body</c>.
    /// </remarks>
    public async Task<ConversionResult> ConvertAsync(
        Stream input,
        Stream output,
        DocumentFormat format,
        ConversionOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(output);

        if (!input.CanRead)
            return ConversionResult.Fail("Input stream is not readable",
                SlimLOErrorCode.InvalidArgument, null);
        if (!output.CanWrite)
            return ConversionResult.Fail("Output stream is not writable",
                SlimLOErrorCode.InvalidArgument, null);
        if (!IsSupportedFormat(format))
            return InvalidFormatFailure(format, "stream conversion");

        var inputBytes = await ReadStreamToMemoryAsync(input, cancellationToken).ConfigureAwait(false);
        var result = await ConvertBufferCoreAsync(inputBytes, format, options, cancellationToken)
            .ConfigureAwait(false);

        if (result.Success && result.Data is not null)
            await output.WriteAsync(result.Data, cancellationToken).ConfigureAwait(false);

        return result.AsBase();
    }

    /// <summary>
    /// Convert a document stream to a PDF file.
    /// </summary>
    /// <param name="input">Readable stream containing input document bytes.</param>
    /// <param name="outputPath">Path for output PDF file.</param>
    /// <param name="format">Document format (required — cannot auto-detect from a stream).</param>
    /// <param name="options">PDF conversion options. Null for defaults.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Conversion result with diagnostics.</returns>
    /// <remarks>
    /// Uses <b>buffer IPC</b>: the input stream is read into memory, converted via binary
    /// IPC, and the resulting PDF bytes are written to disk. No temporary files are created
    /// during conversion — only the final output file is written.
    /// </remarks>
    public async Task<ConversionResult> ConvertAsync(
        Stream input,
        string outputPath,
        DocumentFormat format,
        ConversionOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(input);
        ArgumentException.ThrowIfNullOrEmpty(outputPath);

        if (!input.CanRead)
            return ConversionResult.Fail("Input stream is not readable",
                SlimLOErrorCode.InvalidArgument, null);
        if (!IsSupportedFormat(format))
            return InvalidFormatFailure(format, "stream conversion");

        var inputBytes = await ReadStreamToMemoryAsync(input, cancellationToken).ConfigureAwait(false);
        var result = await ConvertBufferCoreAsync(inputBytes, format, options, cancellationToken)
            .ConfigureAwait(false);

        if (result.Success && result.Data is not null)
            await File.WriteAllBytesAsync(outputPath, result.Data, cancellationToken)
                .ConfigureAwait(false);

        return result.AsBase();
    }

    /// <summary>
    /// Convert a document file to PDF, writing to an output stream.
    /// </summary>
    /// <param name="inputPath">Path to input document (.docx only).</param>
    /// <param name="output">Writable stream where PDF bytes will be written.</param>
    /// <param name="options">PDF conversion options. Null for defaults.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Conversion result with diagnostics. PDF bytes are written to <paramref name="output"/>.</returns>
    /// <remarks>
    /// Uses <b>buffer IPC</b>: the input file is read into .NET memory, sent as binary frames
    /// to the worker, and the resulting PDF bytes are written to the output stream.
    /// For large files where the output must be a stream, consider using the file-to-file
    /// overload and then reading the output file separately.
    /// </remarks>
    public async Task<ConversionResult> ConvertAsync(
        string inputPath,
        Stream output,
        ConversionOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrEmpty(inputPath);
        ArgumentNullException.ThrowIfNull(output);

        if (!output.CanWrite)
            return ConversionResult.Fail("Output stream is not writable",
                SlimLOErrorCode.InvalidArgument, null);

        inputPath = Path.GetFullPath(inputPath);

        if (!File.Exists(inputPath))
            return ConversionResult.Fail(
                $"Input file not found: {inputPath}",
                SlimLOErrorCode.FileNotFound, null);

        var format = DetectFormat(inputPath);
        if (!IsSupportedFormat(format))
            return InvalidFormatFailure(format, "file conversion");

        var inputBytes = await File.ReadAllBytesAsync(inputPath, cancellationToken)
            .ConfigureAwait(false);
        var result = await ConvertBufferCoreAsync(inputBytes, format, options, cancellationToken)
            .ConfigureAwait(false);

        if (result.Success && result.Data is not null)
            await output.WriteAsync(result.Data, cancellationToken).ConfigureAwait(false);

        return result.AsBase();
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

    private static bool IsSupportedFormat(DocumentFormat format) =>
        format == DocumentFormat.Docx;

    private static ConversionResult InvalidFormatFailure(DocumentFormat format, string context)
    {
        var message = format switch
        {
            DocumentFormat.Unknown =>
                $"Unsupported input format for {context}. SlimLO currently supports DOCX (.docx) only.",
            _ =>
                $"Unsupported format '{format}' for {context}. SlimLO currently supports DOCX (.docx) only."
        };

        return ConversionResult.Fail(message, SlimLOErrorCode.InvalidFormat, null);
    }

    private static ConversionResult<byte[]> InvalidFormatFailureBytes(DocumentFormat format, string context)
    {
        var message = format switch
        {
            DocumentFormat.Unknown =>
                $"Format must be specified as DocumentFormat.Docx for {context}.",
            _ =>
                $"Unsupported format '{format}' for {context}. SlimLO currently supports DOCX (.docx) only."
        };

        return ConversionResult<byte[]>.Fail(message, SlimLOErrorCode.InvalidFormat, null);
    }

    /// <summary>Core buffer conversion via binary IPC (no temp files).</summary>
    private async Task<ConversionResult<byte[]>> ConvertBufferCoreAsync(
        ReadOnlyMemory<byte> input,
        DocumentFormat format,
        ConversionOptions? options,
        CancellationToken ct)
    {
        var requestId = Interlocked.Increment(ref _requestId);
        var request = new ConvertBufferRequest
        {
            Id = requestId,
            Format = (int)format,
            DataSize = input.Length,
            Options = ConvertRequestOptions.FromConversionOptions(options)
        };

        return await _pool.ExecuteBufferAsync(request, input, ct).ConfigureAwait(false);
    }

    private static async Task<ReadOnlyMemory<byte>> ReadStreamToMemoryAsync(
        Stream stream, CancellationToken ct)
    {
        if (stream is MemoryStream ms && ms.TryGetBuffer(out var segment))
        {
            return segment.AsMemory()[(int)(ms.Position - segment.Offset)..];
        }

        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer, ct).ConfigureAwait(false);
        return buffer.ToArray();
    }
}
