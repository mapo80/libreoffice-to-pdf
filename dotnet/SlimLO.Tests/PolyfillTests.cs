using System;
using System.Runtime.InteropServices;
using SlimLO.Internal;
using Xunit;

namespace SlimLO.Tests;

// ===========================================================================
// ThrowHelpers tests (polyfill for NS2.0)
// ===========================================================================

public class ThrowHelperTests
{
    [Fact]
    public void ThrowIfDisposed_WhenDisposed_ThrowsObjectDisposedException()
    {
        Assert.Throws<ObjectDisposedException>(() =>
            ThrowHelpers.ThrowIfDisposed(true, this));
    }

    [Fact]
    public void ThrowIfDisposed_WhenNotDisposed_DoesNotThrow()
    {
        ThrowHelpers.ThrowIfDisposed(false, this); // should not throw
    }

    [Fact]
    public void ThrowIfNullOrEmpty_Null_ThrowsArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            ThrowHelpers.ThrowIfNullOrEmpty(null!));
    }

    [Fact]
    public void ThrowIfNullOrEmpty_Empty_ThrowsArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            ThrowHelpers.ThrowIfNullOrEmpty(""));
    }

    [Fact]
    public void ThrowIfNullOrEmpty_Whitespace_DoesNotThrow()
    {
        ThrowHelpers.ThrowIfNullOrEmpty(" "); // whitespace is not empty
    }

    [Fact]
    public void ThrowIfNullOrEmpty_Valid_DoesNotThrow()
    {
        ThrowHelpers.ThrowIfNullOrEmpty("hello");
    }

    [Fact]
    public void ThrowIfNull_Null_ThrowsArgumentNullException()
    {
        Assert.Throws<ArgumentNullException>(() =>
            ThrowHelpers.ThrowIfNull((object?)null));
    }

    [Fact]
    public void ThrowIfNull_NonNull_DoesNotThrow()
    {
        ThrowHelpers.ThrowIfNull(new object());
    }

    [Fact]
    public void ThrowIfDisposed_IncludesTypeName()
    {
        var ex = Assert.Throws<ObjectDisposedException>(() =>
            ThrowHelpers.ThrowIfDisposed(true, this));
        Assert.Contains(nameof(ThrowHelperTests), ex.ObjectName);
    }

    [Fact]
    public void ThrowIfNullOrEmpty_IncludesParamName()
    {
        string? value = null;
        var ex = Assert.Throws<ArgumentException>(() =>
            ThrowHelpers.ThrowIfNullOrEmpty(value!));
        Assert.Equal("value", ex.ParamName);
    }

    [Fact]
    public void ThrowIfNull_IncludesParamName()
    {
        object? value = null;
        var ex = Assert.Throws<ArgumentNullException>(() =>
            ThrowHelpers.ThrowIfNull(value));
        Assert.Equal("value", ex.ParamName);
    }
}

// ===========================================================================
// IsExternalInit tests (init accessor polyfill for NS2.0)
// ===========================================================================

public class IsExternalInitTests
{
    [Fact]
    public void InitProperty_CanBeSetInObjectInitializer()
    {
        var opts = new PdfConverterOptions
        {
            ResourcePath = "/test/path",
            MaxWorkers = 4
        };
        Assert.Equal("/test/path", opts.ResourcePath);
        Assert.Equal(4, opts.MaxWorkers);
    }

    [Fact]
    public void InitProperty_DefaultValues_AreCorrect()
    {
        var opts = new PdfConverterOptions();
        Assert.Null(opts.ResourcePath);
        Assert.Equal(1, opts.MaxWorkers);
        Assert.Equal(TimeSpan.FromMinutes(5), opts.ConversionTimeout);
    }
}

// ===========================================================================
// OS Platform Detection tests (RuntimeInformation.IsOSPlatform)
// ===========================================================================

public class OsPlatformDetectionTests
{
    [Fact]
    public void IsCurrentPlatformDetected()
    {
        bool isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        bool isLinux = RuntimeInformation.IsOSPlatform(OSPlatform.Linux);
        bool isMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);

        // At least one must be true
        Assert.True(isWindows || isLinux || isMacOS,
            "At least one platform should be detected");
    }

    [Fact]
    public void PlatformDetection_ExactlyOneIsTrue()
    {
        bool isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        bool isLinux = RuntimeInformation.IsOSPlatform(OSPlatform.Linux);
        bool isMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);

        int count = (isWindows ? 1 : 0) + (isLinux ? 1 : 0) + (isMacOS ? 1 : 0);
        Assert.Equal(1, count);
    }
}
