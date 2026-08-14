#!/usr/bin/env bash
# Build Kafka release tar.gz in a given workdir.
# Optionally install to local Maven repo and scan with Trivy.
set -euo pipefail

WORKDIR="."
DO_INSTALL=1
DO_TRIVY=1
OUTPUT_DIR=""
GRADLE="${GRADLE:-./gradlew}"
TRIVY_SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
TRIVY_EXIT_CODE="${TRIVY_EXIT_CODE:-1}"
TRIVY_REPORT="${TRIVY_REPORT:-trivy-kafka-dist.json}"

usage() {
  cat <<'EOF'
Usage: build-release-archive.sh [options]

Options:
  --workdir DIR       Build directory (default: .)
  --output-dir DIR    Copy release tarball and Trivy report here
  --skip-install      Skip publish/install to local Maven repository
  --skip-trivy        Skip Trivy scan
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --skip-install)
      DO_INSTALL=0
      shift
      ;;
    --skip-trivy)
      DO_TRIVY=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

WORKDIR="$(cd "$WORKDIR" && pwd)"
cd "$WORKDIR"

if [[ ! -x "$GRADLE" && "$GRADLE" == "./gradlew" ]]; then
  echo "error: ./gradlew not found or not executable in ${WORKDIR}" >&2
  exit 1
fi

if [[ "$DO_INSTALL" -eq 1 ]]; then
  echo "==> [${WORKDIR}] Installing artifacts to local Maven repository (~/.m2)..."
  "$GRADLE" -PskipSigning=true install -x test
fi

echo "==> [${WORKDIR}] Building release tar.gz..."
"$GRADLE" releaseTarGz -x test

VERSION="$(grep -E '^version=' gradle.properties | cut -d= -f2)"
SCALA_BASE="$(grep -E '^scalaVersion=' gradle.properties | cut -d= -f2 | cut -d. -f1-2)"
DIST_DIR="core/build/distributions"
TARBALL="${DIST_DIR}/kafka_${SCALA_BASE}-${VERSION}.tgz"

if [[ ! -f "$TARBALL" ]]; then
  echo "error: release archive not found: ${WORKDIR}/${TARBALL}" >&2
  exit 1
fi

scan_status=0
if [[ "$DO_TRIVY" -eq 1 ]]; then
  if ! command -v trivy >/dev/null 2>&1; then
    echo "error: trivy is not installed or not on PATH" >&2
    exit 1
  fi

  SCAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kafka-trivy.XXXXXX")"
  cleanup() {
    rm -rf "$SCAN_DIR"
  }
  trap cleanup EXIT

  echo "==> [${WORKDIR}] Extracting ${TARBALL} for Trivy scan..."
  tar -xzf "$TARBALL" -C "$SCAN_DIR"

  echo "==> [${WORKDIR}] Scanning release archive with Trivy (severity=${TRIVY_SEVERITY})..."
  trivy fs \
    --no-progress \
    --scanners vuln \
    --severity "$TRIVY_SEVERITY" \
    --exit-code "$TRIVY_EXIT_CODE" \
    --format json \
    --output "$TRIVY_REPORT" \
    "$SCAN_DIR" || scan_status=$?

  trivy fs \
    --no-progress \
    --scanners vuln \
    --severity "$TRIVY_SEVERITY" \
    --format table \
    "$SCAN_DIR"

  trap - EXIT
  cleanup
fi

if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  cp -f "$TARBALL" "$OUTPUT_DIR/"
  if [[ "$DO_TRIVY" -eq 1 && -f "$TRIVY_REPORT" ]]; then
    cp -f "$TRIVY_REPORT" "$OUTPUT_DIR/trivy-kafka-${VERSION}.json"
  fi
fi

echo
echo "Done (${VERSION})."
echo "  Workdir     : ${WORKDIR}"
if [[ "$DO_INSTALL" -eq 1 ]]; then
  echo "  Maven local : ${HOME}/.m2/repository/org/apache/kafka"
fi
echo "  Release tgz : ${WORKDIR}/${TARBALL}"
if [[ "$DO_TRIVY" -eq 1 ]]; then
  echo "  Trivy report: ${WORKDIR}/${TRIVY_REPORT}"
fi
if [[ -n "$OUTPUT_DIR" ]]; then
  echo "  Output dir  : ${OUTPUT_DIR}"
fi

exit "$scan_status"
