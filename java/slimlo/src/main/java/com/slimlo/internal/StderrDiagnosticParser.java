package com.slimlo.internal;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.slimlo.ConversionDiagnostic;
import com.slimlo.DiagnosticCategory;
import com.slimlo.DiagnosticSeverity;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Parses diagnostic entries from the worker's JSON response.
 */
public final class StderrDiagnosticParser {

    private StderrDiagnosticParser() {}

    /**
     * Parse a JSON array of diagnostics into a list of ConversionDiagnostic.
     */
    public static List<ConversionDiagnostic> parseFromJson(JsonArray array) {
        if (array == null || array.size() == 0) {
            return Collections.emptyList();
        }

        List<ConversionDiagnostic> result = new ArrayList<ConversionDiagnostic>();
        for (JsonElement element : array) {
            if (!element.isJsonObject()) continue;
            JsonObject obj = element.getAsJsonObject();

            DiagnosticSeverity severity = DiagnosticSeverity.fromString(
                    getStringOrNull(obj, "severity"));
            DiagnosticCategory category = DiagnosticCategory.fromString(
                    getStringOrNull(obj, "category"));
            String message = getStringOrNull(obj, "message");
            String fontName = getStringOrNull(obj, "font");
            String substitutedWith = getStringOrNull(obj, "substituted_with");

            if (message == null) {
                message = "";
            }

            result.add(new ConversionDiagnostic(
                    severity, category, message, fontName, substitutedWith));
        }

        return result;
    }

    private static String getStringOrNull(JsonObject obj, String key) {
        if (obj.has(key) && !obj.get(key).isJsonNull()) {
            return obj.get(key).getAsString();
        }
        return null;
    }
}
