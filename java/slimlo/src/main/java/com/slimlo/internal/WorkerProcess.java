package com.slimlo.internal;

import com.google.gson.JsonObject;
import com.slimlo.*;

import java.io.*;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Manages the lifecycle of a single native slimlo_worker subprocess.
 * Handles startup, message exchange, stderr capture, and crash detection.
 */
public final class WorkerProcess implements Closeable {

    private final String workerPath;
    private final String resourcePath;
    private final List<String> fontDirectories;
    private final ExecutorService executor;

    private Process process;
    private OutputStream stdin;
    private InputStream stdout;
    private final ReentrantLock lock = new ReentrantLock();
    private final StringBuilder stderrBuffer = new StringBuilder();
    private volatile boolean disposed;
    private volatile boolean initialized;
    private final AtomicInteger conversionCount = new AtomicInteger(0);
    private String version;

    public WorkerProcess(
            String workerPath,
            String resourcePath,
            List<String> fontDirectories,
            ExecutorService executor) {
        this.workerPath = workerPath;
        this.resourcePath = resourcePath;
        this.fontDirectories = fontDirectories;
        this.executor = executor;
    }

    public int getConversionCount() {
        return conversionCount.get();
    }

    public boolean isAlive() {
        return process != null && process.isAlive();
    }

    public String getVersion() {
        return version;
    }

    /**
     * Start the worker process and send the init message.
     */
    public void start() throws IOException, SlimLOException {
        if (disposed) throw new IllegalStateException("WorkerProcess is disposed");

        ProcessBuilder pb = new ProcessBuilder(workerPath);
        pb.redirectErrorStream(false);

        Map<String, String> env = pb.environment();

        // Library paths
        String workerDir = new File(workerPath).getParent();
        String programDir = new File(resourcePath, "program").getAbsolutePath();
        String libPaths = workerDir.equals(programDir) ? workerDir : workerDir + File.pathSeparator + programDir;

        if (WorkerLocator.isLinux()) {
            String existing = System.getenv("LD_LIBRARY_PATH");
            env.put("LD_LIBRARY_PATH", existing != null && !existing.isEmpty()
                    ? libPaths + ":" + existing : libPaths);
        } else if (WorkerLocator.isMacOS()) {
            String existing = System.getenv("DYLD_LIBRARY_PATH");
            env.put("DYLD_LIBRARY_PATH", existing != null && !existing.isEmpty()
                    ? libPaths + ":" + existing : libPaths);
        }

        // VCL plugin: SVP for headless on Linux/Windows, Quartz on macOS
        if (!WorkerLocator.isMacOS()) {
            env.put("SAL_USE_VCLPLUGIN", "svp");
        }

        // macOS: unipoll mode required for thread safety
        if (WorkerLocator.isMacOS()) {
            env.put("SAL_LOK_OPTIONS", "unipoll");
        }

        // Font logging
        env.put("SAL_LOG", "+WARN.vcl.fonts+INFO.vcl+WARN.vcl");

        // Custom font paths
        if (fontDirectories != null && !fontDirectories.isEmpty()) {
            String separator = WorkerLocator.isWindows() ? ";" : ":";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < fontDirectories.size(); i++) {
                if (i > 0) sb.append(separator);
                sb.append(fontDirectories.get(i));
            }
            env.put("SAL_FONTPATH", sb.toString());
        }

        // Temp user profile
        String profileDir = System.getProperty("java.io.tmpdir") + File.separator
                + "slimlo_profile_" + Thread.currentThread().getId() + "_" + System.identityHashCode(this);
        new File(profileDir).mkdirs();
        env.put("HOME", profileDir);

        process = pb.start();
        stdin = process.getOutputStream();
        stdout = process.getInputStream();

        // Start stderr gobbler daemon
        startStderrGobbler();

        // Send init message
        Map<String, Object> initRequest = new HashMap<String, Object>();
        initRequest.put("type", "init");
        initRequest.put("resource_path", resourcePath);
        if (fontDirectories != null && !fontDirectories.isEmpty()) {
            initRequest.put("font_paths", fontDirectories);
        }

        byte[] initBytes = Protocol.serialize(initRequest);
        Protocol.writeMessage(stdin, initBytes);

