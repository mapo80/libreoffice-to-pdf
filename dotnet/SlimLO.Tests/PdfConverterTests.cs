using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using SlimLO.Internal;
using Xunit;

namespace SlimLO.Tests;

// ===========================================================================
// Helpers shared across test classes
// ===========================================================================

internal static class TestHelpers
{
    public static string? GetResourcePath()
    {
        var envPath = Environment.GetEnvironmentVariable("SLIMLO_RESOURCE_PATH");
        if (!string.IsNullOrEmpty(envPath) && Directory.Exists(Path.Combine(envPath, "program")))
            return envPath;
        return null;
    }

    public static bool HasWorker()
    {
        try
        {
            WorkerLocator.FindWorkerExecutable();
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static bool CanRunIntegration() => HasWorker() && GetResourcePath() != null;

    public static string? FindTestDocx()
    {
        var dir = AppContext.BaseDirectory;
        for (int i = 0; i < 8; i++)
        {
            var candidate = Path.Combine(dir, "tests", "test.docx");
            if (File.Exists(candidate))
                return candidate;
            dir = Path.GetDirectoryName(dir)!;
            if (dir == null) break;
        }
        var envPath = Environment.GetEnvironmentVariable("SLIMLO_TEST_DOCX");
        if (!string.IsNullOrEmpty(envPath) && File.Exists(envPath))
            return envPath;
        return null;
    }

    public static string? FindFixture(string filename)
    {
        var dir = AppContext.BaseDirectory;
        for (int i = 0; i < 8; i++)
        {
            var candidate = Path.Combine(dir, "tests", "fixtures", filename);
            if (File.Exists(candidate))
                return candidate;
            dir = Path.GetDirectoryName(dir)!;
            if (dir == null) break;
        }
        return null;
    }

    public static string? FindFontDir()
    {
        var dir = AppContext.BaseDirectory;
        for (int i = 0; i < 8; i++)
        {
            var candidate = Path.Combine(dir, "tests", "fixtures", "fonts");
            if (Directory.Exists(candidate))
                return candidate;
            dir = Path.GetDirectoryName(dir)!;
            if (dir == null) break;
        }
        return null;
    }
}

// ===========================================================================
// ConversionResult tests
// ===========================================================================

public class ConversionResultTests
{
    [Fact]
    public void Ok_ReturnsSuccess()
    {
        var result = ConversionResult.Ok(null);
        Assert.True(result.Success);
        Assert.Null(result.ErrorMessage);
        Assert.Null(result.ErrorCode);
        Assert.Empty(result.Diagnostics);
    }

    [Fact]
    public void Ok_WithDiagnostics_PreservesDiagnostics()
    {
        var diags = new[]
        {
            new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.Font,
                "Missing font", "Arial", "Liberation Sans")
        };
        var result = ConversionResult.Ok(diags);
        Assert.True(result.Success);
        Assert.Single(result.Diagnostics);
        Assert.Equal("Arial", result.Diagnostics[0].FontName);
    }

    [Fact]
    public void Fail_ReturnsFailure()
    {
        var result = ConversionResult.Fail("boom", SlimLOErrorCode.ExportFailed, null);
        Assert.False(result.Success);
        Assert.Equal("boom", result.ErrorMessage);
        Assert.Equal(SlimLOErrorCode.ExportFailed, result.ErrorCode);
        Assert.Empty(result.Diagnostics);
    }

    [Fact]
    public void Fail_WithDiagnostics_PreservesDiagnostics()
    {
        var diags = new[]
        {
            new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.General, "warn")
        };
        var result = ConversionResult.Fail("error", SlimLOErrorCode.LoadFailed, diags);
        Assert.False(result.Success);
        Assert.Single(result.Diagnostics);
    }

    [Fact]
    public void ImplicitBool_TrueOnSuccess()
    {
        ConversionResult result = ConversionResult.Ok(null);
        Assert.True(result);
    }

    [Fact]
    public void ImplicitBool_FalseOnFailure()
    {
        ConversionResult result = ConversionResult.Fail("err", SlimLOErrorCode.Unknown, null);
        Assert.False(result);
    }

    [Fact]
    public void ThrowIfFailed_ThrowsSlimLOException()
    {
        var failure = ConversionResult.Fail("test error", SlimLOErrorCode.ExportFailed, null);
        var ex = Assert.Throws<SlimLOException>(() => failure.ThrowIfFailed());
        Assert.Equal(SlimLOErrorCode.ExportFailed, ex.ErrorCode);
        Assert.Equal("test error", ex.Message);
    }

    [Fact]
    public void ThrowIfFailed_UsesDefaultErrorCode_WhenNull()
    {
        var failure = ConversionResult.Fail("err", SlimLOErrorCode.Unknown, null);
        var ex = Assert.Throws<SlimLOException>(() => failure.ThrowIfFailed());
        Assert.Equal(SlimLOErrorCode.Unknown, ex.ErrorCode);
    }

    [Fact]
    public void ThrowIfFailed_ReturnsThis_OnSuccess()
    {
        var success = ConversionResult.Ok(null);
        var returned = success.ThrowIfFailed();
        Assert.Same(success, returned);
    }

    [Fact]
    public void HasFontWarnings_True_WhenFontCategoryPresent()
    {
        var result = ConversionResult.Ok(new[]
        {
            new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.Font,
                "Missing font", "Arial Narrow", "Liberation Sans")
        });
        Assert.True(result.HasFontWarnings);
    }

    [Fact]
    public void HasFontWarnings_False_WhenOnlyGeneralWarnings()
    {
        var result = ConversionResult.Ok(new[]
        {
            new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.General,
                "Something happened")
        });
        Assert.False(result.HasFontWarnings);
    }

    [Fact]
    public void HasFontWarnings_False_WhenNoDiagnostics()
    {
        var result = ConversionResult.Ok(null);
        Assert.False(result.HasFontWarnings);
    }

    [Fact]
    public void HasFontWarnings_False_WhenEmptyDiagnostics()
    {
        var result = ConversionResult.Ok(Array.Empty<ConversionDiagnostic>());
        Assert.False(result.HasFontWarnings);
    }

    [Fact]
    public void HasFontWarnings_True_WithMixedDiagnostics()
    {
        var result = ConversionResult.Ok(new[]
        {
            new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.General, "gen"),
            new ConversionDiagnostic(DiagnosticSeverity.Info, DiagnosticCategory.Layout, "layout"),
            new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.Font, "font!", "F")
        });
        Assert.True(result.HasFontWarnings);
    }
}

// ===========================================================================
// ConversionResult<T> tests
// ===========================================================================

public class ConversionResultGenericTests
{
    [Fact]
    public void Ok_ReturnsDataAndSuccess()
    {
        var data = new byte[] { 1, 2, 3 };
        var result = ConversionResult<byte[]>.Ok(data, null);
        Assert.True(result.Success);
        Assert.Equal(data, result.Data);
        Assert.Empty(result.Diagnostics);
    }

    [Fact]
    public void Fail_ReturnsNullData()
    {
        var result = ConversionResult<byte[]>.Fail("err", SlimLOErrorCode.ExportFailed, null);
        Assert.False(result.Success);
        Assert.Null(result.Data);
    }

    [Fact]
    public void Ok_WithDiagnostics_PreservesBoth()
    {
        var diags = new[]
        {
            new ConversionDiagnostic(DiagnosticSeverity.Info, DiagnosticCategory.General, "ok")
        };
        var result = ConversionResult<string>.Ok("hello", diags);
        Assert.True(result.Success);
        Assert.Equal("hello", result.Data);
        Assert.Single(result.Diagnostics);
    }

    [Fact]
    public void ImplicitBool_WorksForGeneric()
    {
        ConversionResult result = ConversionResult<byte[]>.Ok(new byte[] { 1 }, null);
        Assert.True(result);

        result = ConversionResult<byte[]>.Fail("err", SlimLOErrorCode.Unknown, null);
        Assert.False(result);
    }

