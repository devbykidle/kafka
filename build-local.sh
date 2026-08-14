#!/usr/bin/env bash
# Install Kafka artifacts to the local Maven repository (~/.m2),
# build the release tar.gz distribution, and scan it with Trivy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

GRADLE="${GRADLE:-./gradlew}"
TRIVY_SEVERITY="HIGH,CRITICAL"
TRIVY_EXIT_CODE="1"
TRIVY_REPORT="${TRIVY_REPORT:-trivy-kafka-dist.json}"
TRIVY_IMAGE_REPORT="${TRIVY_IMAGE_REPORT:-trivy-kafka-image.json}"

if [[ ! -x "$GRADLE" && "$GRADLE" == "./gradlew" ]]; then
  echo "error: ./gradlew not found or not executable" >&2
  exit 1
fi

if ! command -v trivy >/dev/null 2>&1; then
  echo "error: trivy is not installed or not on PATH" >&2
  exit 1
fi

echo "==> Installing artifacts to local Maven repository (~/.m2)..."
"$GRADLE" -PskipSigning=true install -x test

echo "==> Building release tar.gz..."
"$GRADLE" releaseTarGz -x test

VERSION="$(grep -E '^version=' gradle.properties | cut -d= -f2)"
SCALA_BASE="$(grep -E '^scalaVersion=' gradle.properties | cut -d= -f2 | cut -d. -f1-2)"
DIST_DIR="core/build/distributions"
TARBALL="${DIST_DIR}/kafka_${SCALA_BASE}-${VERSION}.tgz"
KAFKA_DIST_DIR_NAME="kafka_${SCALA_BASE}-${VERSION}"

if [[ ! -f "$TARBALL" ]]; then
  echo "error: release archive not found: ${TARBALL}" >&2
  exit 1
fi

SCAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kafka-trivy.XXXXXX")"
cleanup() {
  rm -rf "$SCAN_DIR"
}
trap cleanup EXIT

echo "==> Extracting ${TARBALL} for Trivy scan..."
tar -xzf "$TARBALL" -C "$SCAN_DIR"

echo "==> Scanning release archive with Trivy (severity=${TRIVY_SEVERITY})..."
scan_status=0
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

echo
echo "==> Scanning Docker image with Trivy (severity=${TRIVY_SEVERITY})..."
if ! command -v docker >/dev/null 2>&1; then
  echo "warn: docker not found; skipping trivy image scan." >&2
else
  DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-kafka-trivy:${VERSION}-${SCALA_BASE}}"
  DOCKERFILE_PATH="${SCAN_DIR}/Dockerfile.trivy"
  KAFKA_EXTRACT_DIR="${SCAN_DIR}/${KAFKA_DIST_DIR_NAME}"

  if [[ ! -d "$KAFKA_EXTRACT_DIR" ]]; then
    echo "error: expected extracted kafka dir not found: ${KAFKA_EXTRACT_DIR}" >&2
    exit 1
  fi

  cat > "$DOCKERFILE_PATH" <<EOF
FROM eclipse-temurin:17-jre
RUN mkdir -p /opt/kafka
COPY ${KAFKA_DIST_DIR_NAME}/ /opt/kafka/
ENV KAFKA_HOME=/opt/kafka
WORKDIR /opt/kafka
EOF

  docker build -f "$DOCKERFILE_PATH" -t "$DOCKER_IMAGE_TAG" "$SCAN_DIR"

  trivy image \
    --no-progress \
    --scanners vuln \
    --severity "$TRIVY_SEVERITY" \
    --exit-code "$TRIVY_EXIT_CODE" \
    --format json \
    --output "$TRIVY_IMAGE_REPORT" \
    "$DOCKER_IMAGE_TAG" || scan_status=$?

  trivy image \
    --no-progress \
    --scanners vuln \
    --severity "$TRIVY_SEVERITY" \
    --format table \
    "$DOCKER_IMAGE_TAG"
fi

echo
echo "Done."
echo "  Maven local : ${HOME}/.m2/repository/org/apache/kafka"
echo "  Release tgz : ${TARBALL}"
echo "  Trivy report: ${TRIVY_REPORT}"
echo "  Trivy image report: ${TRIVY_IMAGE_REPORT}"

exit "$scan_status"
