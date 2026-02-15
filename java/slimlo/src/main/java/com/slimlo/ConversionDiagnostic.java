package com.slimlo;

/**
 * A single diagnostic entry from a PDF conversion operation.
 * Diagnostics include font substitution warnings, layout issues,
 * and other non-fatal observations collected during conversion.
 */
public final class ConversionDiagnostic {

    private final DiagnosticSeverity severity;
    private final DiagnosticCategory category;
    private final String message;
    private final String fontName;
    private final String substitutedWith;

    public ConversionDiagnostic(
            DiagnosticSeverity severity,
            DiagnosticCategory category,
            String message,
            String fontName,
            String substitutedWith) {
        this.severity = severity;
        this.category = category;
        this.message = message;
        this.fontName = fontName;
        this.substitutedWith = substitutedWith;
    }

    /** Severity level (INFO or WARNING). */
    public DiagnosticSeverity getSeverity() {
        return severity;
    }

    /** Category (FONT, LAYOUT, GENERAL). */
    public DiagnosticCategory getCategory() {
        return category;
    }

    /** Human-readable diagnostic message. */
    public String getMessage() {
        return message;
    }

    /** Font name if this is a font-related diagnostic. Null otherwise. */
    public String getFontName() {
        return fontName;
    }

    /** The font that was used as a substitute. Null if no substitution. */
    public String getSubstitutedWith() {
        return substitutedWith;
    }

    @Override
    public String toString() {
        return "[" + severity + ":" + category + "] " + message;
    }
}
