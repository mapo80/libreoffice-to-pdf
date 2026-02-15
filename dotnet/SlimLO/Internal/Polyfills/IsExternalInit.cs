#if !NET5_0_OR_GREATER

// Polyfill for C# 9 init-only properties on .NET Standard 2.0 / .NET Framework.
// The compiler requires this type to exist for 'init' accessors.
// See https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-9.0/init

using System.ComponentModel;

namespace System.Runtime.CompilerServices
{
    [EditorBrowsable(EditorBrowsableState.Never)]
    internal static class IsExternalInit { }
}

#endif
