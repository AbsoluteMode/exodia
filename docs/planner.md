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
Encrypted backups include the Planner archive, calendar account settings and saved
OAuth credentials. The local content has its own To-do & calendar archive section;
connection metadata travels with settings and sign-in travels with credentials.
Restore keeps the previous local archive for rollback. Archives from before
Planner support preserve connections already configured on the target Mac.

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
client, `https://www.googleapis.com/auth/calendar.calendarlist.readonly` and
`https://www.googleapis.com/auth/calendar.events.readonly`. These only allow
listing subscribed calendars and reading events; calendar settings and sharing
permissions are not requested.

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

The application owner registers native OAuth clients once. Packaged client
configuration is loaded from WhytapCalendarOAuthClients in the app Info.plist;
ordinary users choose an account and sign in. Advanced app setup allows a source
user to supply their own client. A build without a registered client still needs
that setup; it does not pretend to have a working shared sign-in.
Live consent, organizational restrictions and provider-account compatibility
require acceptance with real accounts. Fixture tests do not prove live sign-in.
Provider registration and public verification remain separate external steps.

Public integration information is available at
[whytap.ai/planner](https://whytap.ai/planner/), with a separate
[calendar privacy notice](https://whytap.ai/calendar-privacy/) linked from the
connection sheet. The pages describe the feature as being prepared and do not
claim provider approval or a generally available release.

1. **Google Cloud:** enable Calendar API, configure the consent screen and create
   a **Desktop app** OAuth client. Add the account as a test user while the app is
   in testing. Enter the client ID and generated desktop client secret when
   required by Google. The desktop client uses a dynamically assigned
   `http://127.0.0.1:<port>/callback` redirect. Public distribution may require
   Google's OAuth verification. The shared Whytap registration is intended for
   public use: testing is a preparation stage, not a personal-only integration.
   Before submitting for verification, publish an accurate app homepage and
   calendar privacy notice on a verified domain, declare the two read scopes,
   and record the real browser-consent and in-app calendar flow for reviewers.
   A client ID alone does not mean that public access has been approved.
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
sizes and listener cleanup apply. Account tokens and the configuration used for each connected account are
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

## Packaging registered clients

Keep the owner's native-client configuration in the Git common directory as
`whytap-calendar-clients.plist`, outside version control. It is a plist dictionary
keyed by `google`, `microsoft` and `zoom`; each entry contains `clientID`. Only
Google's public Desktop client may include `clientSecret`; confidential web-app
secrets, access tokens and refresh tokens are refused.

Both packaging scripts run `scripts/configure-calendar-clients.py` before signing.
`WHYTAP_CALENDAR_CLIENTS_PLIST` can select another local configuration file. Use
`--require-all` on that helper to verify a candidate intended for all three direct
connections. Its output names providers only. Registration values never belong
in logs, public PRs or source documentation.

Closing Planner stops calendar polling. Reopening refreshes the visible range.
An open editor keeps its draft when another tool hotkey brings Planner forward.
The visible window or a retained new-task draft defers Sparkle restart and backup
restore. Ordinary backups continue to capture saved content while Planner is open.

## Public verification preparation

As checked on 2026-10-20, the shared Google Desktop registration exists, Calendar
API is enabled, and the two narrow read scopes are declared. Its public native
configuration is saved privately for packaging. The Whytap logo, homepage and
calendar privacy URL are saved in Google Auth Platform. Ownership of whytap.ai is
verified as a DNS-level Domain property in Google Search Console. Google publishing
status is **In production**, with an **External** audience. Branding has been
verified and published. Calendar data access is not yet verified: until approved,
Google retains its unverified-app warning and lifetime cap of 100 users for the
requested sensitive scope. Production status and verified branding do not approve
access to calendar events. The calendar data-access review is still pending.
Microsoft and Zoom owner-account registration is also pending. The working app
has not been updated by registration or website changes.

For Google's verification form, justify each requested scope from the actual UI:

| Scope | Required behavior |
| --- | --- |
| `calendar.calendarlist.readonly` | List subscribed calendars by name so the user can choose the feeds to display. |
| `calendar.events.readonly` | Read events for the displayed six-week range, show the selected day's agenda and open its meeting/original link. |

The review video must show the real app and browser flow in English: open the
calendar, choose Google, show the consent screen and requested permissions,
finish sign-in, display a calendar containing synthetic example events, change
visible feeds, and disconnect. Use a dedicated test calendar/account without
private events. Offscreen fixtures and a client-creation screenshot do not replace
this evidence. Submit the real unlisted video and only confirm statements that
have been verified. A public registration does not imply organizational admin
approval or Zoom Calendar Service availability for every account.

Provider review requirements:
[Google sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification),
[Google domain verification](https://support.google.com/cloud/answer/13804266?hl=en),
[Zoom distribution](https://developers.zoom.us/docs/distribute/).
