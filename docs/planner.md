# Whytap Planner

Open **Search all tools → To-do** or **Calendar**. Both open the same native
Planner window. The tools can also be added from Settings → Toolbox; adding this
feature does not change existing saved tool layouts or positional shortcuts.

## Tasks and Whytap events

Tasks support add/Return, search, edit, complete/reopen and confirmed deletion.
The Active and Completed lists keep finished work available. Whytap events support
titles, start/end times, all-day spans, locations, notes, https meeting links and
confirmed deletion. All-day end dates in the editor are inclusive; storage uses
an exclusive boundary. Civil all-day dates survive a time-zone change.

The local planner is stored privately in Application Support/Sidekey/Planner.
Changes persist atomically before appearing in the interface. Unreadable or
unsupported archives block writes and retain the original file; Retry loads a
restored file. A failed save keeps the editor/draft and reports an error.
Local tasks and events are not uploaded by calendar connections.
The existing encrypted-backup allowlist does not yet include the Planner archive,
calendar account settings or OAuth credentials; do not rely on that feature to
restore Planner data on another Mac.

## Unified calendar

The month grid and selected-day agenda combine the local Whytap calendar with
selected external calendars. Use **Calendars** to hide/show individual feeds,
inspect the last successful refresh and connection errors, or disconnect an
account. The displayed time zone is the Mac's current time zone. Recurring
external events are expanded by each provider for the visible six-week range.
Matching external iCalendar UIDs with identical occurrence bounds collapse into
one agenda item, retaining meeting/original links and an additional-source count;
unrelated events are never merged by title alone.

External connections are **read-only** in this first implementation. Edit them in
the original app; Whytap refreshes on opening the calendar, changing month,
connecting/disconnecting, explicit Refresh and every minute while it is visible.
Native calendar-change notifications trigger another refresh. Previously fetched
events remain visible after a network failure and are marked potentially stale.
There is no background sync when the calendar view is closed and no persistent
external-event cache. A source without a successful first sync is not labelled
as synced. Disconnect deletes its Keychain credential and displayed events;
provider-side consent can additionally be revoked in the provider's account UI.

**Apple Calendar:** Connect account → Apple Calendar requests the macOS calendar
permission. It shows the calendars available through EventKit, including iCloud.
macOS requires full event permission even for reading; Whytap only reads.
This connection does not require a Whytap backend or a new Apple OAuth client.
When the same Google/Exchange account is also available through macOS, use the
feed checkboxes to select the desired source. UID-based collapse cannot identify
copies for which the providers return unrelated identifiers.

**Google:** connects directly to Google Calendar API using a Desktop OAuth
client and `https://www.googleapis.com/auth/calendar.readonly`.

**Outlook and Teams:** connects directly to Microsoft Graph calendars using
delegated `Calendars.Read` and `offline_access`. Teams meeting links come from
the Outlook event's `onlineMeeting.joinUrl`; this is not a separate Teams chat or
meeting-bot integration. Organizational policies can require administrator consent.

**Zoom:** connects directly to **Zoom Calendar Service**, using
`calendar:read:list_calendar_lists` and `calendar:read:list_events`. This requires
that service and API permissions on the account. It is not a replacement for the
Zoom Meetings API: a Zoom client merely displaying a linked Google or Microsoft
calendar should connect that calendar's provider here. Zoom links on events from
any supported source remain joinable.

## OAuth app registration

Use **Whytap** as the application name and public consent-screen brand.

No shared provider registrations or production OAuth client IDs were supplied
with this change. Direct sign-in needs the developer's registered public client
configuration, entered in Connect account. Live authorization, organizational
consent and provider-account compatibility require separate acceptance with real
accounts. Passing fixture tests is not evidence of a live provider connection.
These registrations are not created automatically by the application.

1. **Google Cloud:** enable Calendar API, configure the consent screen and create
   a **Desktop app** OAuth client. Add the account as a test user while the app is
   in testing. Enter the client ID and generated desktop client secret when
   required by Google. The desktop client uses a dynamically assigned
   `http://127.0.0.1:<port>/callback` redirect. Public distribution may require
   Google's OAuth verification.
2. **Microsoft Entra:** register a public native app with the appropriate account
   audience, permit public client flows and delegated Calendars.Read. Register
   **Mobile and desktop applications → http://localhost/callback**. Whytap uses
   an ephemeral port; Microsoft's documented localhost exception ignores it.
   No client secret is embedded or required.
3. **Zoom Marketplace:** create a General app, enable Public Client OAuth with
   S256 PKCE and add `http://127.0.0.1/callback` to its OAuth allow list. Enable the
   two granular read scopes above and use the **public** client ID. Eligible
   native PKCE clients use a fresh loopback port; no client secret is required.

Authorization opens the default browser; a temporary receiver binds only
127.0.0.1. Microsoft uses a localhost redirect, with that same numeric listener.
State validation, S256 PKCE, a three-minute timeout, cancellation, bounded request
sizes and listener cleanup apply. Tokens and Google client configuration are
stored in the login Keychain under the existing channel's service. Rotated refresh
tokens are persisted before an API call resumes. Disconnect cancels pending
refreshes so they cannot restore a deleted credential. Private responses use an
ephemeral URLSession without cookies/cache; requests reject redirects, and API
pagination rejects foreign hosts before sending authorization. No account
passwords, tokens or event content are logged.

## Verification

Tests use temporary archives, isolated defaults, an in-memory credential store,
fake provider responses and loopback callbacks; they never connect real accounts.
Offscreen fixtures use synthetic content and never show or register an app.
Native macOS compositor effects and real pointer/keyboard behavior still need
acceptance in the one shared installed application.

```sh
swift test --filter 'Planner|CalendarProviderTests|CalendarConnectionTests'
EXODIA_PLANNER_RENDER_DIR=/tmp/exodia-planner-preview swift test --filter PlannerRenderTests
```

Implementation entry points: `Sources/Sidekey/Planner/PlannerStore.swift`,
`PlannerWindowController.swift`, `PlannerView.swift`, `PlannerCalendarView.swift`,
`CalendarConnectView.swift`, `CalendarConnections.swift`, `CalendarRemoteClient.swift`,
`CalendarOAuth.swift`, `CalendarProvider.swift` and `CalendarHTTP.swift`.

Provider contracts checked on 2026-10-19:
[Apple event access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
[Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app),
[Google Calendar scopes](https://developers.google.com/workspace/calendar/api/auth),
[Microsoft native OAuth](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow),
[Microsoft redirect rules](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url),
[Graph calendarView](https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview?view=graph-rest-1.0),
[Teams meeting links](https://learn.microsoft.com/en-us/graph/outlook-calendar-online-meetings),
[Zoom OAuth and loopback](https://developers.zoom.us/docs/integrations/oauth/),
[Zoom Calendar API](https://developers.zoom.us/docs/api/calendar/).
