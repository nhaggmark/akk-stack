## ── Stage 1: build llama-cpp-python with CUDA ──────────────────────
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.11 python3.11-dev python3.11-venv python3-pip \
        build-essential cmake curl ninja-build && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY requirements.txt .

# Install CPU-only PyTorch FIRST so that sentence-transformers (pulled in
# via requirements.txt) does not trigger a CUDA PyTorch download.
# llama-cpp-python handles all GPU acceleration independently via GGML/CUDA;
# the embedding model (all-MiniLM-L6-v2) runs on CPU and does not need CUDA torch.
RUN python3.11 -m pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

# Build llama-cpp-python with CUDA support
# The stubs provide libcuda.so; the linker also needs libcuda.so.1
RUN ln -s /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
ENV CMAKE_ARGS="-DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=86"
ENV FORCE_CMAKE=1
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH}
RUN python3.11 -m pip install --no-cache-dir -r requirements.txt

## ── Stage 2: runtime (no stubs, no build tools) ───────────────────
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.11 curl libgomp1 && \
    rm -rf /var/lib/apt/lists/*

# Copy installed Python packages from builder (dist-packages is where pip installs)
COPY --from=builder /usr/local/lib/python3.11/dist-packages /usr/local/lib/python3.11/dist-packages
COPY --from=builder /usr/local/bin/uvicorn /usr/local/bin/uvicorn

WORKDIR /app
COPY app/ ./app/
COPY config/ ./config/

# Create data directory for ChromaDB persistent storage
RUN mkdir -p /data/chromadb

# Ensure the real NVIDIA driver libs are found at runtime (not build stubs)
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

EXPOSE 8100

CMD ["python3.11", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8100"]