    [Fact]
    public void AsBase_Success_PreservesDiagnostics()
    {
        var diags = new[] { new ConversionDiagnostic(DiagnosticSeverity.Warning, DiagnosticCategory.Font, "warn") };
        var typed = ConversionResult<byte[]>.Ok(new byte[] { 1, 2 }, diags);
        ConversionResult baseResult = typed.AsBase();

        Assert.True(baseResult.Success);
        Assert.Null(baseResult.ErrorMessage);
        Assert.Single(baseResult.Diagnostics);
    }

    [Fact]
    public void AsBase_Failure_PreservesErrorInfo()
    {
        var typed = ConversionResult<byte[]>.Fail("boom", SlimLOErrorCode.ExportFailed, null);
        ConversionResult baseResult = typed.AsBase();

        Assert.False(baseResult.Success);
        Assert.Equal("boom", baseResult.ErrorMessage);
        Assert.Equal(SlimLOErrorCode.ExportFailed, baseResult.ErrorCode);
    }
}

// ===========================================================================
// ConversionDiagnostic tests
// ===========================================================================

public class ConversionDiagnosticTests
{
    [Fact]
    public void Constructor_SetsAllProperties()
    {
        var diag = new ConversionDiagnostic(
            DiagnosticSeverity.Warning,
            DiagnosticCategory.Font,
            "Could not find font 'Arial'",
            "Arial",
            "Liberation Sans");

        Assert.Equal(DiagnosticSeverity.Warning, diag.Severity);
        Assert.Equal(DiagnosticCategory.Font, diag.Category);
        Assert.Equal("Could not find font 'Arial'", diag.Message);
        Assert.Equal("Arial", diag.FontName);
        Assert.Equal("Liberation Sans", diag.SubstitutedWith);
    }

    [Fact]
    public void Constructor_OptionalProperties_DefaultToNull()
    {
        var diag = new ConversionDiagnostic(
            DiagnosticSeverity.Info,
            DiagnosticCategory.General,
            "Info message");

        Assert.Null(diag.FontName);
        Assert.Null(diag.SubstitutedWith);
    }

    [Fact]
    public void ToString_FormatsCorrectly()
    {
        var diag = new ConversionDiagnostic(
            DiagnosticSeverity.Warning,
            DiagnosticCategory.Font,
            "Could not find font 'Arial'");

        Assert.Equal("[Warning:Font] Could not find font 'Arial'", diag.ToString());
    }

    [Fact]
    public void ToString_InfoGeneral()
    {
        var diag = new ConversionDiagnostic(
            DiagnosticSeverity.Info,
            DiagnosticCategory.General,
            "Something");

        Assert.Equal("[Info:General] Something", diag.ToString());
    }

    [Fact]
    public void ToString_LayoutCategory()
    {
        var diag = new ConversionDiagnostic(
            DiagnosticSeverity.Warning,
            DiagnosticCategory.Layout,
            "Layout issue");

        Assert.Equal("[Warning:Layout] Layout issue", diag.ToString());
    }
}

// ===========================================================================
// ConversionOptions tests
// ===========================================================================

public class ConversionOptionsTests
{
    [Fact]
    public void Defaults_AreReasonable()
    {
        var opts = new ConversionOptions();
        Assert.Equal(PdfVersion.Default, opts.PdfVersion);
        Assert.Equal(0, opts.JpegQuality);
        Assert.Equal(0, opts.Dpi);
        Assert.False(opts.TaggedPdf);
        Assert.Null(opts.PageRange);
        Assert.Null(opts.Password);
    }

    [Fact]
    public void RecordEquality_Works()
    {
        var opts1 = new ConversionOptions { PdfVersion = PdfVersion.PdfA2, Dpi = 150, TaggedPdf = true };
        var opts2 = new ConversionOptions { PdfVersion = PdfVersion.PdfA2, Dpi = 150, TaggedPdf = true };
        Assert.Equal(opts1, opts2);
    }

    [Fact]
    public void RecordInequality_Works()
    {
        var opts1 = new ConversionOptions { Dpi = 150 };
        var opts2 = new ConversionOptions { Dpi = 300 };
        Assert.NotEqual(opts1, opts2);
    }

    [Fact]
    public void WithExpression_CreatesModifiedCopy()
    {
        var opts1 = new ConversionOptions { PdfVersion = PdfVersion.PdfA1, Dpi = 150 };
        var opts2 = opts1 with { Dpi = 300 };
        Assert.Equal(PdfVersion.PdfA1, opts2.PdfVersion);
        Assert.Equal(300, opts2.Dpi);
        Assert.Equal(150, opts1.Dpi);
    }

    [Fact]
    public void AllProperties_CanBeSet()
    {
        var opts = new ConversionOptions
        {
            PdfVersion = PdfVersion.PdfA3,
            JpegQuality = 85,
            Dpi = 300,
            TaggedPdf = true,
            PageRange = "1-5",
            Password = "secret"
        };
        Assert.Equal(PdfVersion.PdfA3, opts.PdfVersion);
        Assert.Equal(85, opts.JpegQuality);
        Assert.Equal(300, opts.Dpi);
        Assert.True(opts.TaggedPdf);
        Assert.Equal("1-5", opts.PageRange);
        Assert.Equal("secret", opts.Password);
    }
}

// ===========================================================================
// PdfConverterOptions tests
// ===========================================================================

public class PdfConverterOptionsTests
{
    [Fact]
    public void Defaults_AreReasonable()
    {
        var opts = new PdfConverterOptions();
        Assert.Null(opts.ResourcePath);
        Assert.Null(opts.FontDirectories);
        Assert.Equal(TimeSpan.FromMinutes(5), opts.ConversionTimeout);
        Assert.Equal(1, opts.MaxWorkers);
        Assert.Equal(0, opts.MaxConversionsPerWorker);
        Assert.False(opts.WarmUp);
    }

    [Fact]
    public void AllProperties_CanBeSet()
    {
        var opts = new PdfConverterOptions
        {
            ResourcePath = "/opt/slimlo",
            FontDirectories = new[] { "/usr/share/fonts" },
            ConversionTimeout = TimeSpan.FromMinutes(10),
            MaxWorkers = 4,
            MaxConversionsPerWorker = 100,
            WarmUp = true
        };
        Assert.Equal("/opt/slimlo", opts.ResourcePath);
        Assert.Single(opts.FontDirectories!);
        Assert.Equal(TimeSpan.FromMinutes(10), opts.ConversionTimeout);
        Assert.Equal(4, opts.MaxWorkers);
        Assert.Equal(100, opts.MaxConversionsPerWorker);
        Assert.True(opts.WarmUp);
    }
}

// ===========================================================================
// SlimLOException tests
// ===========================================================================

public class SlimLOExceptionTests
{
    [Fact]
    public void Constructor_WithMessageAndCode()
    {
        var ex = new SlimLOException("test error", SlimLOErrorCode.ExportFailed);
        Assert.Equal("test error", ex.Message);
        Assert.Equal(SlimLOErrorCode.ExportFailed, ex.ErrorCode);
    }

    [Fact]
    public void Constructor_DefaultCode_IsUnknown()
    {
        var ex = new SlimLOException("test error");
        Assert.Equal(SlimLOErrorCode.Unknown, ex.ErrorCode);
    }

    [Fact]
    public void Constructor_WithInnerException()
    {
        var inner = new InvalidOperationException("inner");
        var ex = new SlimLOException("test error", SlimLOErrorCode.InitFailed, inner);
        Assert.Equal("test error", ex.Message);
        Assert.Equal(SlimLOErrorCode.InitFailed, ex.ErrorCode);
        Assert.Same(inner, ex.InnerException);
    }

    [Fact]
    public void InheritsFromException()
    {
        var ex = new SlimLOException("test");
        Assert.IsAssignableFrom<Exception>(ex);
    }
}

// ===========================================================================
// Enum tests
// ===========================================================================

