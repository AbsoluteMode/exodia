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
   review test; use the temporary local review session below, keeping the public
   packaging approval flag closed. Normal Hover/Integrations has no Advanced
   app setup form. Keep the existing project client and real authorization.
4. Show the subscribed calendar names in **Calendars**, hide/show a feed, then
   show **Design review** in the daily agenda. Open its inline details to
   demonstrate times, location and meeting/original link. These actions show
   the actual use of both scopes.
5. Disconnect the demonstration account. Confirm its external events disappear
   while original Google events remain intact.

The owner must explicitly authorize the demo account's calendar grant. Prepare
and inspect the local recording before any upload. An offscreen fixture or
mock consent screen cannot replace this real evidence.

## Temporary local review session

The designated builder can launch the one installed `/Applications/Whytap.app`
with a process-local environment containing:

```text
WHYTAP_GOOGLE_CALENDAR_REVIEW=1
WHYTAP_GOOGLE_CALENDAR_REVIEW_UNTIL=<future UTC Unix timestamp in whole seconds>
```

Use a deadline one hour from launch; deadlines more than two hours ahead, missing
or malformed values and expired sessions stay closed. Pass these values through
`NSWorkspace.OpenConfiguration.environment` for that launch only, after the normal
activity/signature/safe-restart gates. Do not set global launchd variables, save a
preference, change the packaged approval flag or distribute a review-enabled
launcher. Feature workers do not launch or install an app.

Verify the actual process with the bundled `whytap app status`: its
`googleCalendarReviewActive` boolean must be `true`. Then ordinary **Hover →
Calendar → Connect → Google Calendar** starts the real browser flow directly.
The same temporary access applies to **Settings → Integrations**. The Google
warning can still appear for this explicitly opted-in development recording;
this does not constitute provider verification. Zoom stays gated.

This is a local developer opt-in, not a restriction to a particular Google
identity. The owner chooses the authorized demo account in Google's UI and
grants its two read-only scopes. No account identity or credential is placed in
the launch environment or diagnostic status. The normal launch without these
variables remains closed for new shared-client sign-ins.

Expiry blocks new authorization attempts; it does not abort a consent already
started or revoke credentials from a completed connection. Disconnect the demo
account and revoke it in Google when finished. A normal restart clears the
process opt-in; no preference or public-approval change survives it.

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
