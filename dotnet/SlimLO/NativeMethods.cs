using System.Runtime.InteropServices;

namespace SlimLO.Internal;

/// <summary>
/// Minimal P/Invoke declarations for the SlimLO native library.
/// Used only for version queries — all conversion goes through the worker process.
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

    [LibraryImport(LibraryName, EntryPoint = "slimlo_version",
        StringMarshalling = StringMarshalling.Utf8)]
    internal static partial string? GetVersion();

    private static IntPtr ResolveDllImport(string libraryName,
        System.Reflection.Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != LibraryName)
            return IntPtr.Zero;

        if (NativeLibrary.TryLoad(libraryName, assembly, searchPath, out var handle))
            return handle;

        var assemblyDir = Path.GetDirectoryName(assembly.Location)
                          ?? AppContext.BaseDirectory;

        string libFileName;
        if (OperatingSystem.IsWindows())
            libFileName = "slimlo.dll";
        else if (OperatingSystem.IsMacOS())
            libFileName = "libslimlo.dylib";
        else
            libFileName = "libslimlo.so";

        var rid = RuntimeInformation.RuntimeIdentifier;
        string[] searchPaths =
        [
            Path.Combine(assemblyDir, "runtimes", rid, "native", libFileName),
            Path.Combine(assemblyDir, "native", libFileName),
            Path.Combine(assemblyDir, libFileName),
            Path.Combine(assemblyDir, "program", libFileName),
        ];

        foreach (var path in searchPaths)
        {
            if (NativeLibrary.TryLoad(path, out handle))
                return handle;
        }

        return IntPtr.Zero;
    }
}
