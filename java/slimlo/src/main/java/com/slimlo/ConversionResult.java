package com.slimlo;

import java.util.Collections;
import java.util.List;

/**
 * Result of a PDF conversion operation, including diagnostics.
 *
 * <p>Check {@link #isSuccess()} to determine if the conversion succeeded.
 * Diagnostics may be present even on success (e.g., font substitution warnings).</p>
 *
 * <p>For buffer conversions, call {@link #getData()} to get the PDF bytes.</p>
 */
public class ConversionResult {

    private final boolean success;
    private final String errorMessage;
    private final SlimLOErrorCode errorCode;
    private final List<ConversionDiagnostic> diagnostics;
    private final byte[] data;

    ConversionResult(
            boolean success,
            String errorMessage,
            SlimLOErrorCode errorCode,
            List<ConversionDiagnostic> diagnostics,
            byte[] data) {
        this.success = success;
        this.errorMessage = errorMessage;
        this.errorCode = errorCode;
        this.diagnostics = diagnostics != null
                ? Collections.unmodifiableList(diagnostics)
                : Collections.<ConversionDiagnostic>emptyList();
        this.data = data;
    }

    /** Whether the conversion completed successfully. */
    public boolean isSuccess() {
        return success;
    }

    /** Error message if conversion failed. Null on success. */
    public String getErrorMessage() {
        return errorMessage;
    }

    /** Native error code if conversion failed. Null on success. */
    public SlimLOErrorCode getErrorCode() {
        return errorCode;
    }

    /**
     * Diagnostics collected during conversion (font warnings, layout issues).
     * May be non-empty even on success.
     */
    public List<ConversionDiagnostic> getDiagnostics() {
        return diagnostics;
    }

    /** Whether any font substitution warnings were reported. */
    public boolean hasFontWarnings() {
        for (ConversionDiagnostic d : diagnostics) {
            if (d.getCategory() == DiagnosticCategory.FONT) {
                return true;
            }
        }
        return false;
    }

    /**
     * PDF bytes for buffer conversions. Null for file-path conversions
     * or if conversion failed.
     */
    public byte[] getData() {
        return data;
    }

    /**
     * Throw a {@link SlimLOException} if the conversion failed.
     * Returns this result for fluent chaining on success.
     */
    public ConversionResult throwIfFailed() {
        if (!success) {
            throw new SlimLOException(
                    errorMessage != null ? errorMessage : "Conversion failed",
                    errorCode != null ? errorCode : SlimLOErrorCode.UNKNOWN);
        }
        return this;
    }

    // --- Factory methods ---

    /** Create a successful result (file-path mode). */
    public static ConversionResult ok(List<ConversionDiagnostic> diagnostics) {
        return new ConversionResult(true, null, null, diagnostics, null);
    }

    /** Create a successful result with PDF data (buffer mode). */
    public static ConversionResult ok(byte[] data, List<ConversionDiagnostic> diagnostics) {
        return new ConversionResult(true, null, null, diagnostics, data);
    }

    /** Create a failure result. */
    public static ConversionResult fail(
            String errorMessage,
            SlimLOErrorCode errorCode,
            List<ConversionDiagnostic> diagnostics) {
        return new ConversionResult(false, errorMessage, errorCode, diagnostics, null);
    }
}
