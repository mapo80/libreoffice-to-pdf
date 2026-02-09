using System.Runtime.InteropServices;

namespace SlimLO.Native;

/// <summary>
/// P/Invoke declarations for the SlimLO native library.
/// Maps directly to the C API defined in slimlo.h.
/// </summary>
internal static partial class NativeMethods
{
    private const string LibraryName = "slimlo";

    static NativeMethods()
    {
        NativeLibrary.SetDllImportResolver(
            typeof(NativeMethods).Assembly,
            ResolveDllImport);
    }

    [LibraryImport(LibraryName, EntryPoint = "slimlo_init",
        StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr Init(string? resourcePath);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_destroy")]
    internal static partial void Destroy(IntPtr handle);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_convert_file",
        StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int ConvertFile(
        IntPtr handle,
        string inputPath,
        string outputPath,
        int formatHint,
        ref PdfOptionsNative options);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_convert_file",
        StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int ConvertFileNoOptions(
        IntPtr handle,
        string inputPath,
        string outputPath,
        int formatHint,
        IntPtr options); // NULL

    [LibraryImport(LibraryName, EntryPoint = "slimlo_convert_buffer")]
    internal static partial int ConvertBuffer(
        IntPtr handle,
        IntPtr inputData,
        nuint inputSize,
        int formatHint,
        ref PdfOptionsNative options,
        out IntPtr outputData,
        out nuint outputSize);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_convert_buffer")]
    internal static partial int ConvertBufferNoOptions(
        IntPtr handle,
        IntPtr inputData,
        nuint inputSize,
        int formatHint,
        IntPtr options, // NULL
        out IntPtr outputData,
        out nuint outputSize);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_free_buffer")]
    internal static partial void FreeBuffer(IntPtr buffer);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_get_error_message",
        StringMarshalling = StringMarshalling.Utf8)]
    internal static partial string? GetErrorMessage(IntPtr handle);

    [LibraryImport(LibraryName, EntryPoint = "slimlo_version",
        StringMarshalling = StringMarshalling.Utf8)]
    internal static partial string? GetVersion();

    /// <summary>
    /// Custom DLL import resolver for cross-platform native library loading.
    /// Searches for the library in platform-specific runtime directories.
    /// </summary>
    private static IntPtr ResolveDllImport(string libraryName,
        System.Reflection.Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != LibraryName)
            return IntPtr.Zero;

        // Try standard resolution first
        if (NativeLibrary.TryLoad(libraryName, assembly, searchPath, out var handle))
            return handle;

        // Try platform-specific paths relative to the assembly
        var assemblyDir = Path.GetDirectoryName(assembly.Location);
        if (assemblyDir == null)
            return IntPtr.Zero;

        // Determine platform-specific library name
        string libFileName;
        if (OperatingSystem.IsWindows())
            libFileName = "slimlo.dll";
        else if (OperatingSystem.IsMacOS())
            libFileName = "libslimlo.dylib";
        else
            libFileName = "libslimlo.so";

        // Try: runtimes/{rid}/native/
        var rid = RuntimeInformation.RuntimeIdentifier;
        var ridPath = Path.Combine(assemblyDir, "runtimes", rid, "native", libFileName);
        if (NativeLibrary.TryLoad(ridPath, out handle))
            return handle;

        // Try: native/ subdirectory
        var nativePath = Path.Combine(assemblyDir, "native", libFileName);
        if (NativeLibrary.TryLoad(nativePath, out handle))
            return handle;

        // Try: same directory as assembly
        var localPath = Path.Combine(assemblyDir, libFileName);
        if (NativeLibrary.TryLoad(localPath, out handle))
            return handle;

        return IntPtr.Zero;
    }
}

/// <summary>
/// Native struct layout matching SlimLOPdfOptions in slimlo.h.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct PdfOptionsNative
{
    public int PdfVersion;
    public int JpegQuality;
    public int Dpi;
    public int TaggedPdf;
    public IntPtr PageRange;   // UTF-8 string pointer
    public IntPtr Password;    // UTF-8 string pointer
}
