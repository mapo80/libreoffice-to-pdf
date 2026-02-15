namespace SlimLO;

/// <summary>
/// Options for a single PDF conversion operation.
/// </summary>
public sealed class ConversionOptions
{
    /// <summary>PDF version for the output. Default: PDF 1.7.</summary>
    public PdfVersion PdfVersion { get; init; } = PdfVersion.Default;

    /// <summary>JPEG compression quality 1-100. 0 = default (90).</summary>
    public int JpegQuality { get; init; }

    /// <summary>Maximum image resolution in DPI. 0 = default (300).</summary>
    public int Dpi { get; init; }

    /// <summary>Generate tagged PDF for accessibility.</summary>
    public bool TaggedPdf { get; init; }

    /// <summary>Page range string, e.g. "1-3" or "1,3,5-7". Null = all pages.</summary>
    public string? PageRange { get; init; }

    /// <summary>Password for password-protected documents. Null = none.</summary>
    public string? Password { get; init; }
}
