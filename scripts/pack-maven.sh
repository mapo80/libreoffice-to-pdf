#!/bin/bash
# pack-maven.sh — Build Maven packages from SlimLO build output
#
# Usage:
#   ./scripts/pack-maven.sh                          # API JAR only
#   ./scripts/pack-maven.sh linux output-linux-x64/  # API + native JAR
#
# Produces:
#   java/slimlo/target/slimlo-0.1.0.jar              # API JAR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JAVA_DIR="$ROOT_DIR/java"

if [ ! -f "$JAVA_DIR/pom.xml" ]; then
    echo "ERROR: $JAVA_DIR/pom.xml not found"
    exit 1
fi

echo "=== Building SlimLO Java SDK ==="
echo ""

# Build and test the API module
cd "$JAVA_DIR"
mvn clean package -pl slimlo -am

echo ""
echo "=== Package built ==="
ls -la "$JAVA_DIR/slimlo/target/"*.jar 2>/dev/null || echo "No JAR files found"

echo ""
echo "=== Maven coordinates ==="
echo "  <dependency>"
echo "    <groupId>com.slimlo</groupId>"
echo "    <artifactId>slimlo</artifactId>"
echo "    <version>0.1.0</version>"
echo "  </dependency>"