public class EnumTests
{
    [Theory]
    [InlineData(DocumentFormat.Unknown, 0)]
    [InlineData(DocumentFormat.Docx, 1)]
    [InlineData(DocumentFormat.Xlsx, 2)]
    [InlineData(DocumentFormat.Pptx, 3)]
    public void DocumentFormat_ValuesMatchNative(DocumentFormat format, int expected)
    {
        Assert.Equal(expected, (int)format);
    }

    [Theory]
    [InlineData(PdfVersion.Default, 0)]
    [InlineData(PdfVersion.PdfA1, 1)]
    [InlineData(PdfVersion.PdfA2, 2)]
    [InlineData(PdfVersion.PdfA3, 3)]
    public void PdfVersion_ValuesMatchNative(PdfVersion version, int expected)
    {
        Assert.Equal(expected, (int)version);
    }

    [Theory]
    [InlineData(SlimLOErrorCode.Ok, 0)]
    [InlineData(SlimLOErrorCode.InitFailed, 1)]
    [InlineData(SlimLOErrorCode.LoadFailed, 2)]
    [InlineData(SlimLOErrorCode.ExportFailed, 3)]
    [InlineData(SlimLOErrorCode.InvalidFormat, 4)]
    [InlineData(SlimLOErrorCode.FileNotFound, 5)]
    [InlineData(SlimLOErrorCode.OutOfMemory, 6)]
    [InlineData(SlimLOErrorCode.PermissionDenied, 7)]
    [InlineData(SlimLOErrorCode.AlreadyInitialized, 8)]
    [InlineData(SlimLOErrorCode.NotInitialized, 9)]
    [InlineData(SlimLOErrorCode.InvalidArgument, 10)]
    [InlineData(SlimLOErrorCode.Unknown, 99)]
    public void SlimLOErrorCode_ValuesMatchNative(SlimLOErrorCode code, int expected)
    {
        Assert.Equal(expected, (int)code);
    }

    [Theory]
    [InlineData(DiagnosticSeverity.Info, 0)]
    [InlineData(DiagnosticSeverity.Warning, 1)]
    public void DiagnosticSeverity_HasExpectedValues(DiagnosticSeverity severity, int expected)
    {
        Assert.Equal(expected, (int)severity);
    }

    [Theory]
    [InlineData(DiagnosticCategory.General, 0)]
    [InlineData(DiagnosticCategory.Font, 1)]
    [InlineData(DiagnosticCategory.Layout, 2)]
    public void DiagnosticCategory_HasExpectedValues(DiagnosticCategory cat, int expected)
    {
        Assert.Equal(expected, (int)cat);
    }
}

// ===========================================================================
// Protocol tests (message framing + serialization)
// ===========================================================================

public class ProtocolTests
{
    [Fact]
    public async Task WriteAndRead_RoundTrips()
    {
        var ms = new MemoryStream();
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"test\"}");

