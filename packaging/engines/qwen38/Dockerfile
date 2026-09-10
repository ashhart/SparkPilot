FROM vllm/vllm-openai@sha256:3b0e188ffceb3d07e09c3cb5215433a0020eacf02d7f882ed3a8bfd15454477e
LABEL org.opencontainers.image.title="SparkPilot Qwen3.8 Flash Next qualification candidate" \
      org.opencontainers.image.source="https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark" \
      org.opencontainers.image.revision="78b0675e4469a19befaa9c84a41662b671d4185e" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"
COPY LICENSE files/ /opt/sparkpilot-qwen38/files/
COPY apply_patches.py bounded_ple_cache.py weight_page_cache.py /opt/sparkpilot-qwen38/
RUN --network=none python3 /opt/sparkpilot-qwen38/apply_patches.py
COPY security-deps/ /tmp/sparkpilot-security-deps/
RUN --network=none dpkg -i /tmp/sparkpilot-security-deps/*.deb \
    && python3 -m pip uninstall --yes pip \
    && rm -rf /tmp/sparkpilot-security-deps \
    && python3 -c "import importlib.util; assert importlib.util.find_spec('pip') is None"
