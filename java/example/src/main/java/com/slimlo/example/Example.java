package com.slimlo.example;

import com.slimlo.ConversionDiagnostic;
import com.slimlo.ConversionResult;
import com.slimlo.PdfConverter;

import java.io.File;

public class Example {

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("Usage: Example <input.docx> [output.pdf]");
            System.exit(1);
        }

        String input = args[0];
        String output = args.length > 1 ? args[1]
                : input.replaceAll("\\.[^.]+$", ".pdf");

        System.out.println("Converting: " + input + " -> " + output);

        try (PdfConverter converter = PdfConverter.create()) {
            ConversionResult result = converter.convert(input, output);

            if (result.isSuccess()) {
                long size = new File(output).length();
                System.out.println("OK — " + String.format("%,d", size) + " bytes");

                if (result.hasFontWarnings()) {
                    System.out.println("Font warnings:");
                    for (ConversionDiagnostic d : result.getDiagnostics()) {
                        System.out.println("  " + d.getSeverity() + ": " + d.getMessage());
                    }
                }
            } else {
                System.err.println("FAILED: " + result.getErrorMessage());
                System.exit(1);
            }
        }
    }
}
