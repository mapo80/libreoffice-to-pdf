package com.slimlo;

import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * Configuration for creating a {@link PdfConverter} instance.
 * Use {@link #builder()} to create instances.
 */
public final class PdfConverterOptions {

    private final String resourcePath;
    private final List<String> fontDirectories;
    private final long conversionTimeoutMillis;
    private final int maxWorkers;
    private final int maxConversionsPerWorker;
    private final boolean warmUp;

    private PdfConverterOptions(Builder builder) {
        this.resourcePath = builder.resourcePath;
        this.fontDirectories = builder.fontDirectories;
        this.conversionTimeoutMillis = builder.conversionTimeoutMillis;
        this.maxWorkers = builder.maxWorkers;
        this.maxConversionsPerWorker = builder.maxConversionsPerWorker;
        this.warmUp = builder.warmUp;
    }

    /**
     * Path to the SlimLO resources directory (containing program/, share/).
     * If null, auto-detected from the native library location or
     * the SLIMLO_RESOURCE_PATH environment variable.
     */
    public String getResourcePath() {
        return resourcePath;
    }

    /**
     * Additional font directories to make available during conversion.
     * Null means no custom fonts.
     */
    public List<String> getFontDirectories() {
        return fontDirectories;
    }

    /** Maximum time in milliseconds for a single conversion. Default: 300000 (5 minutes). */
    public long getConversionTimeoutMillis() {
        return conversionTimeoutMillis;
    }

    /**
     * Maximum number of worker processes. Each worker handles one conversion at a time.
     * More workers = more parallel conversions, but more memory (~200 MB per worker).
     * Default: 1.
     */
    public int getMaxWorkers() {
        return maxWorkers;
    }

    /**
     * Recycle a worker process after this many conversions.
     * 0 = never recycle. Default: 0.
     */
    public int getMaxConversionsPerWorker() {
        return maxConversionsPerWorker;
    }

    /**
     * If true, start worker processes eagerly during create().
     * If false (default), workers start lazily on first conversion.
     */
    public boolean isWarmUp() {
        return warmUp;
    }

    public static Builder builder() {
        return new Builder();
    }

    public static final class Builder {
        private String resourcePath = null;
        private List<String> fontDirectories = null;
        private long conversionTimeoutMillis = 5 * 60 * 1000L; // 5 minutes
        private int maxWorkers = 1;
        private int maxConversionsPerWorker = 0;
        private boolean warmUp = false;

        private Builder() {}

        public Builder resourcePath(String resourcePath) {
            this.resourcePath = resourcePath;
            return this;
        }

        public Builder fontDirectories(List<String> fontDirectories) {
            this.fontDirectories = fontDirectories;
            return this;
        }

        public Builder conversionTimeout(long duration, TimeUnit unit) {
            this.conversionTimeoutMillis = unit.toMillis(duration);
            return this;
        }

        public Builder conversionTimeoutMillis(long millis) {
            this.conversionTimeoutMillis = millis;
            return this;
        }

        public Builder maxWorkers(int maxWorkers) {
            this.maxWorkers = maxWorkers;
            return this;
        }

        public Builder maxConversionsPerWorker(int maxConversionsPerWorker) {
            this.maxConversionsPerWorker = maxConversionsPerWorker;
            return this;
        }

        public Builder warmUp(boolean warmUp) {
            this.warmUp = warmUp;
            return this;
        }

        public PdfConverterOptions build() {
            if (maxWorkers < 1) {
                throw new IllegalArgumentException("maxWorkers must be at least 1");
            }
            return new PdfConverterOptions(this);
        }
    }
}
