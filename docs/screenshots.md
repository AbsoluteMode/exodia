# Screenshots

Find **Screenshot** in the island's **Search all tools**, or add it from
Settings → Toolbox. Settings → Hotkeys → Tools can assign its optional named
shortcut. Existing layouts and shortcuts are preserved.

Whytap requests macOS Screen Recording access only when invoked. Enable it in
System Settings → Privacy & Security → Screen & System Audio Recording.
Follow macOS's reopen instruction after finishing current work.

Drag an area on a frozen display, or press Return / double-click for the whole display.
Selection belongs to the display where it starts. The floating toolbar stays
outside the crop where space permits, flips above a bottom-edge crop and is
never included in the image.

The main row offers Arrow, Shape, Pen, Text, **Blur**, Undo, Save and Copy.
Color, width, shape and text controls appear for the current tool; color/width
are remembered per tool. Enter a text label in the toolbar, then click to place
it. Select & crop (More or V) moves annotations, deletes a selected annotation,
moves the crop and resizes its corners. Blur patches can be deleted or undone,
but cannot be moved because moving them would expose original information.
Selecting or dragging an existing Blur keeps both its pixels and the crop in
place. Delete removes only that blur; undo/redo preserves the crop.

**Blur → Text and numbers** is the default. Select a zone; on-device Vision
finds text, including standalone numbers, dates, amounts and codes. Language
correction is disabled and language-independent text detection supplements
recognized lines. Only detected text rectangles are blurred. **Entire area**
blurs the complete zone. The visible result supports review: detection can miss
small or unusual text, and blur does not promise irreversible anonymization.
No detections or an analysis error leaves the image unchanged and offers a
retry/entire-area message. Editing/export wait for processing; Escape cancels.

More offers Highlighter, Numbered steps, Spotlight, Copy text, Pin above
windows, Output size, Share, Redo and Cancel. Copy text recognizes the edited
pixels, including blur, rather than the original capture. Pin creates a local
floating reference. Share uses macOS's picker and sends only the edited image
to the service the user selects.

Copy writes flattened PNG pixels to the clipboard and finishes. Save supports
PNG/JPEG by file extension; canceling Save retains the editor. Output size
preserves aspect ratio. Captures/history stay in memory until an explicit
export; no screenshot files are written automatically. Copies may enter the
ordinary clipboard history. Exports carry no editable original layers.
There is no provider setup, account, app-managed model download or API request.

Editor shortcuts, also listed in Help: V Select/crop, A Arrow, R Rectangle,
O Oval, P Pen, T Text, B Blur, M Highlighter, N Numbered steps, ⌘C Copy,
⌘S Save, ⌘Z Undo, ⇧⌘Z Redo. Arrow keys move the crop, Shift moves 10 points,
Option resizes. Delete removes the selected annotation. Escape cancels the
current drawing first, then capture. Return selects the full display before
selection. These are local editor commands.

Display/Space changes and sleep cancel stale captures. App-initiated update
restarts wait for the editor, local processing, dialogs and unsaved edits to
finish. Returning to idle alone never restarts Whytap.

Implementation: `Sources/Sidekey/Screenshots/`. Tests use generated images and
unshown windows. Real capture, permissions, multi-display compositing, clipboard
delivery and save/share dialogs require acceptance in the single installed app
after builder promotion.
