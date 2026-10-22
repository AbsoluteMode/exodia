# Google Calendar verification preparation

Status on 2026-10-21: the native app reached Google's unverified-app warning.
The flow was cancelled without granting access. The public data-access review
has not been submitted: a real demonstration video is missing. Branding and
domain verification do not complete this review. The shared Google connection
must stay unavailable until approval is confirmed.

This is a preparation packet, not a claim of completed approval. Current
registration details and provider status belong to [Planner](planner.md#public-verification-preparation).

## Form text

Application purpose:

> Whytap is a native macOS productivity app. Its Calendar feature combines the
> user's selected calendars in one daily agenda inside Hover. Google events
> are read-only; users choose which subscribed calendars to display.

Scope justifications:

| Requested scope | Why the feature needs it |
| --- | --- |
| `https://www.googleapis.com/auth/calendar.calendarlist.readonly` | Lists subscribed calendars by name in the Calendars selector so the user can show or hide each feed. Reading only owned calendars would exclude shared calendars the user has subscribed to. |
| `https://www.googleapis.com/auth/calendar.events.readonly` | Reads event titles, start/end times, descriptions, locations and meeting/original links for the selected day. The daily agenda and inline event details need this information; free/busy alone cannot supply them. |

Data handling, verified against the native implementation:

> Requests go directly from the Mac to Google. External events remain in memory
> for display and are not written to the local Planner archive or its backups.
> Calendar data is not sent to a Whytap server, AI provider or model training.
> Sign-in credentials are stored in macOS Keychain. Optional encrypted backups
> may include saved credentials, as disclosed in the calendar privacy notice.
> Users can disconnect locally and revoke consent in their Google account.
> Whytap requests no calendar write, sharing, Gmail, Drive or contacts access.

Do not attest to policies or security controls that have not been checked.

## Real demo storyboard

Use a dedicated test account with synthetic calendar content and notifications
hidden. Example calendars: **Whytap demo** and **Team demo**; example event:
**Design review**, 10:00–10:30, **Studio**, with a harmless demonstration meeting
URL. Do not copy private meetings into the recording.

1. Show the actual native Whytap Calendar inside Hover, today’s agenda and its Connect entry.
2. Record the actual Google OAuth flow in English, including the full consent
   screen, application identity, browser address containing the matching client
   ID, and both requested permissions. A development warning, if present during
   the owner's review recording, must not be edited out to simulate approval.
3. Complete consent for the dedicated account and return to Whytap. This is a
   review test; do not enable the public packaging approval flag for it. If the
   public gate is already installed, an owner-only development recording path
   must first be prepared and reviewed with the designated builder. Normal
   Hover/Integrations no longer has an Advanced app setup form. The recording
   path must use the existing project client and real authorization without
   enabling public approval or changing the client ID; it is not a public
   distribution. That development path is pending, not supplied by this guide.
   Keep the normal one-app, signature, data and safe-restart checks.
4. Show the subscribed calendar names in **Calendars**, hide/show a feed, then
   show **Design review** in the daily agenda. Open its inline details to
   demonstrate times, location and meeting/original link. These actions show
   the actual use of both scopes.
5. Disconnect the demonstration account. Confirm its external events disappear
   while original Google events remain intact.

The owner must explicitly authorize the demo account's calendar grant. Prepare
and inspect the local recording before any upload. An offscreen fixture or
mock consent screen cannot replace this real evidence.

## Submission and public gate

After inspection and owner upload authorization, upload the real recording as
an unlisted YouTube video. Add its URL and the scope justifications in Google
Cloud → Google Auth Platform → Data Access / Verification Center for the
existing Whytap project. Recheck the homepage, calendar privacy link, contact,
native client and the exact scope list, then submit the completed application.

Only after Google's approval is confirmed, update the private Google native
client packaging configuration with `publicAccessApproved` set to the string
`"true"`. Run `scripts/test-configure-calendar-clients.py`, readiness/browser
tests and the normal checked build workflow. Do not change the client ID to
evade the gate. Verify the actual live consent screen has no unverified-app
warning before calling the public integration ready.

Google's requirements: [sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)
and [demonstration requirements](https://support.google.com/cloud/answer/13464321?hl=en).
