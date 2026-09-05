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

## Add subtitles

Click the captions button in the toolbar to generate subtitles for the complete
timeline. Zack includes its own local transcription engine and English model,
so there is no Python, Conda, account, or separate download to configure.

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
your clip order, trim ranges, and subtitles while continuing to reference the
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
