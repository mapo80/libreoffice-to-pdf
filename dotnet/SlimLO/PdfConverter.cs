using System.Runtime.InteropServices;
using SlimLO.Native;

namespace SlimLO;

/// <summary>
/// High-level API for converting OOXML documents to PDF.
/// Wraps the SlimLO native library (built on LibreOffice).
///
/// Thread safety: All conversion calls are serialized internally.
/// For concurrent conversions, use multiple processes.
///
/// Usage:
///   using var converter = PdfConverter.Create("/path/to/slimlo/resources");
///   converter.ConvertToPdf("input.docx", "output.pdf");
/// </summary>
public sealed class PdfConverter : IDisposable
{
    private IntPtr _handle;
    private bool _disposed;
    private static readonly object _initLock = new();
    private static PdfConverter? _instance;

    private PdfConverter(string resourcePath)
    {
        _handle = NativeMethods.Init(resourcePath);
        if (_handle == IntPtr.Zero)
        {
            var error = NativeMethods.GetErrorMessage(IntPtr.Zero) ?? "Unknown initialization error";
            throw new SlimLOException(error, SlimLOErrorCode.InitFailed);
        }
    }

    /// <summary>
    /// Create a new PdfConverter instance.
    /// Only one instance may exist per process (LibreOffice limitation).
    /// </summary>
    /// <param name="resourcePath">
    /// Path to the SlimLO resources directory (containing program/, share/, etc.).
    /// If null, attempts auto-detection from the native library location.
    /// </param>
    public static PdfConverter Create(string? resourcePath = null)
    {
        lock (_initLock)
        {
            if (_instance != null && !_instance._disposed)
                throw new InvalidOperationException(
                    "Only one PdfConverter instance is allowed per process. " +
                    "Dispose the existing instance before creating a new one.");

            var path = resourcePath ?? DetectResourcePath();
            _instance = new PdfConverter(path);
            return _instance;
        }
    }

    /// <summary>
    /// Convert a document file to PDF.
    /// </summary>
    /// <param name="inputPath">Path to input document (.docx, .xlsx, .pptx).</param>
    /// <param name="outputPath">Path for output PDF file.</param>
    /// <param name="options">PDF conversion options (null for defaults).</param>
    public void ConvertToPdf(string inputPath, string outputPath, PdfOptions? options = null)
    {
        ThrowIfDisposed();

        if (string.IsNullOrEmpty(inputPath))
            throw new ArgumentException("Input path is required.", nameof(inputPath));
        if (string.IsNullOrEmpty(outputPath))
            throw new ArgumentException("Output path is required.", nameof(outputPath));

        var format = DetectFormat(inputPath);
        int result;

        if (options == null)
        {
            result = NativeMethods.ConvertFileNoOptions(
                _handle, inputPath, outputPath, (int)format, IntPtr.Zero);
        }
        else
        {
            using var nativeOptions = MarshalOptions(options);
            var opts = nativeOptions.Value;
            result = NativeMethods.ConvertFile(
                _handle, inputPath, outputPath, (int)format, ref opts);
        }

        if (result != 0)
        {
            var error = NativeMethods.GetErrorMessage(_handle) ?? "Conversion failed";
            throw new SlimLOException(error, (SlimLOErrorCode)result);
        }
    }

