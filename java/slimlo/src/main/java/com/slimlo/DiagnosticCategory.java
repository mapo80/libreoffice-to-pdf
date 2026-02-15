package com.slimlo;

/**
 * Category of a conversion diagnostic.
 */
public enum DiagnosticCategory {
    GENERAL,
    FONT,
    LAYOUT;

    public static DiagnosticCategory fromString(String s) {
        if (s == null) return GENERAL;
        switch (s.toLowerCase()) {
            case "font": return FONT;
            case "layout": return LAYOUT;
            default: return GENERAL;
        }
    }
}
