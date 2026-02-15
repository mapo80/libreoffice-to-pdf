package com.slimlo.internal;

import java.io.File;
import java.io.FileNotFoundException;
import java.net.URISyntaxException;
import java.net.URL;
import java.security.CodeSource;
import java.security.ProtectionDomain;

/**
 * Locates the slimlo_worker executable and resource directory at runtime.
 */
public final class WorkerLocator {

    private WorkerLocator() {}

    /**
     * Find the slimlo_worker executable.
     *
     * @return Absolute path to the worker executable.
     * @throws FileNotFoundException if the worker cannot be found.
     */
    public static String findWorkerExecutable() throws FileNotFoundException {
        String workerName = isWindows() ? "slimlo_worker.exe" : "slimlo_worker";
        String assemblyDir = getAssemblyDirectory();

        String[] searchPaths = {
                // Same directory as JAR
                new File(assemblyDir, workerName).getAbsolutePath(),
                // native/ subdirectory
                new File(new File(assemblyDir, "native"), workerName).getAbsolutePath(),
                // program/ subdirectory
                new File(new File(assemblyDir, "program"), workerName).getAbsolutePath(),
        };

        for (String path : searchPaths) {
            File f = new File(path);
            if (f.isFile() && f.canExecute()) {
                return f.getAbsolutePath();
            }
        }

        // Check SLIMLO_WORKER_PATH environment variable
        String envWorkerPath = System.getenv("SLIMLO_WORKER_PATH");
        if (envWorkerPath != null && !envWorkerPath.isEmpty()) {
            File f = new File(envWorkerPath);
            if (f.isFile()) {
                return f.getAbsolutePath();
            }
        }

        // Check inside SLIMLO_RESOURCE_PATH/program/
        String envResourcePath = System.getenv("SLIMLO_RESOURCE_PATH");
        if (envResourcePath != null && !envResourcePath.isEmpty()) {
            File f = new File(new File(envResourcePath, "program"), workerName);
            if (f.isFile()) {
                return f.getAbsolutePath();
            }
        }

        StringBuilder searched = new StringBuilder();
        for (String path : searchPaths) {
            if (searched.length() > 0) searched.append(", ");
            searched.append(path);
        }

        throw new FileNotFoundException(
                "Cannot find slimlo_worker executable. Searched: " + searched +
                ". Set SLIMLO_WORKER_PATH or SLIMLO_RESOURCE_PATH environment variable, " +
                "or ensure the native assets are in the expected location.");
    }

    /**
     * Find the SlimLO resource directory (containing program/, share/).
     *
     * @return Absolute path to the resource directory.
     * @throws IllegalStateException if the resource path cannot be found.
     */
    public static String findResourcePath() {
        String assemblyDir = getAssemblyDirectory();

        String[] candidates = {
                // Same directory as JAR
                assemblyDir,
                // slimlo-resources/ subdirectory
                new File(assemblyDir, "slimlo-resources").getAbsolutePath(),
                // Parent directory
                new File(assemblyDir, "..").getAbsolutePath(),
                // Parent's slimlo-resources
                new File(new File(assemblyDir, ".."), "slimlo-resources").getAbsolutePath(),
        };

        for (String candidate : candidates) {
            File programDir = new File(candidate, "program");
            if (programDir.isDirectory() && hasMergedLibrary(programDir)) {
                try {
                    return new File(candidate).getCanonicalPath();
                } catch (Exception e) {
                    return new File(candidate).getAbsolutePath();
                }
            }
        }

        // Check SLIMLO_RESOURCE_PATH environment variable
        String envPath = System.getenv("SLIMLO_RESOURCE_PATH");
        if (envPath != null && !envPath.isEmpty()) {
            File programDir = new File(envPath, "program");
            if (programDir.isDirectory()) {
                return new File(envPath).getAbsolutePath();
            }
        }

        throw new IllegalStateException(
                "Cannot auto-detect SlimLO resource path. " +
                "Set SLIMLO_RESOURCE_PATH environment variable or pass resourcePath " +
                "in PdfConverterOptions.");
    }

    private static boolean hasMergedLibrary(File programDir) {
        return new File(programDir, "libmergedlo.so").exists()
                || new File(programDir, "libmergedlo.dylib").exists()
                || new File(programDir, "mergedlo.dll").exists()
                || new File(programDir, "sofficerc").exists();
    }

    /**
     * Get the directory containing this JAR/class file.
     */
    static String getAssemblyDirectory() {
        try {
            ProtectionDomain pd = WorkerLocator.class.getProtectionDomain();
            if (pd != null) {
                CodeSource cs = pd.getCodeSource();
                if (cs != null) {
                    URL location = cs.getLocation();
                    if (location != null) {
                        File file = new File(location.toURI());
                        // If this is a JAR, return its parent directory
                        if (file.isFile()) {
                            return file.getParentFile().getAbsolutePath();
                        }
                        // If this is a directory (running from classes/)
                        return file.getAbsolutePath();
                    }
                }
            }
        } catch (URISyntaxException e) {
            // Fall through
        }

        // Fallback: current working directory
        return System.getProperty("user.dir", ".");
    }

    static boolean isWindows() {
        String os = System.getProperty("os.name", "").toLowerCase();
        return os.contains("win");
    }

    static boolean isMacOS() {
        String os = System.getProperty("os.name", "").toLowerCase();
        return os.contains("mac") || os.contains("darwin");
    }

    static boolean isLinux() {
        String os = System.getProperty("os.name", "").toLowerCase();
        return os.contains("linux");
    }
}
