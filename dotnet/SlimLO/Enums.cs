namespace SlimLO;

/// <summary>
/// Document format for input files.
/// Values match the native SlimLOFormat enum in slimlo.h.
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
/// Values match the native SlimLOPdfVersion enum in slimlo.h.
/// </summary>
public enum PdfVersion
{
    /// <summary>PDF 1.7 (default).</summary>
    Default = 0,
    /// <summary>PDF/A-1b for long-term archival.</summary>
    PdfA1 = 1,
    /// <summary>PDF/A-2b for long-term archival with improved features.</summary>
    PdfA2 = 2,
    /// <summary>PDF/A-3b for long-term archival with embedded files.</summary>
    PdfA3 = 3
}

/// <summary>
/// Error codes from the SlimLO native library.
/// Values match the native SlimLOError enum in slimlo.h.
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
/// Severity level for conversion diagnostics.
/// </summary>
public enum DiagnosticSeverity
{
    Info,
    Warning
}

/// <summary>
/// Category of a conversion diagnostic.
/// </summary>
public enum DiagnosticCategory
{
    General,
    Font,
    Layout
}
