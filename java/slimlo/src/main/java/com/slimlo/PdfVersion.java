package com.slimlo;

/**
 * PDF output version.
 * Values match the native SlimLOPdfVersion enum in slimlo.h.
 */
public enum PdfVersion {
    /** PDF 1.7 (default). */
    DEFAULT(0),
    /** PDF/A-1b for long-term archival. */
    PDF_A1(1),
    /** PDF/A-2b for long-term archival with improved features. */
    PDF_A2(2),
    /** PDF/A-3b for long-term archival with embedded files. */
    PDF_A3(3);

    private final int value;

    PdfVersion(int value) {
        this.value = value;
    }

    public int getValue() {
        return value;
    }
}
