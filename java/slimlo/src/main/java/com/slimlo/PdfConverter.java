package com.slimlo;

import com.slimlo.internal.WorkerLocator;
import com.slimlo.internal.WorkerPool;

import java.io.*;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Enterprise-grade PDF converter for DOCX-to-PDF conversion.
 *
 * <p><b>Thread safety:</b> All methods are fully thread-safe. Multiple threads
 * can call {@link #convert(String, String)} concurrently. With
 * {@link PdfConverterOptions.Builder#maxWorkers(int)} greater than 1,
 * conversions run in parallel across separate worker processes.</p>
 *
 * <p><b>Crash resilience:</b> Conversions run in isolated worker processes.
 * If LibreOffice crashes on a malformed document, the worker is automatically
 * replaced and the conversion returns a failure result. The host JVM is never affected.</p>
 *
 * <p><b>Conversion modes:</b></p>
 * <ul>
 *   <li><b>File-path mode</b> -- sends only file paths to the worker. The worker
 *       reads/writes files directly. Memory-efficient for large files.</li>
 *   <li><b>Buffer mode</b> -- sends document bytes as binary frames. Zero disk I/O.
 *       Ideal for in-memory pipelines.</li>
 * </ul>
 *
 * <p><b>Usage:</b></p>
 * <pre>{@code
 * try (PdfConverter converter = PdfConverter.create()) {
 *     ConversionResult result = converter.convert("input.docx", "output.pdf");
 *     if (result.isSuccess()) {
 *         System.out.println("OK");
 *     }
 * }
 * }</pre>
 */
public final class PdfConverter implements Closeable {

    private final WorkerPool pool;
    private volatile boolean disposed;
    private final AtomicInteger requestId = new AtomicInteger(0);

    private PdfConverter(WorkerPool pool) {
        this.pool = pool;
    }

    /**
     * Create a new PdfConverter with default options.
     *
     * @return a new PdfConverter instance. Close when no longer needed.
     * @throws FileNotFoundException if worker executable not found.
     * @throws IllegalStateException if resource path cannot be auto-detected.
     */
    public static PdfConverter create() throws FileNotFoundException {
        return create(PdfConverterOptions.builder().build());
    }

    /**
     * Create a new PdfConverter with custom options.
     *
     * @param options converter configuration.
     * @return a new PdfConverter instance. Close when no longer needed.
     * @throws FileNotFoundException if worker executable not found.
     * @throws IllegalStateException if resource path cannot be auto-detected.
     */
    public static PdfConverter create(PdfConverterOptions options) throws FileNotFoundException {
        if (options == null) {
            options = PdfConverterOptions.builder().build();
        }

        String workerPath = WorkerLocator.findWorkerExecutable();
        String resourcePath = options.getResourcePath() != null
                ? options.getResourcePath()
                : WorkerLocator.findResourcePath();

        WorkerPool pool = new WorkerPool(
                workerPath,
                resourcePath,
                options.getFontDirectories(),
                options.getMaxWorkers(),
                options.getMaxConversionsPerWorker(),
                options.getConversionTimeoutMillis());

        PdfConverter converter = new PdfConverter(pool);

        if (options.isWarmUp()) {
            try {
                pool.warmUp();
            } catch (IOException e) {
                pool.close();
                throw new SlimLOException("Failed to warm up workers: " + e.getMessage(),
                        SlimLOErrorCode.INIT_FAILED, e);
            }
        }

        return converter;
    }

    // ---- File-to-file conversion (file-path IPC) ----

    /**
     * Convert a document file to PDF.
     *
     * @param inputPath  path to input document (.docx).
     * @param outputPath path for output PDF file.
     * @return conversion result with diagnostics.
     */
    public ConversionResult convert(String inputPath, String outputPath) {
        return convert(inputPath, outputPath, null);
    }

    /**
     * Convert a document file to PDF with options.
     *
     * @param inputPath  path to input document (.docx).
     * @param outputPath path for output PDF file.
     * @param options    PDF conversion options, or null for defaults.
     * @return conversion result with diagnostics.
     */
    public ConversionResult convert(String inputPath, String outputPath, ConversionOptions options) {
        checkDisposed();
        if (inputPath == null || inputPath.isEmpty()) {
            throw new IllegalArgumentException("inputPath must not be null or empty");
        }
        if (outputPath == null || outputPath.isEmpty()) {
            throw new IllegalArgumentException("outputPath must not be null or empty");
        }

        File inputFile = new File(inputPath).getAbsoluteFile();
        File outputFile = new File(outputPath).getAbsoluteFile();

        if (!inputFile.exists()) {
            return ConversionResult.fail("Input file not found: " + inputFile.getAbsolutePath(),
                    SlimLOErrorCode.FILE_NOT_FOUND, null);
        }

        DocumentFormat format = DocumentFormat.fromExtension(inputPath);
        if (format != DocumentFormat.DOCX) {
            return invalidFormatFailure(format);
        }

        int id = requestId.incrementAndGet();
        Map<String, Object> request = new HashMap<String, Object>();
        request.put("type", "convert");
        request.put("id", id);
        request.put("input", inputFile.getAbsolutePath());
        request.put("output", outputFile.getAbsolutePath());
        request.put("format", format.getValue());
        addOptions(request, options);

        return pool.execute(request);
    }

    // ---- Buffer conversion (binary IPC) ----

    /**
     * Convert in-memory document bytes to PDF bytes.
     *
     * @param input  input document bytes.
     * @param format document format (must be DOCX).
     * @return conversion result with PDF bytes in {@link ConversionResult#getData()}.
     */
    public ConversionResult convert(byte[] input, DocumentFormat format) {
        return convert(input, format, null);
    }

    /**
     * Convert in-memory document bytes to PDF bytes with options.
     *
     * @param input   input document bytes.
     * @param format  document format (must be DOCX).
     * @param options PDF conversion options, or null for defaults.
     * @return conversion result with PDF bytes in {@link ConversionResult#getData()}.
     */
    public ConversionResult convert(byte[] input, DocumentFormat format, ConversionOptions options) {
        checkDisposed();
        if (input == null || input.length == 0) {
            return ConversionResult.fail("Input data is empty", SlimLOErrorCode.INVALID_ARGUMENT, null);
        }
        if (format != DocumentFormat.DOCX) {
            return invalidFormatFailure(format);
        }

        return convertBufferCore(input, format, options);
    }

    // ---- Stream conversion (binary IPC) ----

    /**
     * Convert a document stream to PDF, writing to an output stream.
     *
     * @param input  readable stream containing document bytes.
     * @param output writable stream where PDF bytes will be written.
     * @param format document format (must be DOCX).
     * @return conversion result with diagnostics.
     */
    public ConversionResult convert(InputStream input, OutputStream output, DocumentFormat format) {
        return convert(input, output, format, null);
    }

    /**
     * Convert a document stream to PDF, writing to an output stream.
     *
     * @param input   readable stream containing document bytes.
     * @param output  writable stream where PDF bytes will be written.
     * @param format  document format (must be DOCX).
     * @param options PDF conversion options, or null for defaults.
     * @return conversion result with diagnostics.
     */
    public ConversionResult convert(InputStream input, OutputStream output,
                                    DocumentFormat format, ConversionOptions options) {
        checkDisposed();
        if (input == null) throw new IllegalArgumentException("input must not be null");
        if (output == null) throw new IllegalArgumentException("output must not be null");
        if (format != DocumentFormat.DOCX) {
            return invalidFormatFailure(format);
        }

        try {
            byte[] inputBytes = readAllBytes(input);
            ConversionResult result = convertBufferCore(inputBytes, format, options);

            if (result.isSuccess() && result.getData() != null) {
                output.write(result.getData());
                output.flush();
            }

            // Return result without data (data was written to output stream)
            return result.isSuccess()
                    ? ConversionResult.ok(result.getDiagnostics())
                    : result;
        } catch (IOException e) {
            return ConversionResult.fail("I/O error: " + e.getMessage(),
                    SlimLOErrorCode.UNKNOWN, null);
        }
    }

    // ---- Async variants ----

    /**
     * Asynchronously convert a document file to PDF.
     */
    public CompletableFuture<ConversionResult> convertAsync(final String inputPath, final String outputPath) {
        return convertAsync(inputPath, outputPath, null);
    }

    /**
     * Asynchronously convert a document file to PDF with options.
     */
    public CompletableFuture<ConversionResult> convertAsync(
            final String inputPath, final String outputPath, final ConversionOptions options) {
        return CompletableFuture.supplyAsync(new java.util.function.Supplier<ConversionResult>() {
            @Override
            public ConversionResult get() {
                return convert(inputPath, outputPath, options);
            }
        });
    }

    /**
     * Asynchronously convert in-memory document bytes to PDF bytes.
     */
    public CompletableFuture<ConversionResult> convertAsync(final byte[] input, final DocumentFormat format) {
        return convertAsync(input, format, null);
    }

    /**
     * Asynchronously convert in-memory document bytes to PDF bytes with options.
     */
    public CompletableFuture<ConversionResult> convertAsync(
            final byte[] input, final DocumentFormat format, final ConversionOptions options) {
        return CompletableFuture.supplyAsync(new java.util.function.Supplier<ConversionResult>() {
            @Override
            public ConversionResult get() {
                return convert(input, format, options);
            }
        });
    }

    @Override
    public void close() {
        if (disposed) return;
        disposed = true;
        pool.close();
    }

    // ---- Internal helpers ----

    private ConversionResult convertBufferCore(byte[] input, DocumentFormat format, ConversionOptions options) {
        int id = requestId.incrementAndGet();
        Map<String, Object> request = new HashMap<String, Object>();
        request.put("type", "convert_buffer");
        request.put("id", id);
        request.put("format", format.getValue());
        request.put("data_size", (long) input.length);
        addOptions(request, options);

        return pool.executeBuffer(request, input);
    }

    private static void addOptions(Map<String, Object> request, ConversionOptions options) {
        if (options == null) return;

        Map<String, Object> opts = new HashMap<String, Object>();
        opts.put("pdf_version", options.getPdfVersion().getValue());
        opts.put("jpeg_quality", options.getJpegQuality());
        opts.put("dpi", options.getDpi());
        opts.put("tagged_pdf", options.isTaggedPdf());
        if (options.getPageRange() != null) {
            opts.put("page_range", options.getPageRange());
        }
        if (options.getPassword() != null) {
            opts.put("password", options.getPassword());
        }
        request.put("options", opts);
    }

    private static ConversionResult invalidFormatFailure(DocumentFormat format) {
        String message;
        if (format == DocumentFormat.UNKNOWN) {
            message = "Unsupported input format. SlimLO currently supports DOCX (.docx) only.";
        } else {
            message = "Unsupported format '" + format + "'. SlimLO currently supports DOCX (.docx) only.";
        }
        return ConversionResult.fail(message, SlimLOErrorCode.INVALID_FORMAT, null);
    }

    private void checkDisposed() {
        if (disposed) {
            throw new IllegalStateException("PdfConverter has been closed");
        }
    }

    private static byte[] readAllBytes(InputStream in) throws IOException {
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        byte[] chunk = new byte[8192];
        int read;
        while ((read = in.read(chunk)) != -1) {
            buffer.write(chunk, 0, read);
        }
        return buffer.toByteArray();
    }
}