        await Protocol.WriteMessageAsync(ms, payload, CancellationToken.None);
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);

        Assert.NotNull(result);
        Assert.Equal(payload, result);
    }

    [Fact]
    public async Task ReadMessage_ReturnsNull_OnEmptyStream()
    {
        var ms = new MemoryStream(Array.Empty<byte>());
        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.Null(result);
    }

    [Fact]
    public async Task ReadMessage_ReturnsNull_OnPartialLengthHeader()
    {
        var ms = new MemoryStream(new byte[] { 0x01, 0x00 }); // only 2 bytes of 4-byte header
        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.Null(result);
    }

    [Fact]
    public async Task ReadMessage_ReturnsNull_OnTruncatedPayload()
    {
        var ms = new MemoryStream();
        var lengthBytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(lengthBytes, 100); // claim 100 bytes
        ms.Write(lengthBytes);
        ms.Write(new byte[50]); // only 50 bytes present
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.Null(result); // EOF mid-message
    }

    [Fact]
    public async Task ReadMessage_ThrowsOnOversizedMessage()
    {
        var ms = new MemoryStream();
        var lengthBytes = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(lengthBytes, 300_000_000); // 300 MB > 256 MB limit
        ms.Write(lengthBytes);
        ms.Position = 0;

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => Protocol.ReadMessageAsync(ms, CancellationToken.None));
    }

    [Fact]
    public async Task WriteAndRead_MultipleMessages()
    {
        var ms = new MemoryStream();
        var msg1 = Encoding.UTF8.GetBytes("{\"a\":1}");
        var msg2 = Encoding.UTF8.GetBytes("{\"b\":2}");
        var msg3 = Encoding.UTF8.GetBytes("{\"c\":3}");

        await Protocol.WriteMessageAsync(ms, msg1, CancellationToken.None);
        await Protocol.WriteMessageAsync(ms, msg2, CancellationToken.None);
        await Protocol.WriteMessageAsync(ms, msg3, CancellationToken.None);
        ms.Position = 0;

        var r1 = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        var r2 = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        var r3 = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        var r4 = await Protocol.ReadMessageAsync(ms, CancellationToken.None);

        Assert.Equal(msg1, r1);
        Assert.Equal(msg2, r2);
        Assert.Equal(msg3, r3);
        Assert.Null(r4); // EOF
    }

    [Fact]
    public async Task WriteAndRead_EmptyPayload()
    {
        var ms = new MemoryStream();
        var payload = Array.Empty<byte>();

        await Protocol.WriteMessageAsync(ms, payload, CancellationToken.None);
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.NotNull(result);
        Assert.Empty(result);
    }

    [Fact]
    public async Task WriteAndRead_LargePayload()
    {
        var ms = new MemoryStream();
        var payload = new byte[1024 * 1024]; // 1 MB
        Random.Shared.NextBytes(payload);

        await Protocol.WriteMessageAsync(ms, payload, CancellationToken.None);
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.NotNull(result);
        Assert.Equal(payload, result);
    }

    [Fact]
    public void Serialize_InitRequest()
    {
        var request = new InitRequest
        {
            ResourcePath = "/opt/slimlo",
            FontPaths = new[] { "/fonts/a", "/fonts/b" }
        };
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.Equal("init", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal("/opt/slimlo", doc.RootElement.GetProperty("resource_path").GetString());
        Assert.Equal(2, doc.RootElement.GetProperty("font_paths").GetArrayLength());
    }

    [Fact]
    public void Serialize_ConvertRequest()
    {
        var request = new ConvertRequest
        {
            Id = 42,
            Input = "/tmp/in.docx",
            Output = "/tmp/out.pdf",
            Format = 1,
            Options = new ConvertRequestOptions
            {
                PdfVersion = 2,
                JpegQuality = 85,
                Dpi = 300,
                TaggedPdf = true,
                PageRange = "1-5"
            }
        };
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.Equal("convert", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal(42, doc.RootElement.GetProperty("id").GetInt32());
        Assert.Equal("/tmp/in.docx", doc.RootElement.GetProperty("input").GetString());
        Assert.Equal(1, doc.RootElement.GetProperty("format").GetInt32());

        var opts = doc.RootElement.GetProperty("options");
        Assert.Equal(2, opts.GetProperty("pdf_version").GetInt32());
        Assert.Equal(85, opts.GetProperty("jpeg_quality").GetInt32());
        Assert.True(opts.GetProperty("tagged_pdf").GetBoolean());
        Assert.Equal("1-5", opts.GetProperty("page_range").GetString());
    }

    [Fact]
    public void Serialize_ConvertRequest_WithoutOptions()
    {
        var request = new ConvertRequest
        {
            Id = 1,
            Input = "/in.docx",
            Output = "/out.pdf",
            Format = 1
        };
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.False(doc.RootElement.TryGetProperty("options", out _));
    }

    [Fact]
    public void Serialize_QuitRequest()
    {
        var request = new QuitRequest();
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.Equal("quit", doc.RootElement.GetProperty("type").GetString());
    }

    [Fact]
    public void Deserialize_ParsesJsonCorrectly()
    {
        var jsonBytes = Encoding.UTF8.GetBytes("{\"type\":\"ready\",\"version\":\"1.0\"}");
        using var doc = Protocol.Deserialize(jsonBytes);

        Assert.Equal("ready", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal("1.0", doc.RootElement.GetProperty("version").GetString());
    }

    [Fact]
    public void ConvertRequestOptions_FromConversionOptions_Null_ReturnsNull()
    {
        Assert.Null(ConvertRequestOptions.FromConversionOptions(null));
    }

    [Fact]
    public void ConvertRequestOptions_FromConversionOptions_MapsProperties()
    {
        var opts = new ConversionOptions
        {
            PdfVersion = PdfVersion.PdfA2,
            JpegQuality = 75,
            Dpi = 200,
            TaggedPdf = true,
            PageRange = "1-3",
            Password = "pass123"
        };
        var mapped = ConvertRequestOptions.FromConversionOptions(opts)!;

        Assert.Equal(2, mapped.PdfVersion);
        Assert.Equal(75, mapped.JpegQuality);
        Assert.Equal(200, mapped.Dpi);
        Assert.True(mapped.TaggedPdf);
        Assert.Equal("1-3", mapped.PageRange);
        Assert.Equal("pass123", mapped.Password);
    }

    [Fact]
    public void Serialize_InitRequest_NoFontPaths_OmitsField()
    {
        var request = new InitRequest
        {
            ResourcePath = "/opt/slimlo"
        };
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.False(doc.RootElement.TryGetProperty("font_paths", out _));
    }

    [Fact]
    public void Serialize_ConvertBufferRequest()
    {
        var request = new ConvertBufferRequest
        {
            Id = 7,
            Format = 1,
            DataSize = 1024,
            Options = new ConvertRequestOptions { Dpi = 300 }
        };
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.Equal("convert_buffer", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal(7, doc.RootElement.GetProperty("id").GetInt32());
        Assert.Equal(1, doc.RootElement.GetProperty("format").GetInt32());
        Assert.Equal(1024, doc.RootElement.GetProperty("data_size").GetInt64());
        Assert.Equal(300, doc.RootElement.GetProperty("options").GetProperty("dpi").GetInt32());
    }

    [Fact]
    public void Serialize_ConvertBufferRequest_WithoutOptions_OmitsField()
    {
        var request = new ConvertBufferRequest { Id = 1, Format = 1, DataSize = 512 };
        var bytes = Protocol.Serialize(request);
        var json = Encoding.UTF8.GetString(bytes);

        using var doc = JsonDocument.Parse(json);
        Assert.False(doc.RootElement.TryGetProperty("options", out _));
    }

    [Fact]
    public async Task WriteAndRead_ReadOnlyMemory_RoundTrips()
    {
        var ms = new MemoryStream();
        var payload = new byte[] { 0x01, 0x02, 0x03, 0xFF };
        ReadOnlyMemory<byte> memory = payload.AsMemory();

        await Protocol.WriteMessageAsync(ms, memory, CancellationToken.None);
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.NotNull(result);
        Assert.Equal(payload, result);
    }

    [Fact]
    public async Task WriteAndRead_ReadOnlyMemory_LargePayload()
    {
        var ms = new MemoryStream();
        var payload = new byte[5 * 1024 * 1024]; // 5 MB
        Random.Shared.NextBytes(payload);

        await Protocol.WriteMessageAsync(ms, payload.AsMemory(), CancellationToken.None);
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.NotNull(result);
        Assert.Equal(payload, result);
    }

    [Fact]
    public async Task WriteAndRead_MixedByteArrayAndReadOnlyMemory()
    {
        var ms = new MemoryStream();
        var jsonPayload = Encoding.UTF8.GetBytes("{\"type\":\"convert_buffer\"}");
        var binaryPayload = new byte[] { 0xDE, 0xAD, 0xBE, 0xEF };

        await Protocol.WriteMessageAsync(ms, jsonPayload, CancellationToken.None);
        await Protocol.WriteMessageAsync(ms, binaryPayload.AsMemory(), CancellationToken.None);
        ms.Position = 0;

        var r1 = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        var r2 = await Protocol.ReadMessageAsync(ms, CancellationToken.None);

        Assert.Equal(jsonPayload, r1);
        Assert.Equal(binaryPayload, r2);
    }

    [Fact]
    public async Task WriteAndRead_ReadOnlyMemory_EmptyPayload()
    {
        var ms = new MemoryStream();
        await Protocol.WriteMessageAsync(ms, ReadOnlyMemory<byte>.Empty, CancellationToken.None);
        ms.Position = 0;

        var result = await Protocol.ReadMessageAsync(ms, CancellationToken.None);
        Assert.NotNull(result);
        Assert.Empty(result);
    }
}

// ===========================================================================
// StderrDiagnosticParser tests
// ===========================================================================

public class StderrDiagnosticParserTests
{
    private static JsonElement ParseJson(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.Clone();
    }

    [Fact]
    public void ParseFromJson_EmptyArray_ReturnsEmpty()
    {
        var element = ParseJson("[]");
        var result = StderrDiagnosticParser.ParseFromJson(element);
        Assert.Empty(result);
    }

    [Fact]
    public void ParseFromJson_NonArray_ReturnsEmpty()
    {
        var element = ParseJson("\"not an array\"");
        var result = StderrDiagnosticParser.ParseFromJson(element);
        Assert.Empty(result);
    }

    [Fact]
    public void ParseFromJson_NullValueKind_ReturnsEmpty()
    {
        var element = ParseJson("null");
        var result = StderrDiagnosticParser.ParseFromJson(element);
        Assert.Empty(result);
    }

    [Fact]
    public void ParseFromJson_FontWarning_FullProperties()
    {
        var json = "[{\"severity\":\"warning\",\"category\":\"font\"," +
            "\"message\":\"Could not find font 'Arial Narrow'\"," +
            "\"font\":\"Arial Narrow\",\"substituted_with\":\"Liberation Sans\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticSeverity.Warning, result[0].Severity);
        Assert.Equal(DiagnosticCategory.Font, result[0].Category);
        Assert.Equal("Could not find font 'Arial Narrow'", result[0].Message);
        Assert.Equal("Arial Narrow", result[0].FontName);
        Assert.Equal("Liberation Sans", result[0].SubstitutedWith);
    }

    [Fact]
    public void ParseFromJson_InfoSeverity()
    {
        var json = "[{\"severity\":\"info\",\"category\":\"general\",\"message\":\"Info message\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticSeverity.Info, result[0].Severity);
        Assert.Equal(DiagnosticCategory.General, result[0].Category);
    }

    [Fact]
    public void ParseFromJson_LayoutCategory()
    {
        var json = "[{\"severity\":\"warning\",\"category\":\"layout\",\"message\":\"Layout issue\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticCategory.Layout, result[0].Category);
    }

    [Fact]
    public void ParseFromJson_UnknownSeverity_DefaultsToWarning()
    {
        var json = "[{\"severity\":\"critical\",\"category\":\"font\",\"message\":\"msg\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticSeverity.Warning, result[0].Severity);
    }

    [Fact]
    public void ParseFromJson_UnknownCategory_DefaultsToGeneral()
    {
        var json = "[{\"severity\":\"warning\",\"category\":\"network\",\"message\":\"msg\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticCategory.General, result[0].Category);
    }

    [Fact]
    public void ParseFromJson_MinimalDiagnostic_MissingOptionalFields()
    {
        var json = "[{\"message\":\"just a message\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticSeverity.Warning, result[0].Severity);
        Assert.Equal(DiagnosticCategory.General, result[0].Category);
        Assert.Equal("just a message", result[0].Message);
        Assert.Null(result[0].FontName);
        Assert.Null(result[0].SubstitutedWith);
    }

    [Fact]
    public void ParseFromJson_MultipleDiagnostics()
    {
        var json = "[{\"severity\":\"warning\",\"category\":\"font\",\"message\":\"Font 1\",\"font\":\"F1\"}," +
            "{\"severity\":\"info\",\"category\":\"layout\",\"message\":\"Layout 1\"}," +
            "{\"severity\":\"warning\",\"category\":\"general\",\"message\":\"General 1\"}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Equal(3, result.Count);
        Assert.Equal("Font 1", result[0].Message);
        Assert.Equal("Layout 1", result[1].Message);
        Assert.Equal("General 1", result[2].Message);
    }

    [Fact]
    public void ParseFromJson_EmptyObject_UsesDefaults()
    {
        var json = "[{}]";
        var element = ParseJson(json);
        var result = StderrDiagnosticParser.ParseFromJson(element);

        Assert.Single(result);
        Assert.Equal(DiagnosticSeverity.Warning, result[0].Severity);
        Assert.Equal(DiagnosticCategory.General, result[0].Category);
        Assert.Equal("", result[0].Message);
    }
}

// ===========================================================================
// PdfConverter.Create tests (no worker needed for validation tests)
// ===========================================================================

public class PdfConverterCreateTests
{
    [Fact]
    public void Create_WithZeroMaxWorkers_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            PdfConverter.Create(new PdfConverterOptions { MaxWorkers = 0 }));
    }

    [Fact]
    public void Create_WithNegativeMaxWorkers_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            PdfConverter.Create(new PdfConverterOptions { MaxWorkers = -1 }));
    }

    [Fact]
    public void Version_DoesNotThrow()
    {
        // Version uses P/Invoke -- may return null if library not found,
        // but should never throw
        var version = PdfConverter.Version;
        // Can be null if native lib not available; just verify no crash
    }
}

