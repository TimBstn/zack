# Zack

Zack is a slim, native video editor for macOS. It is for people who want to
quickly arrange clips, make clean trims, add editable subtitles, and export a
finished video—without learning a complicated editing suite.

Everything stays on your Mac. Zack edits non-destructively, so your original
video files are never changed.

## Get started

Download the latest Zack DMG from this project’s GitHub Releases page. Open
the DMG, drag **Zack** to your Applications folder, then open it like any
other Mac app. See the [installation guide](docs/DISTRIBUTION.md) for details.

### Requirements

- macOS 14 or later
- Apple silicon Mac
- MP4, MOV, or M4V source videos

## Make a video

1. Open Zack and click **Import videos**, or drag video files into the
   window.
2. Click a clip in the timeline to select it.
3. Drag a clip tile left or right to arrange the order of your video.
4. In **Selected** preview, drag the orange cutters beneath the player to set
   that clip’s start and end.
5. Switch to **Full Video** to watch the finished timeline.
6. Click the orange Export button to save the combined video as an MP4.

You can copy a selected clip with Command-C and paste it with Command-V. This
is useful for repeating a short moment or creating a transition.

## Adjust audio

Select a clip and click the speaker button in the toolbar to open **Audio**.
Each clip has its own volume slider: **100%** keeps the recording’s original
level, while 0% mutes it and values above 100% boost it. Zack measures the
actual output peak of the trimmed clip after gain, so a quiet recording and a
loud recording do not read the same at 100%. Keep the meter below the -1 dB
safe ceiling; yellow and red can distort footage that was already loud. Audio
levels are saved in the project and applied to the exported MP4.

## Fade video clips

Select a video clip to open its **Video** sidebar. Open **Transition** and set
Fade in or Fade out in seconds. Fades are rendered in the full-video preview
and exported MP4.

## Add music

Open the Music row below the video timeline and use its **+** button to import
an audio file. Music appears in its own lane beneath the video timeline. Drag
a music block left or right to set where it starts; Zack keeps the whole block
inside the finished video so it never visually changes length while moving.
Drag either orange cutter directly for live trimming. Select a block to set its independent volume, song
offset, and fades in the Music panel. Zack mixes music beneath your video audio in preview
and export, stopping it when the video ends.

The Music panel also offers optional fade-in and fade-out durations, up to 12
seconds each, for smoother starts and endings. Use **Song offset** to begin at
a later point inside the music file without moving its block on the timeline.

Music tiles support the same editing shortcuts as video clips: Command-C,
Command-V, Command-D, and Delete.

## Choose an output

Choose **Zack → Settings → Video** before exporting:

- **YouTube Video** — 1920 × 1080 (16:9) for normal, horizontal YouTube videos.
- **Shorts & Reels** — 1080 × 1920 (9:16) for YouTube Shorts and Instagram Reels.

The selected output changes both the preview and exported MP4. Zack keeps each
clip’s original aspect ratio; footage that does not fill the selected frame is
shown with black bars rather than stretched.

## Add subtitles

Click the captions button in the toolbar to generate subtitles for the complete
timeline. Zack includes its own local transcription engine, English model, and
voice activity detection, so there is no Python, Conda, account, or separate
download to configure. Background music is excluded from the transcription
source so it cannot interfere with speech detection.

Choose **Zack → Settings → Subtitles** to set the maximum number of
characters in each generated caption (spaces and punctuation count), and choose
whether caption breaks should keep words together. These preferences apply the
next time you generate subtitles.

The generated SRT file is saved in `~/Movies/Zack Subtitles`. Zack opens
the subtitle editor beside the video, where you can edit each caption and its
start and end time while watching the **Full Video** preview. Enter times as
`0:03.00`, `1:02.50`, or plain seconds; they apply when you press Return or
leave the field. Subtitle text, timing, and edits are also saved in your
project.

## Save your work

Choose **File → Save Project** to create a `.zack` project. A project stores
your clip order, trim ranges, audio levels, output format, and subtitles while continuing to reference the
original video files on your Mac. Zack asks before closing a project with
unsaved changes.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Command-I | Import videos |
| Command-O | Open a project |
| Command-S | Save the project |
| Command-E | Export the full video |
| Command-C / Command-V | Copy / paste the selected clip |
| Command-D | Duplicate the selected clip |
| Delete | Remove the selected clip |
| Command-Z / Shift-Command-Z | Undo / redo |
| Space | Play / pause the preview |

More guidance is available directly in the app under **Help → Zack Help**
and **Help → Keyboard Shortcuts**.

## Privacy

Your videos, projects, and subtitle transcription stay local to your Mac.
Zack does not upload your footage for editing or transcription.
