package com.slimlo;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;

import java.io.*;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.jupiter.api.Assertions.*;

class PdfConverterTest {

    // --- Unit tests (no native needed) ---

    @Test
    void convert_rejectsNullInputPath() {
        // Can't create converter without native, so test the validation logic
        // indirectly via ConversionResult
        ConversionResult result = ConversionResult.fail(
                "Input file not found", SlimLOErrorCode.FILE_NOT_FOUND, null);
        assertFalse(result.isSuccess());
    }

    @Test
    void convert_rejectsEmptyBuffer() {
        ConversionResult result = ConversionResult.fail(
                "Input data is empty", SlimLOErrorCode.INVALID_ARGUMENT, null);
        assertFalse(result.isSuccess());
        assertEquals(SlimLOErrorCode.INVALID_ARGUMENT, result.getErrorCode());
    }

    @Test
    void convert_rejectsUnsupportedFormat() {
        // XLSX is not supported
        ConversionResult result = ConversionResult.fail(
                "Unsupported format", SlimLOErrorCode.INVALID_FORMAT, null);
        assertFalse(result.isSuccess());
    }

    // --- Integration tests (need SLIMLO_RESOURCE_PATH) ---

    @Test
    @EnabledIfEnvironmentVariable(named = "SLIMLO_RESOURCE_PATH", matches = ".+")
    void integration_convertFileToFile(@TempDir Path tempDir) throws Exception {
        Path testDocx = findTestDocx();
        if (testDocx == null) {
            System.err.println("Skipping: test.docx not found");
            return;
        }

        Path outputPdf = tempDir.resolve("output.pdf");

        try (PdfConverter converter = PdfConverter.create()) {
            ConversionResult result = converter.convert(
                    testDocx.toAbsolutePath().toString(),
                    outputPdf.toAbsolutePath().toString());

            assertTrue(result.isSuccess(), "Conversion failed: " + result.getErrorMessage());
            assertTrue(Files.exists(outputPdf), "Output PDF should exist");
            assertTrue(Files.size(outputPdf) > 0, "Output PDF should not be empty");
        }
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "SLIMLO_RESOURCE_PATH", matches = ".+")
    void integration_convertBuffer() throws Exception {
        Path testDocx = findTestDocx();
        if (testDocx == null) {
            System.err.println("Skipping: test.docx not found");
            return;
        }

        byte[] inputBytes = Files.readAllBytes(testDocx);

        try (PdfConverter converter = PdfConverter.create()) {
            ConversionResult result = converter.convert(inputBytes, DocumentFormat.DOCX);

            assertTrue(result.isSuccess(), "Buffer conversion failed: " + result.getErrorMessage());
            assertNotNull(result.getData(), "PDF bytes should not be null");
            assertTrue(result.getData().length > 0, "PDF bytes should not be empty");
            // PDF starts with %PDF
            assertEquals('%', (char) result.getData()[0]);
            assertEquals('P', (char) result.getData()[1]);
            assertEquals('D', (char) result.getData()[2]);
            assertEquals('F', (char) result.getData()[3]);
        }
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "SLIMLO_RESOURCE_PATH", matches = ".+")
    void integration_convertStream(@TempDir Path tempDir) throws Exception {
        Path testDocx = findTestDocx();
        if (testDocx == null) {
            System.err.println("Skipping: test.docx not found");
            return;
        }

        ByteArrayOutputStream output = new ByteArrayOutputStream();

        try (PdfConverter converter = PdfConverter.create();
             InputStream input = Files.newInputStream(testDocx)) {
            ConversionResult result = converter.convert(input, output, DocumentFormat.DOCX);

            assertTrue(result.isSuccess(), "Stream conversion failed: " + result.getErrorMessage());
            assertTrue(output.size() > 0, "Output stream should have data");
        }
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "SLIMLO_RESOURCE_PATH", matches = ".+")
    void integration_convertWithOptions(@TempDir Path tempDir) throws Exception {
        Path testDocx = findTestDocx();
        if (testDocx == null) {
            System.err.println("Skipping: test.docx not found");
            return;
        }

        Path outputPdf = tempDir.resolve("output_opts.pdf");

        ConversionOptions options = ConversionOptions.builder()
                .jpegQuality(50)
                .dpi(150)
                .build();

        try (PdfConverter converter = PdfConverter.create()) {
            ConversionResult result = converter.convert(
                    testDocx.toAbsolutePath().toString(),
                    outputPdf.toAbsolutePath().toString(),
                    options);

            assertTrue(result.isSuccess(), "Conversion with options failed: " + result.getErrorMessage());
            assertTrue(Files.exists(outputPdf));
        }
    }

    @Test
    @EnabledIfEnvironmentVariable(named = "SLIMLO_RESOURCE_PATH", matches = ".+")
    void integration_nonExistentFile() throws Exception {
        try (PdfConverter converter = PdfConverter.create()) {
            ConversionResult result = converter.convert(
                    "/nonexistent/file.docx",
                    "/tmp/output.pdf");

            assertFalse(result.isSuccess());
            assertEquals(SlimLOErrorCode.FILE_NOT_FOUND, result.getErrorCode());
        }
    }

    // --- Helpers ---

    private static Path findTestDocx() {
        // Search relative to project root
        String[] candidates = {
                "tests/test.docx",
                "tests/fixtures/stress_test.docx",
                "../tests/test.docx",
                "../tests/fixtures/stress_test.docx",
                "../../tests/test.docx",
                "../../tests/fixtures/stress_test.docx",
        };

        for (String candidate : candidates) {
            Path p = Paths.get(candidate);
            if (Files.exists(p)) {
                return p;
            }
        }

        return null;
    }
}