// ===========================================================================
// PdfConverter integration tests (require worker + SLIMLO_RESOURCE_PATH)
// ===========================================================================

public class PdfConverterIntegrationTests : IAsyncDisposable
{
    private PdfConverter? _converter;

    private PdfConverter? GetOrCreateConverter()
    {
        if (_converter is not null) return _converter;
        if (!TestHelpers.CanRunIntegration()) return null;

        _converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath()
        });
        return _converter;
    }

    public async ValueTask DisposeAsync()
    {
        if (_converter is not null)
            await _converter.DisposeAsync();
    }

    // --- File conversion ---

    [Fact]
    public async Task ConvertAsync_ValidDocx_ProducesPdf()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var outputPdf = Path.Combine(Path.GetTempPath(), $"slimlo_test_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(testDocx, outputPdf);
            Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
            Assert.True(File.Exists(outputPdf));

            var pdfBytes = await File.ReadAllBytesAsync(outputPdf);
            Assert.True(pdfBytes.Length > 100);
            Assert.Equal((byte)'%', pdfBytes[0]);
            Assert.Equal((byte)'P', pdfBytes[1]);
            Assert.Equal((byte)'D', pdfBytes[2]);
            Assert.Equal((byte)'F', pdfBytes[3]);
        }
        finally
        {
            if (File.Exists(outputPdf)) File.Delete(outputPdf);
        }
    }

    [Fact]
    public async Task ConvertAsync_FileNotFound_ReturnsFailure()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var result = await converter.ConvertAsync(
            "/nonexistent/input.docx", "/tmp/output.pdf");

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.FileNotFound, result.ErrorCode);
        Assert.Contains("not found", result.ErrorMessage!);
    }

    [Fact]
    public async Task ConvertAsync_EmptyInputPath_Throws()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        await Assert.ThrowsAsync<ArgumentException>(() =>
            converter.ConvertAsync("", "/tmp/output.pdf"));
    }

    [Fact]
    public async Task ConvertAsync_EmptyOutputPath_Throws()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        await Assert.ThrowsAsync<ArgumentException>(() =>
            converter.ConvertAsync("/tmp/in.docx", ""));
    }

    // --- Buffer conversion ---

    [Fact]
    public async Task ConvertAsync_BufferValidDocx_ReturnsPdfBytes()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var docxBytes = await File.ReadAllBytesAsync(testDocx);
        var result = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);

        Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
        Assert.NotNull(result.Data);
        Assert.True(result.Data!.Length > 100);
        Assert.Equal((byte)'%', result.Data[0]);
        Assert.Equal((byte)'P', result.Data[1]);
        Assert.Equal((byte)'D', result.Data[2]);
        Assert.Equal((byte)'F', result.Data[3]);
    }

    [Fact]
    public async Task ConvertAsync_BufferEmptyInput_ReturnsFailure()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var result = await converter.ConvertAsync(
            ReadOnlyMemory<byte>.Empty, DocumentFormat.Docx);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidArgument, result.ErrorCode);
    }

    [Fact]
    public async Task ConvertAsync_BufferUnknownFormat_ReturnsFailure()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var result = await converter.ConvertAsync(
            new byte[] { 1, 2, 3 }, DocumentFormat.Unknown);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
    }

    [Theory]
    [InlineData(DocumentFormat.Xlsx)]
    [InlineData(DocumentFormat.Pptx)]
    public async Task ConvertAsync_BufferUnsupportedFormat_ReturnsFailure(DocumentFormat format)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var result = await converter.ConvertAsync(
            new byte[] { 1, 2, 3 }, format);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
    }

    // --- Format detection ---

    [Fact]
    public async Task ConvertAsync_DetectsDocxFormat()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(testDocx, output);
            Assert.True(result.Success);
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    [Theory]
    [InlineData(".xlsx")]
    [InlineData(".pptx")]
    public async Task ConvertAsync_FileUnsupportedExtension_ReturnsInvalidFormat(string extension)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var input = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}{extension}");
        var output = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}.pdf");

        try
        {
            await File.WriteAllBytesAsync(input, new byte[] { 1, 2, 3 });

            var result = await converter.ConvertAsync(input, output);

            Assert.False(result.Success);
            Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
            Assert.False(File.Exists(output));
        }
        finally
        {
            if (File.Exists(input)) File.Delete(input);
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- Fixture tests (complex documents) ---

    [Theory]
    [InlineData("multi_font.docx")]
    [InlineData("rich_formatting.docx")]
    [InlineData("unicode_text.docx")]
    [InlineData("large_document.docx")]
    public async Task ConvertAsync_ComplexFixture_Succeeds(string fixture)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var fixturePath = TestHelpers.FindFixture(fixture);
        if (fixturePath == null) return;

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(fixturePath, output);
            Assert.True(result.Success, $"Failed converting {fixture}: {result.ErrorMessage}");
            Assert.True(File.Exists(output), $"Output PDF not created for {fixture}");

            var pdfBytes = await File.ReadAllBytesAsync(output);
            Assert.True(pdfBytes.Length > 100, $"PDF too small for {fixture}: {pdfBytes.Length} bytes");
            Assert.Equal((byte)'%', pdfBytes[0]);
            Assert.Equal((byte)'P', pdfBytes[1]);
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    [Fact]
    public async Task ConvertAsync_MissingFontsFixture_StillConverts()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var fixturePath = TestHelpers.FindFixture("missing_fonts.docx");
        if (fixturePath == null) return;

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(fixturePath, output);
            Assert.True(result.Success, $"Failed converting missing_fonts.docx: {result.ErrorMessage}");
            Assert.True(File.Exists(output));

            var pdfBytes = await File.ReadAllBytesAsync(output);
            Assert.True(pdfBytes.Length > 100);
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- Options ---

    [Fact]
    public async Task ConvertAsync_WithConversionOptions_Succeeds()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;

        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(testDocx, output,
                new ConversionOptions
                {
                    Dpi = 150,
                    JpegQuality = 85,
                    TaggedPdf = true
                });
            Assert.True(result.Success, $"Failed with options: {result.ErrorMessage}");
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- Dispose ---

    [Fact]
    public async Task DisposeAsync_PreventsSubsequentConversions()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath()
        });

        await converter.DisposeAsync();

        await Assert.ThrowsAsync<ObjectDisposedException>(async () =>
            await converter.ConvertAsync("/tmp/in.docx", "/tmp/out.pdf"));
    }

    [Fact]
    public async Task Dispose_Sync_PreventsSubsequentConversions()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath()
        });

        converter.Dispose();

        await Assert.ThrowsAsync<ObjectDisposedException>(async () =>
            await converter.ConvertAsync("/tmp/in.docx", "/tmp/out.pdf"));
    }

    [Fact]
    public async Task DisposeAsync_CalledTwice_IsIdempotent()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath()
        });

        await converter.DisposeAsync();
        await converter.DisposeAsync(); // should not throw
    }

    // --- Custom font tests ---
    //
    // FontDirectories works cross-platform:
    // - Linux: SAL_FONTPATH → fontconfig
    // - macOS: CTFontManagerRegisterFontsForURL → CoreText (process-level)

    [Fact]
    public async Task ConvertAsync_WithCustomBarcodeFont_Succeeds()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var fixturePath = TestHelpers.FindFixture("barcode_font.docx");
        if (fixturePath == null) return;

        var fontDir = TestHelpers.FindFontDir();
        if (fontDir == null) return;

        await using var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath(),
            FontDirectories = [fontDir]
        });

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_barcode_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(fixturePath, output);
            Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
            Assert.True(File.Exists(output));

            var pdfBytes = await File.ReadAllBytesAsync(output);
            Assert.True(pdfBytes.Length > 100, "PDF too small");

            // PDF header check
            Assert.Equal((byte)'%', pdfBytes[0]);
            Assert.Equal((byte)'P', pdfBytes[1]);
            Assert.Equal((byte)'D', pdfBytes[2]);
            Assert.Equal((byte)'F', pdfBytes[3]);

            // The barcode font should be embedded in the PDF with its actual name
            // (possibly subset-prefixed like ABCDEF+LibreBarcode128-Regular)
            var pdfText = System.Text.Encoding.ASCII.GetString(pdfBytes);
            Assert.True(
                pdfText.Contains("Barcode") || pdfText.Contains("barcode"),
                "PDF should contain the barcode font when FontDirectories is set");

            // Verify no font substitution diagnostic for the barcode font
            var barcodeSubstitution = result.Diagnostics
                .Where(d => d.Category == DiagnosticCategory.Font)
                .Any(d => d.FontName?.Contains("Barcode") == true);
            Assert.False(barcodeSubstitution,
                "Barcode font was substituted despite being in FontDirectories");
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    [Fact]
    public async Task ConvertAsync_WithoutBarcodeFont_StillConverts()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var fixturePath = TestHelpers.FindFixture("barcode_font.docx");
        if (fixturePath == null) return;

        // Create converter WITHOUT custom font directory — font will be substituted
        await using var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath()
        });

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_nobarcode_{Guid.NewGuid():N}.pdf");
        try
        {
            var result = await converter.ConvertAsync(fixturePath, output);
            Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
            Assert.True(File.Exists(output));

            // The PDF should be valid even without the barcode font
            var pdfBytes = await File.ReadAllBytesAsync(output);
            Assert.True(pdfBytes.Length > 100, "PDF too small");

            // The barcode font should NOT appear in the PDF since it's not available
            var pdfText = System.Text.Encoding.ASCII.GetString(pdfBytes);
            Assert.DoesNotContain("LibreBarcode", pdfText);
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- Concurrent conversions ---

    [Fact]
    public async Task ConvertAsync_ConcurrentCalls_AllSucceed()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        await using var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath(),
            MaxWorkers = 1
        });

        var tasks = new Task<ConversionResult>[3];
        var outputs = new string[3];

        for (int i = 0; i < 3; i++)
        {
            outputs[i] = Path.Combine(Path.GetTempPath(), $"slimlo_conc_{Guid.NewGuid():N}.pdf");
            var output = outputs[i];
            tasks[i] = converter.ConvertAsync(testDocx, output);
        }

        var results = await Task.WhenAll(tasks);

        try
        {
            foreach (var result in results)
            {
                Assert.True(result.Success, $"Concurrent conversion failed: {result.ErrorMessage}");
            }
        }
        finally
        {
            foreach (var output in outputs)
            {
                if (File.Exists(output)) File.Delete(output);
            }
        }
    }
}