    /// <summary>
    /// Convert a document from a byte array to PDF.
    /// </summary>
    /// <param name="input">Input document bytes.</param>
    /// <param name="format">Document format (required for buffer conversion).</param>
    /// <param name="options">PDF conversion options (null for defaults).</param>
    /// <returns>PDF file bytes.</returns>
    public byte[] ConvertToPdf(ReadOnlySpan<byte> input, DocumentFormat format, PdfOptions? options = null)
    {
        ThrowIfDisposed();

        if (input.IsEmpty)
            throw new ArgumentException("Input data is required.", nameof(input));
        if (format == DocumentFormat.Unknown)
            throw new ArgumentException("Format must be specified for buffer conversion.", nameof(format));

        unsafe
        {
            fixed (byte* inputPtr = input)
            {
                int result;
                IntPtr outputData;
                nuint outputSize;

                if (options == null)
                {
                    result = NativeMethods.ConvertBufferNoOptions(
                        _handle, (IntPtr)inputPtr, (nuint)input.Length,
                        (int)format, IntPtr.Zero, out outputData, out outputSize);
                }
                else
                {
                    using var nativeOptions = MarshalOptions(options);
                    var opts = nativeOptions.Value;
                    result = NativeMethods.ConvertBuffer(
                        _handle, (IntPtr)inputPtr, (nuint)input.Length,
                        (int)format, ref opts, out outputData, out outputSize);
                }

                if (result != 0)
                {
                    var error = NativeMethods.GetErrorMessage(_handle) ?? "Conversion failed";
                    throw new SlimLOException(error, (SlimLOErrorCode)result);
                }

                try
                {
                    var output = new byte[(int)outputSize];
                    Marshal.Copy(outputData, output, 0, (int)outputSize);
                    return output;
                }
                finally
                {
                    NativeMethods.FreeBuffer(outputData);
                }
            }
        }
    }

    /// <summary>
    /// Convert a document file to PDF asynchronously.
    /// Runs the conversion on the thread pool since LibreOffice is synchronous.
    /// </summary>
    public Task ConvertToPdfAsync(string inputPath, string outputPath,
        PdfOptions? options = null, CancellationToken cancellationToken = default)
    {
        return Task.Run(() => ConvertToPdf(inputPath, outputPath, options), cancellationToken);
    }

    /// <summary>
    /// Convert a document from a byte array to PDF asynchronously.
    /// </summary>
    public Task<byte[]> ConvertToPdfAsync(byte[] input, DocumentFormat format,
        PdfOptions? options = null, CancellationToken cancellationToken = default)
    {
        return Task.Run(() => ConvertToPdf(input, format, options), cancellationToken);
    }

    /// <summary>
    /// Get the SlimLO library version string.
    /// </summary>
    public static string? GetVersion() => NativeMethods.GetVersion();

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_handle != IntPtr.Zero)
        {
            NativeMethods.Destroy(_handle);
            _handle = IntPtr.Zero;
        }

        lock (_initLock)
        {
            if (_instance == this)
                _instance = null;
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private static DocumentFormat DetectFormat(string path)
    {
        var ext = Path.GetExtension(path)?.ToLowerInvariant();
        return ext switch
        {
            ".docx" => DocumentFormat.Docx,
            ".xlsx" => DocumentFormat.Xlsx,
            ".pptx" => DocumentFormat.Pptx,
            _ => DocumentFormat.Unknown
        };
    }

    private static string DetectResourcePath()
    {
        // Try to find resources relative to the native library
        var assemblyDir = Path.GetDirectoryName(typeof(PdfConverter).Assembly.Location);
        if (assemblyDir == null)
            throw new InvalidOperationException("Cannot detect resource path. Provide it explicitly.");

        // Check common locations
        string[] candidates =
        [
            Path.Combine(assemblyDir, "slimlo-resources"),
            Path.Combine(assemblyDir, "..", "slimlo-resources"),
            Path.Combine(assemblyDir, "runtimes", RuntimeInformation.RuntimeIdentifier, "native", "slimlo-resources"),
        ];

        foreach (var candidate in candidates)
        {
            if (Directory.Exists(Path.Combine(candidate, "program")))
                return Path.GetFullPath(candidate);
        }

        // Check SLIMLO_RESOURCE_PATH environment variable
        var envPath = Environment.GetEnvironmentVariable("SLIMLO_RESOURCE_PATH");
        if (!string.IsNullOrEmpty(envPath) && Directory.Exists(Path.Combine(envPath, "program")))
            return envPath;

        throw new InvalidOperationException(
            "Cannot auto-detect SlimLO resource path. " +
            "Set SLIMLO_RESOURCE_PATH environment variable or pass the path to PdfConverter.Create().");
    }

    private static MarshaledOptions MarshalOptions(PdfOptions options)
    {
        return new MarshaledOptions(options);
    }
}

