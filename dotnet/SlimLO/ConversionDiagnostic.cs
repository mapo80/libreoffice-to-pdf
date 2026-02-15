using System;

namespace SlimLO;

/// <summary>
/// A single diagnostic entry from a PDF conversion operation.
/// Diagnostics include font substitution warnings, layout issues,
/// and other non-fatal observations collected during conversion.
/// </summary>
public sealed class ConversionDiagnostic
{
    public ConversionDiagnostic(
        DiagnosticSeverity severity,
        DiagnosticCategory category,
        string message,
        string? fontName = null,
        string? substitutedWith = null)
    {
        Severity = severity;
        Category = category;
        Message = message;
        FontName = fontName;
        SubstitutedWith = substitutedWith;
    }

    /// <summary>Severity level (Info or Warning).</summary>
    public DiagnosticSeverity Severity { get; }

    /// <summary>Category (Font, Layout, General).</summary>
    public DiagnosticCategory Category { get; }

    /// <summary>Human-readable diagnostic message.</summary>
    public string Message { get; }

    /// <summary>Font name if this is a font-related diagnostic. Null otherwise.</summary>
    public string? FontName { get; }

    /// <summary>
    /// The font that was used as a substitute, if this is a font substitution warning.
    /// Null if no substitution occurred or if this is not a font diagnostic.
    /// </summary>
    public string? SubstitutedWith { get; }

    public override string ToString() =>
        $"[{Severity}:{Category}] {Message}";
}
