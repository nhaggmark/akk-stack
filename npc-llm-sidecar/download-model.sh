#!/bin/bash
# Download Mistral 7B Instruct v0.3 Q4_K_M GGUF model for NPC LLM sidecar
# Source: https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF
# Size: ~4.37 GB

set -e

MODELS_DIR="$(cd "$(dirname "$0")" && pwd)/models"
MODEL_FILE="Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/bartowski/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/${MODEL_FILE}"

echo "=== NPC LLM Sidecar — Model Download ==="
echo "Model:       ${MODEL_FILE}"
echo "Size:        ~4.37 GB"
echo "Destination: ${MODELS_DIR}/${MODEL_FILE}"
echo ""

# Check if already downloaded
if [ -f "${MODELS_DIR}/${MODEL_FILE}" ]; then
    EXISTING_SIZE=$(stat -c%s "${MODELS_DIR}/${MODEL_FILE}" 2>/dev/null || stat -f%z "${MODELS_DIR}/${MODEL_FILE}" 2>/dev/null)
    echo "Model file already exists (${EXISTING_SIZE} bytes)."
    echo "To re-download, delete it first: rm ${MODELS_DIR}/${MODEL_FILE}"
    exit 0
fi

mkdir -p "${MODELS_DIR}"

echo "Downloading from HuggingFace..."
echo ""

# Download with progress bar and resume support
curl -L \
    --progress-bar \
    --continue-at - \
    --output "${MODELS_DIR}/${MODEL_FILE}" \
    "${MODEL_URL}"

echo ""
echo "Download complete!"
FINAL_SIZE=$(stat -c%s "${MODELS_DIR}/${MODEL_FILE}" 2>/dev/null || stat -f%z "${MODELS_DIR}/${MODEL_FILE}" 2>/dev/null)
echo "File size: ${FINAL_SIZE} bytes"
echo ""
echo "Next steps:"
echo "  1. Start the sidecar:  cd $(dirname "$0")/.. && make up-llm"
echo "  2. Reload quests:      #reloadquest (in-game)"
echo "  3. Talk to any NPC:    target a guard and /say Hello"
