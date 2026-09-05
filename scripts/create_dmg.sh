#!/bin/zsh
set -euo pipefail

# Produces a Finder-ready installer: Zack.app, an Applications shortcut, and a
# branded background with fixed icon placement. Run build_app.sh first.
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
output_dir="${project_dir}/dist"
app_path="${output_dir}/Zack.app"
dmg_path="${output_dir}/Zack-0.1.0.dmg"
background_path="${project_dir}/Resources/Branding/ZackDMGBackground.png"
staging_path="${output_dir}/dmg-staging"
rw_dmg_path="${output_dir}/Zack-rw.dmg"
volume_name="Zack"

if [[ ! -d "${app_path}" ]]; then
    echo "Missing ${app_path}. Run scripts/build_app.sh first." >&2
    exit 1
fi
if [[ ! -f "${background_path}" ]]; then
    echo "Missing ${background_path}." >&2
    exit 1
fi

rm -rf "${staging_path}"
rm -f "${dmg_path}" "${rw_dmg_path}"
mkdir -p "${staging_path}/.background"
cp -R "${app_path}" "${staging_path}/Zack.app"
ln -s /Applications "${staging_path}/Applications"
cp "${background_path}" "${staging_path}/.background/background.png"

hdiutil create -volname "${volume_name}" -srcfolder "${staging_path}" -ov -format UDRW "${rw_dmg_path}" >/dev/null
device="$(hdiutil attach -readwrite -noverify -noautoopen "${rw_dmg_path}" | awk '/\/Volumes\// { print $1; exit }')"
if [[ -z "${device}" ]]; then
    echo "Could not mount the temporary DMG." >&2
    exit 1
fi

osascript - "${volume_name}" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {100, 100, 860, 575}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 14
            set background picture of viewOptions to file ".background:background.png"
            set position of item "Zack.app" of container window to {180, 245}
            set position of item "Applications" of container window to {580, 245}
            update without registering applications
            close
        end tell
    end tell
end run
APPLESCRIPT

sync
hdiutil detach "${device}" >/dev/null
hdiutil convert "${rw_dmg_path}" -format UDZO -imagekey zlib-level=9 -o "${dmg_path}" -ov >/dev/null
rm -f "${rw_dmg_path}"
rm -rf "${staging_path}"
echo "Built ${dmg_path}"
