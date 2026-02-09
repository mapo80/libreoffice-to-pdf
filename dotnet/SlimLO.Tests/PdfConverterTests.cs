using Xunit;

namespace SlimLO.Tests;

/// <summary>
/// Integration tests for PdfConverter.
/// These tests require the SlimLO native library and resources to be built and available.
/// Set SLIMLO_RESOURCE_PATH environment variable before running.
/// </summary>
public class PdfConverterTests
{
    private static bool NativeLibraryAvailable()
    {
        try
        {
            var version = PdfConverter.GetVersion();
            return version != null;
        }
        catch
        {
            return false;
        }
    }

    [Fact]
    public void GetVersion_ReturnsNonNull()
    {
        // This test can run even without the native library
        // to verify P/Invoke declaration compilation
        if (!NativeLibraryAvailable())
        {
            // Skip if native library not available
            return;
        }

        var version = PdfConverter.GetVersion();
        Assert.NotNull(version);
        Assert.Contains("SlimLO", version);
    }

    [Fact]
    public void Create_WithInvalidPath_ThrowsSlimLOException()
    {
        if (!NativeLibraryAvailable())
            return;

        Assert.Throws<SlimLOException>(() =>
            PdfConverter.Create("/nonexistent/path"));
    }

    [Fact]
    public void ConvertToPdf_SimpleDocx_ProducesOutput()
    {
        if (!NativeLibraryAvailable())
            return;

        var resourcePath = Environment.GetEnvironmentVariable("SLIMLO_RESOURCE_PATH");
        if (string.IsNullOrEmpty(resourcePath))
            return; // Skip if no resources

        using var converter = PdfConverter.Create(resourcePath);

        var testDocx = Path.Combine("..", "..", "..", "..", "test-corpus", "simple.docx");
        if (!File.Exists(testDocx))
            return; // Skip if no test document

        var outputPdf = Path.GetTempFileName() + ".pdf";
        try
        {
            converter.ConvertToPdf(testDocx, outputPdf);

            Assert.True(File.Exists(outputPdf));
            Assert.True(new FileInfo(outputPdf).Length > 0);
        }
        finally
        {
            if (File.Exists(outputPdf))
                File.Delete(outputPdf);
        }
    }

    [Fact]
    public void PdfOptions_RecordEquality_Works()
    {
        var opts1 = new PdfOptions { Version = PdfVersion.PdfA2, Dpi = 150 };
        var opts2 = new PdfOptions { Version = PdfVersion.PdfA2, Dpi = 150 };

        Assert.Equal(opts1, opts2);
    }

    [Fact]
    public void DocumentFormat_EnumValues_MatchNative()
    {
        // Verify enum values match slimlo.h SlimLOFormat
        Assert.Equal(0, (int)DocumentFormat.Unknown);
        Assert.Equal(1, (int)DocumentFormat.Docx);
        Assert.Equal(2, (int)DocumentFormat.Xlsx);
        Assert.Equal(3, (int)DocumentFormat.Pptx);
    }
}