// ===========================================================================
// PdfConverter Stream validation tests (argument checking, no conversion needed)
// ===========================================================================

public class PdfConverterStreamValidationTests
{
    // -- Stream → Stream validation --

    [Fact]
    public async Task ConvertAsync_StreamToStream_NullInput_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            converter.ConvertAsync((Stream)null!, new MemoryStream(), DocumentFormat.Docx));
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_NullOutput_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            converter.ConvertAsync(new MemoryStream(new byte[] { 1 }), (Stream)null!, DocumentFormat.Docx));
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_UnknownFormat_ReturnsFailure()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var result = await converter.ConvertAsync(
            new MemoryStream(new byte[] { 1 }), new MemoryStream(), DocumentFormat.Unknown);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
    }

    [Theory]
    [InlineData(DocumentFormat.Xlsx)]
    [InlineData(DocumentFormat.Pptx)]
    public async Task ConvertAsync_StreamToStream_UnsupportedFormat_ReturnsFailure(DocumentFormat format)
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var result = await converter.ConvertAsync(
            new MemoryStream(new byte[] { 1, 2, 3 }), new MemoryStream(), format);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_NonReadableInput_ReturnsFailure()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var closedStream = new MemoryStream();
        closedStream.Close();

        var result = await converter.ConvertAsync(
            closedStream, new MemoryStream(), DocumentFormat.Docx);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidArgument, result.ErrorCode);
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_NonWritableOutput_ReturnsFailure()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var readOnlyStream = new MemoryStream(new byte[] { 1 }, writable: false);

        var result = await converter.ConvertAsync(
            new MemoryStream(new byte[] { 1 }), readOnlyStream, DocumentFormat.Docx);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidArgument, result.ErrorCode);
    }

    // -- Stream → File validation --

    [Fact]
    public async Task ConvertAsync_StreamToFile_NullInput_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            converter.ConvertAsync((Stream)null!, "/tmp/out.pdf", DocumentFormat.Docx));
    }

    [Fact]
    public async Task ConvertAsync_StreamToFile_EmptyOutputPath_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        await Assert.ThrowsAsync<ArgumentException>(() =>
            converter.ConvertAsync(new MemoryStream(new byte[] { 1 }), "", DocumentFormat.Docx));
    }

    [Fact]
    public async Task ConvertAsync_StreamToFile_UnknownFormat_ReturnsFailure()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var result = await converter.ConvertAsync(
            new MemoryStream(new byte[] { 1 }), "/tmp/out.pdf", DocumentFormat.Unknown);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
    }

    [Theory]
    [InlineData(DocumentFormat.Xlsx)]
    [InlineData(DocumentFormat.Pptx)]
    public async Task ConvertAsync_StreamToFile_UnsupportedFormat_ReturnsFailure(DocumentFormat format)
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var result = await converter.ConvertAsync(
            new MemoryStream(new byte[] { 1, 2, 3 }),
            Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}.pdf"),
            format);

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
    }

    // -- File → Stream validation --

    [Fact]
    public async Task ConvertAsync_FileToStream_EmptyInputPath_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        await Assert.ThrowsAsync<ArgumentException>(() =>
            converter.ConvertAsync("", new MemoryStream()));
    }

    [Fact]
    public async Task ConvertAsync_FileToStream_NullOutput_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            converter.ConvertAsync("/tmp/in.docx", (Stream)null!));
    }

    [Fact]
    public async Task ConvertAsync_FileToStream_FileNotFound_ReturnsFailure()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var result = await converter.ConvertAsync(
            "/nonexistent/input.docx", new MemoryStream());

        Assert.False(result.Success);
        Assert.Equal(SlimLOErrorCode.FileNotFound, result.ErrorCode);
    }

    [Theory]
    [InlineData(".xlsx")]
    [InlineData(".pptx")]
    public async Task ConvertAsync_FileToStream_UnsupportedExtension_ReturnsFailure(string extension)
    {
        if (!TestHelpers.CanRunIntegration()) return;
        await using var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });

        var input = Path.Combine(Path.GetTempPath(), $"slimlo_{Guid.NewGuid():N}{extension}");
        try
        {
            await File.WriteAllBytesAsync(input, new byte[] { 1, 2, 3 });
            var result = await converter.ConvertAsync(input, new MemoryStream());

            Assert.False(result.Success);
            Assert.Equal(SlimLOErrorCode.InvalidFormat, result.ErrorCode);
        }
        finally
        {
            if (File.Exists(input)) File.Delete(input);
        }
    }

    // -- Disposed converter --

    [Fact]
    public async Task ConvertAsync_StreamToStream_AfterDispose_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });
        await converter.DisposeAsync();

        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            converter.ConvertAsync(new MemoryStream(), new MemoryStream(), DocumentFormat.Docx));
    }

    [Fact]
    public async Task ConvertAsync_StreamToFile_AfterDispose_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });
        await converter.DisposeAsync();

        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            converter.ConvertAsync(new MemoryStream(), "/tmp/out.pdf", DocumentFormat.Docx));
    }

    [Fact]
    public async Task ConvertAsync_FileToStream_AfterDispose_Throws()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        var converter = PdfConverter.Create(new PdfConverterOptions
            { ResourcePath = TestHelpers.GetResourcePath() });
        await converter.DisposeAsync();

        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            converter.ConvertAsync("/tmp/in.docx", new MemoryStream()));
    }
}

