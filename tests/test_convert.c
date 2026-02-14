/*
 * test_convert.c — SlimLO PDF conversion test
 *
 * Tests basic docx→PDF conversion via libslimlo.so.
 * Validates that the output is a valid PDF (checks magic bytes).
 *
 * Build:
 *   gcc -o test_convert test_convert.c -I/opt/slimlo/include \
 *       -L/opt/slimlo/program -lslimlo -Wl,-rpath,/opt/slimlo/program
 *
 * Run:
 *   ./test_convert /path/to/test.docx /tmp/output.pdf
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "slimlo.h"

static int check_pdf_magic(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "FAIL: Cannot open output file: %s\n", path);
        return 0;
    }
    char magic[5] = {0};
    size_t n = fread(magic, 1, 4, f);
    fclose(f);

    if (n < 4 || memcmp(magic, "%PDF", 4) != 0) {
        fprintf(stderr, "FAIL: Output is not a valid PDF (magic: '%.*s')\n", (int)n, magic);
        return 0;
    }
    return 1;
}

static long file_size(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    return sz;
}

int main(int argc, char** argv) {
    const char* resource_path = "/opt/slimlo";
    const char* input_path = NULL;
    const char* output_path = NULL;

    if (argc < 3) {
        fprintf(stderr, "Usage: %s <input.docx> <output.pdf> [resource_path]\n", argv[0]);
        return 1;
    }
    input_path = argv[1];
    output_path = argv[2];
    if (argc > 3) {
        resource_path = argv[3];
    }

    printf("=== SlimLO Conversion Test ===\n");
    printf("Version:  %s\n", slimlo_version());
    printf("Resource: %s\n", resource_path);
    printf("Input:    %s (%ld bytes)\n", input_path, file_size(input_path));
    printf("Output:   %s\n", output_path);
    printf("\n");

    /* Initialize */
    printf("[1/3] Initializing SlimLO...\n");
    SlimLOHandle handle = slimlo_init(resource_path);
    if (!handle) {
        fprintf(stderr, "FAIL: slimlo_init failed: %s\n",
                slimlo_get_error_message(NULL));
        return 1;
    }
    printf("  OK\n\n");

    /* Convert */
    printf("[2/3] Converting docx -> PDF...\n");
    SlimLOError err = slimlo_convert_file(
        handle, input_path, output_path,
        SLIMLO_FORMAT_DOCX, NULL
    );
    if (err != SLIMLO_OK) {
        fprintf(stderr, "FAIL: slimlo_convert_file returned %d: %s\n",
                err, slimlo_get_error_message(handle));
        slimlo_destroy(handle);
        return 1;
    }
    printf("  OK\n\n");

    /* Validate unsupported format guards */
    printf("[3/4] Verifying unsupported formats are rejected...\n");
    err = slimlo_convert_file(
        handle, input_path, output_path,
        SLIMLO_FORMAT_XLSX, NULL
    );
    if (err != SLIMLO_ERROR_INVALID_FORMAT) {
        fprintf(stderr, "FAIL: expected INVALID_FORMAT for XLSX hint, got %d (%s)\n",
                err, slimlo_get_error_message(handle));
        slimlo_destroy(handle);
        return 1;
    }

    err = slimlo_convert_file(
        handle, input_path, output_path,
        SLIMLO_FORMAT_PPTX, NULL
    );
    if (err != SLIMLO_ERROR_INVALID_FORMAT) {
        fprintf(stderr, "FAIL: expected INVALID_FORMAT for PPTX hint, got %d (%s)\n",
                err, slimlo_get_error_message(handle));
        slimlo_destroy(handle);
        return 1;
    }
    printf("  OK\n\n");

    /* Validate output */
    printf("[4/4] Validating PDF output...\n");
    long sz = file_size(output_path);
    if (sz <= 0) {
        fprintf(stderr, "FAIL: Output file is empty or missing\n");
        slimlo_destroy(handle);
        return 1;
    }
    printf("  Output size: %ld bytes\n", sz);

    if (!check_pdf_magic(output_path)) {
        slimlo_destroy(handle);
        return 1;
    }
    printf("  PDF magic: OK\n\n");

    /* Cleanup */
    slimlo_destroy(handle);

    printf("=== ALL TESTS PASSED ===\n");
    return 0;
}
