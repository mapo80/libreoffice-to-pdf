package com.slimlo.internal;

import com.slimlo.ConversionResult;
import com.slimlo.SlimLOErrorCode;
import com.slimlo.SlimLOException;

import java.io.Closeable;
import java.io.IOException;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Thread-safe pool of native worker processes.
 * Provides round-robin dispatch, automatic crash recovery,
 * and worker recycling.
 */
public final class WorkerPool implements Closeable {

    private final String workerPath;
    private final String resourcePath;
    private final List<String> fontDirectories;
    private final int maxWorkers;
    private final int maxConversionsPerWorker;
    private final long timeoutMillis;
    private final Semaphore gate;
    private final WorkerProcess[] workers;
    private final ReentrantLock[] workerLocks;
    private final AtomicInteger nextWorkerIndex = new AtomicInteger(0);
    private final ExecutorService executor;
    private volatile boolean disposed;
    private volatile String version;

    public WorkerPool(
            String workerPath,
            String resourcePath,
            List<String> fontDirectories,
            int maxWorkers,
            int maxConversionsPerWorker,
            long timeoutMillis) {
        this.workerPath = workerPath;
        this.resourcePath = resourcePath;
        this.fontDirectories = fontDirectories;
        this.maxWorkers = maxWorkers;
        this.maxConversionsPerWorker = maxConversionsPerWorker;
        this.timeoutMillis = timeoutMillis;
        this.gate = new Semaphore(maxWorkers);
        this.workers = new WorkerProcess[maxWorkers];
        this.workerLocks = new ReentrantLock[maxWorkers];
        for (int i = 0; i < maxWorkers; i++) {
            workerLocks[i] = new ReentrantLock();
        }
        this.executor = Executors.newCachedThreadPool(new java.util.concurrent.ThreadFactory() {
            private final AtomicInteger count = new AtomicInteger(0);
            @Override
            public Thread newThread(Runnable r) {
                Thread t = new Thread(r, "slimlo-worker-io-" + count.incrementAndGet());
                t.setDaemon(true);
                return t;
            }
        });
    }

    public String getVersion() {
        return version;
    }

    /**
     * Pre-start all worker processes (for warmUp mode).
     */
    public void warmUp() throws IOException {
        for (int i = 0; i < maxWorkers; i++) {
            ensureWorker(i);
        }
    }

    /**
     * Execute a file-path conversion on the next available worker.
     * Thread-safe.
     */
    public ConversionResult execute(Map<String, Object> request) {
        if (disposed) {
            return ConversionResult.fail("Pool is disposed", SlimLOErrorCode.NOT_INITIALIZED, null);
        }

        try {
            gate.acquire();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return ConversionResult.fail("Interrupted while waiting for worker", SlimLOErrorCode.UNKNOWN, null);
        }

        try {
            int index = Math.abs(nextWorkerIndex.incrementAndGet()) % maxWorkers;

            try {
                ensureWorker(index);
            } catch (IOException e) {
                return ConversionResult.fail("Failed to start worker: " + e.getMessage(),
                        SlimLOErrorCode.INIT_FAILED, null);
            }

            WorkerProcess worker = workers[index];
            if (worker == null) {
                return ConversionResult.fail("Failed to start worker", SlimLOErrorCode.INIT_FAILED, null);
            }

            ConversionResult result = worker.convert(request, timeoutMillis);

            // Check if worker needs recycling
            if (maxConversionsPerWorker > 0 && worker.getConversionCount() >= maxConversionsPerWorker) {
                recycleWorker(index);
            }

            // If worker crashed, mark for replacement
            if (!worker.isAlive()) {
                workerLocks[index].lock();
                try {
                    if (workers[index] == worker) {
                        worker.close();
                        workers[index] = null;
                    }
                } finally {
                    workerLocks[index].unlock();
                }
            }

            return result;
        } finally {
            gate.release();
        }
    }

    /**
     * Execute a buffer conversion on the next available worker.
     * Thread-safe.
     */
    public ConversionResult executeBuffer(Map<String, Object> request, byte[] documentData) {
        if (disposed) {
            return ConversionResult.fail("Pool is disposed", SlimLOErrorCode.NOT_INITIALIZED, null);
        }

        try {
            gate.acquire();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return ConversionResult.fail("Interrupted while waiting for worker", SlimLOErrorCode.UNKNOWN, null);
        }

        try {
            int index = Math.abs(nextWorkerIndex.incrementAndGet()) % maxWorkers;

            try {
                ensureWorker(index);
            } catch (IOException e) {
                return ConversionResult.fail("Failed to start worker: " + e.getMessage(),
                        SlimLOErrorCode.INIT_FAILED, null);
            }

            WorkerProcess worker = workers[index];
            if (worker == null) {
                return ConversionResult.fail("Failed to start worker", SlimLOErrorCode.INIT_FAILED, null);
            }

            ConversionResult result = worker.convertBuffer(request, documentData, timeoutMillis);

            if (maxConversionsPerWorker > 0 && worker.getConversionCount() >= maxConversionsPerWorker) {
                recycleWorker(index);
            }

            if (!worker.isAlive()) {
                workerLocks[index].lock();
                try {
                    if (workers[index] == worker) {
                        worker.close();
                        workers[index] = null;
                    }
                } finally {
                    workerLocks[index].unlock();
                }
            }

            return result;
        } finally {
            gate.release();
        }
    }

    private void ensureWorker(int index) throws IOException {
        if (workers[index] != null && workers[index].isAlive()) {
            return;
        }

        workerLocks[index].lock();
        try {
            // Double-check
            if (workers[index] != null && workers[index].isAlive()) {
                return;
            }

            // Dispose old
            if (workers[index] != null) {
                workers[index].close();
                workers[index] = null;
            }

            // Start new
            WorkerProcess worker = new WorkerProcess(workerPath, resourcePath, fontDirectories, executor);
            worker.start();
            workers[index] = worker;
            if (version == null) {
                version = worker.getVersion();
            }
        } finally {
            workerLocks[index].unlock();
        }
    }

    private void recycleWorker(int index) {
        workerLocks[index].lock();
        try {
            if (workers[index] != null) {
                workers[index].close();
                workers[index] = null;
            }
        } finally {
            workerLocks[index].unlock();
        }
    }

    @Override
    public void close() {
        if (disposed) return;
        disposed = true;

        for (int i = 0; i < maxWorkers; i++) {
            if (workers[i] != null) {
                workers[i].close();
                workers[i] = null;
            }
        }

        executor.shutdown();
    }
}
