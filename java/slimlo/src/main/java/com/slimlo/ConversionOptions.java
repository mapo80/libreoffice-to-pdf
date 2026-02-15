package com.slimlo;

/**
 * Options for a single PDF conversion operation.
 * Use {@link #builder()} to create instances.
 */
public final class ConversionOptions {

    private final PdfVersion pdfVersion;
    private final int jpegQuality;
    private final int dpi;
    private final boolean taggedPdf;
    private final String pageRange;
    private final String password;

    private ConversionOptions(Builder builder) {
        this.pdfVersion = builder.pdfVersion;
        this.jpegQuality = builder.jpegQuality;
        this.dpi = builder.dpi;
        this.taggedPdf = builder.taggedPdf;
        this.pageRange = builder.pageRange;
        this.password = builder.password;
    }

    /** PDF version for the output. Default: PDF 1.7. */
    public PdfVersion getPdfVersion() {
        return pdfVersion;
    }

    /** JPEG compression quality 1-100. 0 = default (90). */
    public int getJpegQuality() {
        return jpegQuality;
    }

    /** Maximum image resolution in DPI. 0 = default (300). */
    public int getDpi() {
        return dpi;
    }

    /** Whether to generate tagged PDF for accessibility. */
    public boolean isTaggedPdf() {
        return taggedPdf;
    }

    /** Page range string, e.g. "1-3" or "1,3,5-7". Null = all pages. */
    public String getPageRange() {
        return pageRange;
    }

    /** Password for password-protected documents. Null = none. */
    public String getPassword() {
        return password;
    }

    public static Builder builder() {
        return new Builder();
    }

    public static final class Builder {
        private PdfVersion pdfVersion = PdfVersion.DEFAULT;
        private int jpegQuality = 0;
        private int dpi = 0;
        private boolean taggedPdf = false;
        private String pageRange = null;
        private String password = null;

        private Builder() {}

        public Builder pdfVersion(PdfVersion pdfVersion) {
            this.pdfVersion = pdfVersion;
            return this;
        }

        public Builder jpegQuality(int jpegQuality) {
            this.jpegQuality = jpegQuality;
            return this;
        }

        public Builder dpi(int dpi) {
            this.dpi = dpi;
            return this;
        }

        public Builder taggedPdf(boolean taggedPdf) {
            this.taggedPdf = taggedPdf;
            return this;
        }

        public Builder pageRange(String pageRange) {
            this.pageRange = pageRange;
            return this;
        }

        public Builder password(String password) {
            this.password = password;
            return this;
        }

        public ConversionOptions build() {
            return new ConversionOptions(this);
        }
    }
}
