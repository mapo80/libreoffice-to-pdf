package com.slimlo;

/**
 * Document format for input files.
 * Values match the native SlimLOFormat enum in slimlo.h.
 * SlimLO currently supports DOCX only; XLSX/PPTX are retained for
 * binary compatibility and return INVALID_FORMAT at runtime.
 */
public enum DocumentFormat {
    UNKNOWN(0),
    DOCX(1),
    XLSX(2),
    PPTX(3);

    private final int value;

    DocumentFormat(int value) {
        this.value = value;
    }

    public int getValue() {
        return value;
    }

    public static DocumentFormat fromValue(int value) {
        for (DocumentFormat f : values()) {
            if (f.value == value) return f;
        }
        return UNKNOWN;
    }

    /**
     * Detect format from file extension.
     */
    public static DocumentFormat fromExtension(String path) {
        if (path == null) return UNKNOWN;
        String lower = path.toLowerCase();
        if (lower.endsWith(".docx")) return DOCX;
        if (lower.endsWith(".xlsx")) return XLSX;
        if (lower.endsWith(".pptx")) return PPTX;
        return UNKNOWN;
    }
}