/// <summary>
/// Helper to marshal PdfOptions to native struct, handling string pinning.
/// </summary>
internal sealed class MarshaledOptions : IDisposable
{
    private GCHandle _pageRangeHandle;
    private GCHandle _passwordHandle;
    private byte[]? _pageRangeBytes;
    private byte[]? _passwordBytes;

    public PdfOptionsNative Value { get; }

    public MarshaledOptions(PdfOptions options)
    {
        var native = new PdfOptionsNative
        {
            PdfVersion = (int)options.Version,
            JpegQuality = options.JpegQuality,
            Dpi = options.Dpi,
            TaggedPdf = options.TaggedPdf ? 1 : 0
        };

        if (options.PageRange != null)
        {
            _pageRangeBytes = System.Text.Encoding.UTF8.GetBytes(options.PageRange + '\0');
            _pageRangeHandle = GCHandle.Alloc(_pageRangeBytes, GCHandleType.Pinned);
            native.PageRange = _pageRangeHandle.AddrOfPinnedObject();
        }

        if (options.Password != null)
        {
            _passwordBytes = System.Text.Encoding.UTF8.GetBytes(options.Password + '\0');
            _passwordHandle = GCHandle.Alloc(_passwordBytes, GCHandleType.Pinned);
            native.Password = _passwordHandle.AddrOfPinnedObject();
        }

        Value = native;
    }

    public void Dispose()
    {
        if (_pageRangeHandle.IsAllocated) _pageRangeHandle.Free();
        if (_passwordHandle.IsAllocated) _passwordHandle.Free();
    }
}

/// <summary>
/// Document format for input files.
/// </summary>
public enum DocumentFormat
{
    Unknown = 0,
    Docx = 1,
    Xlsx = 2,
    Pptx = 3
}

/// <summary>
/// PDF output version.
/// </summary>
public enum PdfVersion
{
    Default = 0,
    PdfA1 = 1,
    PdfA2 = 2,
    PdfA3 = 3
}

/// <summary>
/// PDF conversion options.
/// </summary>
public record PdfOptions
{
    /// <summary>PDF version (Default = PDF 1.7).</summary>
    public PdfVersion Version { get; init; } = PdfVersion.Default;

    /// <summary>JPEG compression quality 1-100 (0 = default 90).</summary>
    public int JpegQuality { get; init; } = 0;

    /// <summary>Maximum image resolution in DPI (0 = default 300).</summary>
    public int Dpi { get; init; } = 0;

    /// <summary>Generate tagged PDF for accessibility.</summary>
    public bool TaggedPdf { get; init; } = false;

    /// <summary>Page range, e.g. "1-3" (null = all pages).</summary>
    public string? PageRange { get; init; }

    /// <summary>Password for protected documents (null = none).</summary>
    public string? Password { get; init; }
}

/// <summary>
/// Error codes from the SlimLO native library.
/// </summary>
public enum SlimLOErrorCode
{
    Ok = 0,
    InitFailed = 1,
    LoadFailed = 2,
    ExportFailed = 3,
    InvalidFormat = 4,
    FileNotFound = 5,
    OutOfMemory = 6,
    PermissionDenied = 7,
    AlreadyInitialized = 8,
    NotInitialized = 9,
    InvalidArgument = 10,
    Unknown = 99
}

/// <summary>
/// Exception thrown by SlimLO operations.
/// </summary>
public class SlimLOException : Exception
{
    public SlimLOErrorCode ErrorCode { get; }

    public SlimLOException(string message, SlimLOErrorCode errorCode = SlimLOErrorCode.Unknown)
        : base(message)
    {
        ErrorCode = errorCode;
    }
}
