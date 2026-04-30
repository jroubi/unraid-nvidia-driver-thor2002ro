#!/bin/bash
#
# Run the NVIDIA driver build on Mac using Docker.
# Execute from the Unraid workspace root:
#   cd /Users/julien.charland/Documents/Code/Unraid
#   ./build/run-build.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
IMAGE_NAME="nvidia-thor-builder"

echo "=== Building Docker image (amd64 for x86_64 cross-compile) ==="
docker build --platform linux/amd64 -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

echo ""
echo "=== Creating output directory ==="
mkdir -p "${PROJECT_DIR}/output"

echo ""
echo "=== Running build inside Docker ==="
docker run --rm \
    --platform linux/amd64 \
    -v "${PROJECT_DIR}/output:/output" \
    -v "${PROJECT_DIR}/config.gz:/build/config.gz:ro" \
    -v "${SCRIPT_DIR}/build.sh:/build/build.sh:ro" \
    -v "${SCRIPT_DIR}/kernel-7.0.patch:/build/kernel-7.0.patch:ro" \
    "${IMAGE_NAME}" \
    bash /build/build.sh

echo ""
echo "=== Build finished ==="
echo "Output files:"
ls -lh "${PROJECT_DIR}/output/"
