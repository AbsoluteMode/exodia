# Screenshots

Find **Screenshot** in the island's **Search all tools**, or add it from
Settings → Toolbox. Settings → Hotkeys → Tools can assign its optional named
shortcut. Existing layouts and shortcuts are preserved.

Settings → Permissions → **Screen Recording** shows **Allowed** or **Not allowed**
for screenshots. Click **Allow** to request access; **Open** returns to its system
settings when already allowed. A previous denial opens System Settings →
Privacy & Security → Screen & System Audio Recording. Returning to Whytap or
clicking Refresh updates the status. Screenshot invocation can also request
this access; opening Settings or launching Whytap never requests it. It is
optional for other features. Follow macOS's reopen instruction after finishing
current work.

Drag an area on a frozen display, or double-click to edit the whole display.
Return copies/closes immediately, using the full display if there is no crop.
Selection belongs to the display where it starts. The floating toolbar stays
outside the crop where space permits, flips above a bottom-edge crop and is
never included in the image.

One horizontal row offers Arrow, Shape, Pen, Text, **Blur**, contextual settings,
Undo, **Download** and **Copy**. There is no second settings row.
Color, width, shape and text controls appear for the current tool; color/width
are remembered per tool. Enter a text label in the toolbar, then click to place
it. Select & crop (More or V) moves annotations, deletes a selected annotation,
moves the crop and resizes its corners. Blur patches can be deleted or undone,
but cannot be moved because moving them would expose original information.
Selecting or dragging an existing Blur keeps both its pixels and the crop in
place. Delete removes only that blur; undo/redo preserves the crop.

**Blur → Text and numbers** is the default. Select a zone; on-device Vision
finds text regions, numbers, dates, amounts and codes using fast recognition
and language-independent detection. A bounded extra pass checks uncovered
glyphs for isolated letters/digits: a temporary repeated-glyph atlas helps the fast
recognizer identify single numbers. Its pixels never enter the screenshot.
Accurate OCR is reserved for Copy text, avoiding its long cold start in Blur.
Dark-background crops are inverted only for detection, preserving output colors. Only detected text
rectangles are blurred, with small rounded masks and strength
matched separately to each text region’s height, so large text is not weakened
by nearby small labels. Rendering uses a reusable hardware-backed Core Image
context; cropping, detection, blur and PNG encoding run away from the UI thread.
**Entire area**
blurs the complete zone. The visible result supports review: detection can miss
small or unusual text, and blur does not promise irreversible anonymization.
No detections or an analysis error leaves the image unchanged and offers a
retry/entire-area message. Editing/export wait for processing; Escape cancels.

More offers Highlighter, Numbered steps, Spotlight, Copy text, Pin above
windows, Output size, Share, Redo and Cancel. Copy text recognizes the edited
pixels, including blur, rather than the original capture. Pin creates a local
floating reference. Share uses macOS's picker and sends only the edited image
to the service the user selects.

Copy writes flattened PNG pixels to the clipboard and finishes. **Return /
numeric Enter** does the same after selection; during Blur it waits for the
completed patch before copying. Return during Download likewise waits for the file
and then copies/closes. A failed Blur keeps the editor open. In the
annotation text field, Return commits the field and also copies/closes.
**Download** (or ⌘S) writes PNG directly into Downloads, using a readable local
timestamp such as `Screenshot 2026-10-20 at 20.30.15.png`. Existing files are never
overwritten; a collision adds `(2)`, `(3)`, and so on. The editor stays open and
shows “Downloaded to Downloads as …” with the actual filename, also announced to
accessibility. Folder/write failures leave the editor open for retry.
Output size preserves aspect ratio. Captures/history stay in memory until an
explicit
export; no screenshot files are written automatically. Copies may enter the
ordinary clipboard history. Exports carry no editable original layers.
There is no provider setup, account, app-managed model download or API request.

Editor shortcuts, also listed in Help: V Select/crop, A Arrow, R Rectangle,
O Oval, P Pen, T Text, B Blur, M Highlighter, N Numbered steps, ⌘C Copy,
⌘S Download, ⌘Z Undo, ⇧⌘Z Redo. Arrow keys move the crop, Shift moves 10 points,
Option resizes. Delete removes the selected annotation. Escape cancels the
current drawing first, then capture. Without a crop, Return copies the full display and closes; with a crop it
copies that area and closes. These are local editor commands.

Display/Space changes and sleep cancel stale captures. App-initiated update
restarts wait for the editor, local processing, dialogs and unsaved edits to
finish. Returning to idle alone never restarts Whytap.

Implementation: `Sources/Sidekey/Screenshots/`. Tests use generated images and
unshown windows. Real capture, permissions, multi-display compositing, clipboard
delivery, Downloads access and share dialogs require acceptance in the single
installed app
after builder promotion.
