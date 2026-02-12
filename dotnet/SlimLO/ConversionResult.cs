namespace SlimLO;

/// <summary>
/// Result of a PDF conversion operation, including diagnostics.
/// Check <see cref="Success"/> or use implicit bool conversion to determine
/// if the conversion succeeded. Diagnostics may be present even on success
/// (e.g., font substitution warnings).
/// </summary>
public class ConversionResult
{
    private static readonly IReadOnlyList<ConversionDiagnostic> EmptyDiagnostics =
        Array.Empty<ConversionDiagnostic>();

    internal ConversionResult(
        bool success,
        string? errorMessage,
        SlimLOErrorCode? errorCode,
        IReadOnlyList<ConversionDiagnostic>? diagnostics)
    {
        Success = success;
        ErrorMessage = errorMessage;
        ErrorCode = errorCode;
        Diagnostics = diagnostics ?? EmptyDiagnostics;
    }

    /// <summary>Whether the conversion completed successfully.</summary>
    public bool Success { get; }

    /// <summary>Error message if conversion failed. Null on success.</summary>
    public string? ErrorMessage { get; }

    /// <summary>Native error code if conversion failed. Null on success.</summary>
    public SlimLOErrorCode? ErrorCode { get; }

    /// <summary>
    /// Diagnostics collected during conversion (font warnings, layout issues).
    /// May be non-empty even on success — warnings do not prevent conversion.
    /// </summary>
    public IReadOnlyList<ConversionDiagnostic> Diagnostics { get; }

    /// <summary>Whether any font substitution warnings were reported.</summary>
    public bool HasFontWarnings
    {
        get
        {
            for (int i = 0; i < Diagnostics.Count; i++)
            {
                if (Diagnostics[i].Category == DiagnosticCategory.Font)
                    return true;
            }
            return false;
        }
    }

    /// <summary>Implicit bool conversion: true if conversion succeeded.</summary>
    public static implicit operator bool(ConversionResult result) => result.Success;

    /// <summary>
    /// Throw a <see cref="SlimLOException"/> if the conversion failed.
    /// Returns this result for fluent chaining on success.
    /// </summary>
    public ConversionResult ThrowIfFailed()
    {
        if (!Success)
            throw new SlimLOException(
                ErrorMessage ?? "Conversion failed",
                ErrorCode ?? SlimLOErrorCode.Unknown);
        return this;
    }

    internal static ConversionResult Ok(IReadOnlyList<ConversionDiagnostic>? diagnostics) =>
        new(true, null, null, diagnostics);

    internal static ConversionResult Fail(
        string errorMessage,
        SlimLOErrorCode errorCode,
        IReadOnlyList<ConversionDiagnostic>? diagnostics) =>
        new(false, errorMessage, errorCode, diagnostics);
}

/// <summary>
/// Conversion result that also carries output data (for buffer conversions).
/// </summary>
public sealed class ConversionResult<T> : ConversionResult
{
    internal ConversionResult(
        bool success,
        string? errorMessage,
        SlimLOErrorCode? errorCode,
        IReadOnlyList<ConversionDiagnostic>? diagnostics,
        T? data)
        : base(success, errorMessage, errorCode, diagnostics)
    {
        Data = data;
    }

    /// <summary>Output data (e.g., PDF bytes). Null if conversion failed.</summary>
    public T? Data { get; }

    internal static ConversionResult<T> Ok(
        T data,
        IReadOnlyList<ConversionDiagnostic>? diagnostics) =>
        new(true, null, null, diagnostics, data);

    internal static new ConversionResult<T> Fail(
        string errorMessage,
        SlimLOErrorCode errorCode,
        IReadOnlyList<ConversionDiagnostic>? diagnostics) =>
        new(false, errorMessage, errorCode, diagnostics, default);
}
