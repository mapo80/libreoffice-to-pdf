package com.slimlo;

/**
 * Severity level for conversion diagnostics.
 */
public enum DiagnosticSeverity {
    INFO,
    WARNING;

    public static DiagnosticSeverity fromString(String s) {
        if (s == null) return INFO;
        switch (s.toLowerCase()) {
            case "warning": return WARNING;
            default: return INFO;
        }
    }
}