        // Read init response
        byte[] responseBytes = Protocol.readMessage(stdout);
        if (responseBytes == null) {
            int exitCode = -1;
            try {
                if (process.waitFor(1, TimeUnit.SECONDS)) {
                    exitCode = process.exitValue();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            String stderr = getStderrOutput();
            String message = "Worker process died during initialization (exit code: " + exitCode + ").";
            if (stderr.contains("error while loading shared libraries")) {
                message += " Missing system library detected. Check that all required native libraries are installed.";
            }
            message += " Stderr: " + stderr;
            throw new SlimLOException(message, SlimLOErrorCode.INIT_FAILED);
        }

        JsonObject root = Protocol.deserialize(responseBytes);
        String type = root.has("type") ? root.get("type").getAsString() : "";

        if ("error".equals(type)) {
            String message = root.has("message") ? root.get("message").getAsString() : "Unknown error";
            throw new SlimLOException("Worker initialization failed: " + message, SlimLOErrorCode.INIT_FAILED);
        }

        if ("ready".equals(type)) {
            version = root.has("version") ? root.get("version").getAsString() : null;
            initialized = true;
        } else {
            throw new SlimLOException("Unexpected init response type: " + type, SlimLOErrorCode.INIT_FAILED);
        }
    }

    /**
     * Execute a file-path conversion.
     */
    public ConversionResult convert(
            Map<String, Object> request,
            long timeoutMillis) {
        if (disposed) {
            return ConversionResult.fail("Worker is disposed", SlimLOErrorCode.NOT_INITIALIZED, null);
        }
        if (!initialized || process == null || !process.isAlive()) {
            return ConversionResult.fail("Worker process is not running", SlimLOErrorCode.NOT_INITIALIZED, null);
        }

        lock.lock();
        try {
            clearStderrBuffer();

            Future<ConversionResult> future = executor.submit(() -> {
                byte[] requestBytes = Protocol.serialize(request);
                Protocol.writeMessage(stdin, requestBytes);

                byte[] responseBytes = Protocol.readMessage(stdout);
                if (responseBytes == null) {
                    initialized = false;
                    int exitCode = process.isAlive() ? -1 : process.exitValue();
                    return ConversionResult.fail(
                            "Worker process crashed during conversion (exit code: " + exitCode + ").",
                            SlimLOErrorCode.UNKNOWN, null);
                }

                return parseConvertResponse(responseBytes, false);
            });

            try {
                return future.get(timeoutMillis, TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                future.cancel(true);
                killProcess();
                initialized = false;
                return ConversionResult.fail(
                        "Conversion timed out after " + (timeoutMillis / 1000) + " seconds",
                        SlimLOErrorCode.UNKNOWN, null);
            } catch (ExecutionException e) {
                Throwable cause = e.getCause();
                if (cause instanceof IOException) {
                    initialized = false;
                    return ConversionResult.fail(
                            "I/O error during conversion: " + cause.getMessage(),
                            SlimLOErrorCode.UNKNOWN, null);
                }
                return ConversionResult.fail(
                        "Conversion error: " + cause.getMessage(),
                        SlimLOErrorCode.UNKNOWN, null);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return ConversionResult.fail("Conversion interrupted", SlimLOErrorCode.UNKNOWN, null);
            }
        } finally {
            lock.unlock();
        }
    }

    /**
     * Execute a buffer conversion. Sends document bytes, receives PDF bytes.
     */
    public ConversionResult convertBuffer(
            Map<String, Object> request,
            byte[] documentData,
            long timeoutMillis) {
        if (disposed) {
            return ConversionResult.fail("Worker is disposed", SlimLOErrorCode.NOT_INITIALIZED, null);
        }
        if (!initialized || process == null || !process.isAlive()) {
            return ConversionResult.fail("Worker process is not running", SlimLOErrorCode.NOT_INITIALIZED, null);
        }

        lock.lock();
        try {
            clearStderrBuffer();

            Future<ConversionResult> future = executor.submit(() -> {
                // Send JSON header frame
                byte[] requestBytes = Protocol.serialize(request);
                Protocol.writeMessage(stdin, requestBytes);

                // Send binary document frame
                Protocol.writeMessage(stdin, documentData);

                // Read JSON response frame
                byte[] responseBytes = Protocol.readMessage(stdout);
                if (responseBytes == null) {
                    initialized = false;
                    int exitCode = process.isAlive() ? -1 : process.exitValue();
                    return ConversionResult.fail(
                            "Worker process crashed during buffer conversion (exit code: " + exitCode + ").",
                            SlimLOErrorCode.UNKNOWN, null);
                }

                return parseConvertResponse(responseBytes, true);
            });

            try {
                return future.get(timeoutMillis, TimeUnit.MILLISECONDS);
            } catch (TimeoutException e) {
                future.cancel(true);
                killProcess();
                initialized = false;
                return ConversionResult.fail(
                        "Buffer conversion timed out after " + (timeoutMillis / 1000) + " seconds",
                        SlimLOErrorCode.UNKNOWN, null);
            } catch (ExecutionException e) {
                Throwable cause = e.getCause();
                if (cause instanceof IOException) {
                    initialized = false;
                }
                return ConversionResult.fail(
                        "Buffer conversion error: " + (cause != null ? cause.getMessage() : "unknown"),
                        SlimLOErrorCode.UNKNOWN, null);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return ConversionResult.fail("Buffer conversion interrupted", SlimLOErrorCode.UNKNOWN, null);
            }
        } finally {
            lock.unlock();
        }
    }

    private ConversionResult parseConvertResponse(byte[] responseBytes, boolean isBuffer) throws IOException {
        JsonObject root = Protocol.deserialize(responseBytes);

        List<ConversionDiagnostic> diagnostics = root.has("diagnostics") && root.get("diagnostics").isJsonArray()
                ? StderrDiagnosticParser.parseFromJson(root.getAsJsonArray("diagnostics"))
                : Collections.<ConversionDiagnostic>emptyList();

        boolean success = root.has("success") && root.get("success").getAsBoolean();

        if (success) {
            conversionCount.incrementAndGet();
            if (isBuffer) {
                // Read binary PDF frame
                byte[] pdfBytes = Protocol.readMessage(stdout);
                if (pdfBytes == null) {
                    initialized = false;
                    return ConversionResult.fail(
                            "Worker process crashed while sending PDF data",
                            SlimLOErrorCode.UNKNOWN, diagnostics);
                }
                return ConversionResult.ok(pdfBytes, diagnostics);
            }
            return ConversionResult.ok(diagnostics);
        } else {
            String errorMessage = root.has("error_message") && !root.get("error_message").isJsonNull()
                    ? root.get("error_message").getAsString()
                    : "Conversion failed";
            SlimLOErrorCode errorCode = root.has("error_code") && root.get("error_code").isJsonPrimitive()
                    ? SlimLOErrorCode.fromValue(root.get("error_code").getAsInt())
                    : SlimLOErrorCode.UNKNOWN;

            conversionCount.incrementAndGet();
            return ConversionResult.fail(errorMessage, errorCode, diagnostics);
        }
    }

    private void startStderrGobbler() {
        final InputStream stderr = process.getErrorStream();
        Thread gobbler = new Thread(new Runnable() {
            @Override
            public void run() {
                try (BufferedReader reader = new BufferedReader(new InputStreamReader(stderr))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        synchronized (stderrBuffer) {
                            stderrBuffer.append(line).append('\n');
                        }
                    }
                } catch (IOException e) {
                    // Process ended
                }
            }
        }, "slimlo-stderr-gobbler");
        gobbler.setDaemon(true);
        gobbler.start();
    }

    private void clearStderrBuffer() {
        synchronized (stderrBuffer) {
            stderrBuffer.setLength(0);
        }
    }

    private String getStderrOutput() {
        synchronized (stderrBuffer) {
            return stderrBuffer.toString();
        }
    }

    private void killProcess() {
        try {
            if (process != null && process.isAlive()) {
                process.destroyForcibly();
            }
        } catch (Exception e) {
            // Best effort
        }
    }

    @Override
    public void close() {
        if (disposed) return;
        disposed = true;

        if (process != null && process.isAlive()) {
            try {
                // Try graceful shutdown
                Map<String, Object> quitRequest = new HashMap<String, Object>();
                quitRequest.put("type", "quit");
                byte[] quitBytes = Protocol.serialize(quitRequest);
                Protocol.writeMessage(stdin, quitBytes);

                // Wait up to 5 seconds
                if (!process.waitFor(5, TimeUnit.SECONDS)) {
                    killProcess();
                }
            } catch (Exception e) {
                killProcess();
            }
        }

        if (process != null) {
            process.destroy();
        }
    }
}
