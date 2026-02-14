namespace SlimLO;

/// <summary>
/// Configuration for creating a <see cref="PdfConverter"/> instance.
/// </summary>
public sealed class PdfConverterOptions
{
    /// <summary>
    /// Path to the SlimLO resources directory (containing program/, share/).
    /// If null, auto-detected from the native library location or
    /// the SLIMLO_RESOURCE_PATH environment variable.
    /// </summary>
    public string? ResourcePath { get; init; }

    /// <summary>
    /// Additional font directories to make available during conversion.
    /// These directories are passed to LibreOffice via SAL_FONTPATH.
    /// Fonts must be present at converter creation time; changes require
    /// creating a new PdfConverter instance.
    /// </summary>
    public IReadOnlyList<string>? FontDirectories { get; init; }

    /// <summary>
    /// Maximum time to wait for a single conversion to complete.
    /// After this timeout, the worker process is killed and the conversion
    /// fails with a TimeoutException. Default: 5 minutes.
    /// </summary>
    public TimeSpan ConversionTimeout { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>
    /// Maximum number of worker processes. Each worker can handle one
    /// conversion at a time. More workers = more parallel conversions,
    /// but more memory usage (~200 MB per worker). Default: 1.
    /// </summary>
    public int MaxWorkers { get; init; } = 1;

    /// <summary>
    /// Recycle a worker process after this many conversions to prevent
    /// memory leaks from accumulating. 0 = never recycle. Default: 0.
    /// </summary>
    public int MaxConversionsPerWorker { get; init; }

    /// <summary>
    /// If true, start worker processes eagerly during Create().
    /// If false (default), workers start lazily on first conversion.
    /// </summary>
    public bool WarmUp { get; init; }

}
