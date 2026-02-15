#if !NET6_0_OR_GREATER

// Polyfill for [CallerArgumentExpression] on .NET Standard 2.0 / .NET Framework.
// The compiler uses this attribute to capture the expression passed to a parameter.

namespace System.Runtime.CompilerServices
{
    [AttributeUsage(AttributeTargets.Parameter, AllowMultiple = false, Inherited = false)]
    internal sealed class CallerArgumentExpressionAttribute : Attribute
    {
        public CallerArgumentExpressionAttribute(string parameterName)
        {
            ParameterName = parameterName;
        }

        public string ParameterName { get; }
    }
}

#endif
