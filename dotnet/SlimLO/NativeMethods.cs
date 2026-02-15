using System;
using System.IO;
using System.Runtime.InteropServices;

namespace SlimLO.Internal;

/// <summary>
/// Minimal P/Invoke declarations for the SlimLO native library.
/// Used only for version queries — all conversion goes through the worker process.
/// </summary>
internal static partial class NativeMethods
{
    private const string LibraryName = "slimlo";

#if NET8_0_OR_GREATER
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
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            libFileName = "slimlo.dll";
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            libFileName = "libslimlo.dylib";
        else
            libFileName = "libslimlo.so";

        var rid = RuntimeInformation.RuntimeIdentifier;
        string[] searchPaths = new[]
        {
            Path.Combine(assemblyDir, "runtimes", rid, "native", libFileName),
            Path.Combine(assemblyDir, "native", libFileName),
            Path.Combine(assemblyDir, libFileName),
            Path.Combine(assemblyDir, "program", libFileName),
        };

        foreach (var path in searchPaths)
        {
            if (NativeLibrary.TryLoad(path, out handle))
                return handle;
        }

        return IntPtr.Zero;
    }
#else
    // .NET Standard 2.0 / .NET Framework: classic DllImport without custom resolver.
    // The native library must be in the application output directory (NuGet .targets handles this)
    // or on the system PATH.
    [DllImport(LibraryName, EntryPoint = "slimlo_version",
        CharSet = CharSet.Ansi, CallingConvention = CallingConvention.Cdecl)]
    internal static extern string? GetVersion();
#endif
}
