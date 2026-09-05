#!/bin/zsh
set -euo pipefail

# Builds the native, local-only transcription runtime that is shipped inside
# Zack.app. This is a developer build step; end users never run it.
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
source_dir="${project_dir}/Vendor/whisper.cpp"
build_dir="${source_dir}/build-macos"

if [[ ! -d "${source_dir}" ]]; then
    echo "Missing whisper.cpp source at ${source_dir}." >&2
    exit 1
fi

cmake -S "${source_dir}" -B "${build_dir}" \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=OFF
cmake --build "${build_dir}" --config Release --target whisper-cli --parallel 4

if [[ ! -f "${project_dir}/Resources/Whisper/ggml-small.en.bin" ]]; then
    echo "Missing Resources/Whisper/ggml-small.en.bin. Download the release model before packaging." >&2
    exit 1
fi