// ===========================================================================
// PdfConverter Stream integration tests (require worker + SLIMLO_RESOURCE_PATH)
// ===========================================================================

public class PdfConverterStreamIntegrationTests : IAsyncDisposable
{
    private PdfConverter? _converter;

    private PdfConverter? GetOrCreateConverter()
    {
        if (_converter is not null) return _converter;
        if (!TestHelpers.CanRunIntegration()) return null;
        _converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath()
        });
        return _converter;
    }

    public async ValueTask DisposeAsync()
    {
        if (_converter is not null)
            await _converter.DisposeAsync();
    }

    // --- Stream → Stream ---

    [Fact]
    public async Task ConvertAsync_StreamToStream_ValidDocx_ProducesPdf()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        await using var inputFs = File.OpenRead(testDocx);
        using var outputMs = new MemoryStream();

        var result = await converter.ConvertAsync(
            inputFs, outputMs, DocumentFormat.Docx);

        Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
        Assert.True(outputMs.Length > 100, $"PDF too small: {outputMs.Length}");

        outputMs.Position = 0;
        var header = new byte[4];
        await outputMs.ReadAsync(header);
        Assert.Equal((byte)'%', header[0]);
        Assert.Equal((byte)'P', header[1]);
        Assert.Equal((byte)'D', header[2]);
        Assert.Equal((byte)'F', header[3]);
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_MemoryStreamInput_Works()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var docxBytes = await File.ReadAllBytesAsync(testDocx);
        using var inputMs = new MemoryStream(docxBytes);
        using var outputMs = new MemoryStream();

        var result = await converter.ConvertAsync(
            inputMs, outputMs, DocumentFormat.Docx);

        Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
        Assert.True(outputMs.Length > 100);
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_PreservesDiagnostics()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var fixture = TestHelpers.FindFixture("missing_fonts.docx");
        if (fixture == null) return;

        await using var inputFs = File.OpenRead(fixture);
        using var outputMs = new MemoryStream();

        var result = await converter.ConvertAsync(
            inputFs, outputMs, DocumentFormat.Docx);

        Assert.True(result.Success);
        Assert.NotNull(result.Diagnostics);
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_NoTempDirectoryCreated()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var tempDir = Path.Combine(Path.GetTempPath(), "slimlo");
        if (Directory.Exists(tempDir))
            Directory.Delete(tempDir, recursive: true);

        var docxBytes = await File.ReadAllBytesAsync(testDocx);
        using var inputMs = new MemoryStream(docxBytes);
        using var outputMs = new MemoryStream();

        var result = await converter.ConvertAsync(
            inputMs, outputMs, DocumentFormat.Docx);

        Assert.True(result.Success);
        Assert.True(outputMs.Length > 100);
        Assert.False(Directory.Exists(tempDir),
            "slimlo temp directory should not be created for buffer/stream conversions");
    }

    // --- Stream → File ---

    [Fact]
    public async Task ConvertAsync_StreamToFile_ValidDocx_ProducesPdf()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_s2f_{Guid.NewGuid():N}.pdf");
        try
        {
            await using var inputFs = File.OpenRead(testDocx);
            var result = await converter.ConvertAsync(
                inputFs, output, DocumentFormat.Docx);

            Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
            Assert.True(File.Exists(output));

            var pdfBytes = await File.ReadAllBytesAsync(output);
            Assert.True(pdfBytes.Length > 100);
            Assert.Equal((byte)'%', pdfBytes[0]);
            Assert.Equal((byte)'P', pdfBytes[1]);
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- File → Stream ---

    [Fact]
    public async Task ConvertAsync_FileToStream_ValidDocx_ProducesPdf()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        using var outputMs = new MemoryStream();
        var result = await converter.ConvertAsync(testDocx, outputMs);

        Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
        Assert.True(outputMs.Length > 100, $"PDF too small: {outputMs.Length}");

        outputMs.Position = 0;
        var header = new byte[4];
        await outputMs.ReadAsync(header);
        Assert.Equal((byte)'%', header[0]);
        Assert.Equal((byte)'P', header[1]);
        Assert.Equal((byte)'D', header[2]);
        Assert.Equal((byte)'F', header[3]);
    }

    [Fact]
    public async Task ConvertAsync_FileToStream_NoTempDirectoryCreated()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var tempDir = Path.Combine(Path.GetTempPath(), "slimlo");
        if (Directory.Exists(tempDir))
            Directory.Delete(tempDir, recursive: true);

        using var outputMs = new MemoryStream();
        var result = await converter.ConvertAsync(testDocx, outputMs);

        Assert.True(result.Success);
        Assert.True(outputMs.Length > 100);
        Assert.False(Directory.Exists(tempDir),
            "slimlo temp directory should not be created for file→stream conversions");
    }

    // --- Complex fixtures with stream overloads ---

    [Theory]
    [InlineData("multi_font.docx")]
    [InlineData("rich_formatting.docx")]
    [InlineData("unicode_text.docx")]
    [InlineData("large_document.docx")]
    public async Task ConvertAsync_StreamToStream_ComplexFixture_Succeeds(string fixture)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var fixturePath = TestHelpers.FindFixture(fixture);
        if (fixturePath == null) return;

        await using var inputFs = File.OpenRead(fixturePath);
        using var outputMs = new MemoryStream();

        var result = await converter.ConvertAsync(
            inputFs, outputMs, DocumentFormat.Docx);

        Assert.True(result.Success, $"Failed converting {fixture}: {result.ErrorMessage}");
        Assert.True(outputMs.Length > 100, $"PDF too small for {fixture}: {outputMs.Length}");
    }

    // --- No temp directory tests ---

    [Fact]
    public async Task ConvertAsync_BufferRoundTrip_NoTempDirectoryCreated()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var tempDir = Path.Combine(Path.GetTempPath(), "slimlo");
        if (Directory.Exists(tempDir))
            Directory.Delete(tempDir, recursive: true);

        var docxBytes = await File.ReadAllBytesAsync(testDocx);
        var result = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);

        Assert.True(result.Success);
        Assert.NotNull(result.Data);
        Assert.True(result.Data!.Length > 100);
        Assert.False(Directory.Exists(tempDir),
            "slimlo temp directory should not be created for buffer conversions");
    }

    [Fact]
    public async Task ConvertAsync_StreamToFile_NoTempDirectoryCreated()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        var tempDir = Path.Combine(Path.GetTempPath(), "slimlo");
        if (Directory.Exists(tempDir))
            Directory.Delete(tempDir, recursive: true);

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_s2f_{Guid.NewGuid():N}.pdf");
        try
        {
            var docxBytes = await File.ReadAllBytesAsync(testDocx);
            using var inputMs = new MemoryStream(docxBytes);
            var result = await converter.ConvertAsync(inputMs, output, DocumentFormat.Docx);

            Assert.True(result.Success);
            Assert.True(File.Exists(output));
            Assert.False(Directory.Exists(tempDir),
                "slimlo temp directory should not be created for stream→file conversions");
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- Buffer conversion with fixtures ---

    [Theory]
    [InlineData("multi_font.docx")]
    [InlineData("rich_formatting.docx")]
    [InlineData("unicode_text.docx")]
    [InlineData("large_document.docx")]
    public async Task ConvertAsync_Buffer_ComplexFixture_Succeeds(string fixture)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var fixturePath = TestHelpers.FindFixture(fixture);
        if (fixturePath == null) return;

        var docxBytes = await File.ReadAllBytesAsync(fixturePath);
        var result = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);

        Assert.True(result.Success, $"Failed converting {fixture}: {result.ErrorMessage}");
        Assert.NotNull(result.Data);
        Assert.True(result.Data!.Length > 100, $"PDF too small for {fixture}: {result.Data.Length} bytes");
        Assert.Equal((byte)'%', result.Data[0]);
        Assert.Equal((byte)'P', result.Data[1]);
        Assert.Equal((byte)'D', result.Data[2]);
        Assert.Equal((byte)'F', result.Data[3]);
    }

    [Fact]
    public async Task ConvertAsync_Buffer_MissingFontsFixture_StillConverts()
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var fixturePath = TestHelpers.FindFixture("missing_fonts.docx");
        if (fixturePath == null) return;

        var docxBytes = await File.ReadAllBytesAsync(fixturePath);
        var result = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);

        Assert.True(result.Success, $"Failed converting missing_fonts.docx: {result.ErrorMessage}");
        Assert.NotNull(result.Data);
        Assert.True(result.Data!.Length > 100);
    }

    // --- File → Stream with fixtures ---

    [Theory]
    [InlineData("multi_font.docx")]
    [InlineData("rich_formatting.docx")]
    [InlineData("unicode_text.docx")]
    [InlineData("large_document.docx")]
    public async Task ConvertAsync_FileToStream_ComplexFixture_Succeeds(string fixture)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var fixturePath = TestHelpers.FindFixture(fixture);
        if (fixturePath == null) return;

        using var outputMs = new MemoryStream();
        var result = await converter.ConvertAsync(fixturePath, outputMs);

        Assert.True(result.Success, $"Failed converting {fixture}: {result.ErrorMessage}");
        Assert.True(outputMs.Length > 100, $"PDF too small for {fixture}: {outputMs.Length}");

        outputMs.Position = 0;
        var header = new byte[4];
        await outputMs.ReadAsync(header);
        Assert.Equal((byte)'%', header[0]);
        Assert.Equal((byte)'P', header[1]);
        Assert.Equal((byte)'D', header[2]);
        Assert.Equal((byte)'F', header[3]);
    }

    // --- Stream → File with fixtures ---

    [Theory]
    [InlineData("multi_font.docx")]
    [InlineData("rich_formatting.docx")]
    [InlineData("unicode_text.docx")]
    [InlineData("large_document.docx")]
    public async Task ConvertAsync_StreamToFile_ComplexFixture_Succeeds(string fixture)
    {
        var converter = GetOrCreateConverter();
        if (converter is null) return;
        var fixturePath = TestHelpers.FindFixture(fixture);
        if (fixturePath == null) return;

        var output = Path.Combine(Path.GetTempPath(), $"slimlo_s2f_{Guid.NewGuid():N}.pdf");
        try
        {
            var docxBytes = await File.ReadAllBytesAsync(fixturePath);
            using var inputMs = new MemoryStream(docxBytes);
            var result = await converter.ConvertAsync(inputMs, output, DocumentFormat.Docx);

            Assert.True(result.Success, $"Failed converting {fixture}: {result.ErrorMessage}");
            Assert.True(File.Exists(output), $"Output PDF not created for {fixture}");

            var pdfBytes = await File.ReadAllBytesAsync(output);
            Assert.True(pdfBytes.Length > 100, $"PDF too small for {fixture}: {pdfBytes.Length} bytes");
            Assert.Equal((byte)'%', pdfBytes[0]);
            Assert.Equal((byte)'P', pdfBytes[1]);
        }
        finally
        {
            if (File.Exists(output)) File.Delete(output);
        }
    }

    // --- Barcode font via buffer/stream ---

    [Fact]
    public async Task ConvertAsync_Buffer_WithCustomBarcodeFont_Succeeds()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var fixturePath = TestHelpers.FindFixture("barcode_font.docx");
        if (fixturePath == null) return;

        var fontDir = TestHelpers.FindFontDir();
        if (fontDir == null) return;

        await using var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath(),
            FontDirectories = [fontDir]
        });

        var docxBytes = await File.ReadAllBytesAsync(fixturePath);
        var result = await converter.ConvertAsync(docxBytes.AsMemory(), DocumentFormat.Docx);

        Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
        Assert.NotNull(result.Data);
        Assert.True(result.Data!.Length > 100, "PDF too small");

        // PDF header check
        Assert.Equal((byte)'%', result.Data[0]);
        Assert.Equal((byte)'P', result.Data[1]);
        Assert.Equal((byte)'D', result.Data[2]);
        Assert.Equal((byte)'F', result.Data[3]);

        // The barcode font should be embedded in the PDF
        var pdfText = Encoding.ASCII.GetString(result.Data);
        Assert.True(
            pdfText.Contains("Barcode") || pdfText.Contains("barcode"),
            "PDF should contain the barcode font when FontDirectories is set");
    }

    [Fact]
    public async Task ConvertAsync_StreamToStream_WithCustomBarcodeFont_Succeeds()
    {
        if (!TestHelpers.CanRunIntegration()) return;

        var fixturePath = TestHelpers.FindFixture("barcode_font.docx");
        if (fixturePath == null) return;

        var fontDir = TestHelpers.FindFontDir();
        if (fontDir == null) return;

        await using var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath(),
            FontDirectories = [fontDir]
        });

        var docxBytes = await File.ReadAllBytesAsync(fixturePath);
        using var inputMs = new MemoryStream(docxBytes);
        using var outputMs = new MemoryStream();

        var result = await converter.ConvertAsync(inputMs, outputMs, DocumentFormat.Docx);

        Assert.True(result.Success, $"Conversion failed: {result.ErrorMessage}");
        Assert.True(outputMs.Length > 100, "PDF too small");

        // The barcode font should be embedded
        var pdfText = Encoding.ASCII.GetString(outputMs.ToArray());
        Assert.True(
            pdfText.Contains("Barcode") || pdfText.Contains("barcode"),
            "PDF should contain the barcode font when FontDirectories is set");
    }

    // --- Concurrent stream conversions ---

    [Fact]
    public async Task ConvertAsync_ConcurrentStreamToStream_AllSucceed()
    {
        if (!TestHelpers.CanRunIntegration()) return;
        var testDocx = TestHelpers.FindTestDocx();
        if (testDocx == null) return;

        await using var converter = PdfConverter.Create(new PdfConverterOptions
        {
            ResourcePath = TestHelpers.GetResourcePath(),
            MaxWorkers = 1
        });

        var docxBytes = await File.ReadAllBytesAsync(testDocx);
        var tasks = new Task<ConversionResult>[3];
        var outputs = new MemoryStream[3];

        for (int i = 0; i < 3; i++)
        {
            outputs[i] = new MemoryStream();
            var input = new MemoryStream(docxBytes);
            var output = outputs[i];
            tasks[i] = converter.ConvertAsync(input, output, DocumentFormat.Docx);
        }

        var results = await Task.WhenAll(tasks);

        foreach (var result in results)
            Assert.True(result.Success, $"Concurrent stream conversion failed: {result.ErrorMessage}");

        foreach (var output in outputs)
        {
            Assert.True(output.Length > 100);
            output.Dispose();
        }
    }
}
