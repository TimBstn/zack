# Install Zack

Zack is distributed as a macOS DMG through GitHub Releases. It does not
require the Mac App Store, Python, Conda, or any separate transcription setup.

## Install

1. Download the latest `Zack-<version>.dmg` from GitHub Releases.
2. Double-click the downloaded DMG to open it.
3. Drag `Zack.app` to your Applications folder.
4. Open Zack from Applications.

The first launch may prompt you to confirm that you want to open the app. This
is normal for software downloaded outside the Mac App Store.

## First project

Choose **Import videos** or drag MP4, MOV, or M4V files into Zack. Select a
clip to trim it, drag whole clip tiles to change their order, and switch to
**Full Video** to preview the complete timeline.

## Subtitles

The captions button generates subtitles locally for the full video. Zack
includes the transcription engine and English language model, so no account or
additional install is needed. Generated SRT files are saved in:

```text
~/Movies/Zack Subtitles
```

Use the inline subtitle panel to edit captions while watching the full-video
preview.

## Update

Download the newest DMG from GitHub Releases, replace the existing `Zack.app`
in Applications with the new version, then reopen it. Your `.zack` projects
and original video files remain untouched.

## Privacy

Video editing and subtitle transcription run locally on your Mac. Zack does
not upload video, audio, projects, or subtitle text.
