#!/bin/zsh
set -euo pipefail

# Produces a self-contained macOS app bundle for local testing and release
# packaging. Code signing is optional for developer builds.
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
output_dir="${project_dir}/dist"
app_path="${output_dir}/Zack.app"
whisper_bin_dir="${project_dir}/Vendor/whisper.cpp/build-macos/bin"

bin_path="$(cd "${project_dir}" && swift build -c release >&2 && swift build -c release --show-bin-path)"
if [[ ! -x "${whisper_bin_dir}/whisper-cli" ]]; then
    "${script_dir}/build_whisper_runtime.sh"
fi
rm -rf "${app_path}"
mkdir -p "${app_path}/Contents/MacOS" "${app_path}/Contents/Frameworks" "${app_path}/Contents/Resources/Whisper" "${app_path}/Contents/Resources/Fonts"
cp "${bin_path}/Zack" "${app_path}/Contents/MacOS/Zack"
cp "${project_dir}/Resources/Info.plist" "${app_path}/Contents/Info.plist"
cp "${project_dir}/Resources/Branding/Zack.icns" "${app_path}/Contents/Resources/Zack.icns"
cp -R "${project_dir}/Resources/Fonts/." "${app_path}/Contents/Resources/Fonts/"
cp "${whisper_bin_dir}/whisper-cli" "${app_path}/Contents/MacOS/whisper-cli"
for library in libwhisper.1.dylib libggml.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-base.0.dylib; do
    cp -L "${whisper_bin_dir}/${library}" "${app_path}/Contents/Frameworks/${library}"
done
cp "${project_dir}/Resources/Whisper/ggml-small.en.bin" "${app_path}/Contents/Resources/Whisper/"
cp "${project_dir}/Resources/Whisper/ggml-silero-v6.2.0.bin" "${app_path}/Contents/Resources/Whisper/"
cp "${project_dir}/Resources/THIRD_PARTY_NOTICES.md" "${app_path}/Contents/Resources/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${app_path}/Contents/MacOS/whisper-cli"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    find "${app_path}/Contents/Frameworks" -type f -name "*.dylib" -exec codesign --force --options runtime --sign "${CODE_SIGN_IDENTITY}" {} \;
    codesign --force --options runtime --sign "${CODE_SIGN_IDENTITY}" "${app_path}/Contents/MacOS/whisper-cli"
    codesign --force --options runtime --sign "${CODE_SIGN_IDENTITY}" "${app_path}"
fi

echo "Built ${app_path}"
