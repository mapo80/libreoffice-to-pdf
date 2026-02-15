package com.slimlo;

import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class ConversionResultTest {

    @Test
    void okResult_isSuccess() {
        ConversionResult result = ConversionResult.ok(null);
        assertTrue(result.isSuccess());
        assertNull(result.getErrorMessage());
        assertNull(result.getErrorCode());
        assertTrue(result.getDiagnostics().isEmpty());
    }

    @Test
    void okResult_withData() {
        byte[] data = new byte[]{1, 2, 3};
        ConversionResult result = ConversionResult.ok(data, null);
        assertTrue(result.isSuccess());
        assertArrayEquals(data, result.getData());
    }

    @Test
    void failResult_isNotSuccess() {
        ConversionResult result = ConversionResult.fail(
                "something went wrong",
                SlimLOErrorCode.EXPORT_FAILED,
                null);
        assertFalse(result.isSuccess());
        assertEquals("something went wrong", result.getErrorMessage());
        assertEquals(SlimLOErrorCode.EXPORT_FAILED, result.getErrorCode());
        assertNull(result.getData());
    }

    @Test
    void throwIfFailed_throwsOnFailure() {
        ConversionResult result = ConversionResult.fail(
                "export failed", SlimLOErrorCode.EXPORT_FAILED, null);

        SlimLOException ex = assertThrows(SlimLOException.class, result::throwIfFailed);
        assertEquals("export failed", ex.getMessage());
        assertEquals(SlimLOErrorCode.EXPORT_FAILED, ex.getErrorCode());
    }

    @Test
    void throwIfFailed_returnsThisOnSuccess() {
        ConversionResult result = ConversionResult.ok(null);
        assertSame(result, result.throwIfFailed());
    }

    @Test
    void hasFontWarnings_trueWhenFontDiagnosticPresent() {
        List<ConversionDiagnostic> diagnostics = Arrays.asList(
                new ConversionDiagnostic(DiagnosticSeverity.WARNING, DiagnosticCategory.FONT,
                        "Font not found: Arial", "Arial", "Liberation Sans")
        );
        ConversionResult result = ConversionResult.ok(diagnostics);
        assertTrue(result.hasFontWarnings());
    }

    @Test
    void hasFontWarnings_falseWhenNoDiagnostics() {
        ConversionResult result = ConversionResult.ok(null);
        assertFalse(result.hasFontWarnings());
    }

    @Test
    void hasFontWarnings_falseWhenOnlyGeneralDiagnostics() {
        List<ConversionDiagnostic> diagnostics = Arrays.asList(
                new ConversionDiagnostic(DiagnosticSeverity.INFO, DiagnosticCategory.GENERAL,
                        "Something happened", null, null)
        );
        ConversionResult result = ConversionResult.ok(diagnostics);
        assertFalse(result.hasFontWarnings());
    }

    @Test
    void diagnostics_areUnmodifiable() {
        List<ConversionDiagnostic> diagnostics = Arrays.asList(
                new ConversionDiagnostic(DiagnosticSeverity.WARNING, DiagnosticCategory.FONT,
                        "Font warning", "Arial", null)
        );
        ConversionResult result = ConversionResult.ok(diagnostics);

        assertThrows(UnsupportedOperationException.class, () ->
                result.getDiagnostics().add(
                        new ConversionDiagnostic(DiagnosticSeverity.INFO, DiagnosticCategory.GENERAL,
                                "test", null, null)));
    }

    @Test
    void failResult_nullDataForFileMode() {
        ConversionResult result = ConversionResult.fail(
                "error", SlimLOErrorCode.LOAD_FAILED, null);
        assertNull(result.getData());
    }

    // --- Enums ---

    @Test
    void documentFormat_fromExtension() {
        assertEquals(DocumentFormat.DOCX, DocumentFormat.fromExtension("test.docx"));
        assertEquals(DocumentFormat.DOCX, DocumentFormat.fromExtension("TEST.DOCX"));
        assertEquals(DocumentFormat.XLSX, DocumentFormat.fromExtension("file.xlsx"));
        assertEquals(DocumentFormat.PPTX, DocumentFormat.fromExtension("slides.pptx"));
        assertEquals(DocumentFormat.UNKNOWN, DocumentFormat.fromExtension("file.pdf"));
        assertEquals(DocumentFormat.UNKNOWN, DocumentFormat.fromExtension(null));
    }

    @Test
    void documentFormat_fromValue() {
        assertEquals(DocumentFormat.DOCX, DocumentFormat.fromValue(1));
        assertEquals(DocumentFormat.UNKNOWN, DocumentFormat.fromValue(99));
    }

    @Test
    void slimLOErrorCode_fromValue() {
        assertEquals(SlimLOErrorCode.OK, SlimLOErrorCode.fromValue(0));
        assertEquals(SlimLOErrorCode.INIT_FAILED, SlimLOErrorCode.fromValue(1));
        assertEquals(SlimLOErrorCode.UNKNOWN, SlimLOErrorCode.fromValue(99));
        assertEquals(SlimLOErrorCode.UNKNOWN, SlimLOErrorCode.fromValue(999));
    }

    @Test
    void diagnosticSeverity_fromString() {
        assertEquals(DiagnosticSeverity.WARNING, DiagnosticSeverity.fromString("warning"));
        assertEquals(DiagnosticSeverity.WARNING, DiagnosticSeverity.fromString("WARNING"));
        assertEquals(DiagnosticSeverity.INFO, DiagnosticSeverity.fromString("info"));
        assertEquals(DiagnosticSeverity.INFO, DiagnosticSeverity.fromString(null));
    }

    @Test
    void diagnosticCategory_fromString() {
        assertEquals(DiagnosticCategory.FONT, DiagnosticCategory.fromString("font"));
        assertEquals(DiagnosticCategory.LAYOUT, DiagnosticCategory.fromString("layout"));
        assertEquals(DiagnosticCategory.GENERAL, DiagnosticCategory.fromString("general"));
        assertEquals(DiagnosticCategory.GENERAL, DiagnosticCategory.fromString(null));
    }

    // --- Options builders ---

    @Test
    void conversionOptions_defaults() {
        ConversionOptions opts = ConversionOptions.builder().build();
        assertEquals(PdfVersion.DEFAULT, opts.getPdfVersion());
        assertEquals(0, opts.getJpegQuality());
        assertEquals(0, opts.getDpi());
        assertFalse(opts.isTaggedPdf());
        assertNull(opts.getPageRange());
        assertNull(opts.getPassword());
    }

    @Test
    void conversionOptions_customValues() {
        ConversionOptions opts = ConversionOptions.builder()
                .pdfVersion(PdfVersion.PDF_A2)
                .jpegQuality(85)
                .dpi(150)
                .taggedPdf(true)
                .pageRange("1-3")
                .password("secret")
                .build();

        assertEquals(PdfVersion.PDF_A2, opts.getPdfVersion());
        assertEquals(85, opts.getJpegQuality());
        assertEquals(150, opts.getDpi());
        assertTrue(opts.isTaggedPdf());
        assertEquals("1-3", opts.getPageRange());
        assertEquals("secret", opts.getPassword());
    }

    @Test
    void pdfConverterOptions_defaults() {
        PdfConverterOptions opts = PdfConverterOptions.builder().build();
        assertNull(opts.getResourcePath());
        assertNull(opts.getFontDirectories());
        assertEquals(300000, opts.getConversionTimeoutMillis());
        assertEquals(1, opts.getMaxWorkers());
        assertEquals(0, opts.getMaxConversionsPerWorker());
        assertFalse(opts.isWarmUp());
    }

    @Test
    void pdfConverterOptions_rejectsInvalidMaxWorkers() {
        assertThrows(IllegalArgumentException.class, () ->
                PdfConverterOptions.builder().maxWorkers(0).build());
    }

    // --- SlimLOException ---

    @Test
    void slimLOException_carriesErrorCode() {
        SlimLOException ex = new SlimLOException("test error", SlimLOErrorCode.LOAD_FAILED);
        assertEquals("test error", ex.getMessage());
        assertEquals(SlimLOErrorCode.LOAD_FAILED, ex.getErrorCode());
    }

    // --- ConversionDiagnostic ---

    @Test
    void conversionDiagnostic_toString() {
        ConversionDiagnostic d = new ConversionDiagnostic(
                DiagnosticSeverity.WARNING, DiagnosticCategory.FONT,
                "Font not found", "Arial", "Liberation Sans");
        assertEquals("[WARNING:FONT] Font not found", d.toString());
        assertEquals("Arial", d.getFontName());
        assertEquals("Liberation Sans", d.getSubstitutedWith());
    }
}
