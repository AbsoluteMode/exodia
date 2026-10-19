import Foundation

enum NotifySetupGuide {
    static func contents(directory: URL) -> String {
        """
        # Exodia Notify: local script sources

        Notifications appear as the existing compact pill LEFT of the island.
        History (including each event's color and logo) and source controls are in
        Notify. Find Notify with Search all tools or add it through Settings > Toolbox.
        Settings > Notifications lists all connected sources with individual on/off switches.
        No Exodia server or model request is needed to deliver a notification.

        ## Configure a source

        Ask the user which events they want, which chats/accounts or filters apply,
        and request only the access required by that integration. A request to show
        incoming messages does not authorize sending messages or changing accounts.
        Use the source's supported APIs and the user's own authorized access.
        Store credentials in macOS Keychain or their chosen credential manager.
        Never put secrets in source JSON, notification output, arguments or logs.

        Root: \(directory.path)
        Registry: \(directory.appendingPathComponent("sources").path)
        Logos: \(directory.appendingPathComponent("logos").path)
        History: \(directory.appendingPathComponent("history.json").path)

        Install an atomic UTF-8 JSON file named <id>.json in sources, mode 600.
        Required: id (1..64 letters/digits/dot/underscore/hyphen, starts alphanumeric),
        name (1..100 chars), command (argv array, first entry an absolute executable
        path). Optional: enabled (default true), intervalSeconds (5..86400), tint
        (#RRGGBB), logo, duration (2..60 seconds, default 8). At most 16 sources.
        Working files/cursors should be private files under the notification root.
        Preserve unrelated sources and notifications.

        Example source (use actual paths on this Mac):
        {"id":"example","name":"Example","command":["/bin/zsh","/absolute/path/example.zsh"],"tint":"#299FD6","logo":"paperplane.fill","intervalSeconds":30}

        Exodia supervises the command while the app runs, including with the drawer
        closed. No shell interpolation is performed: arguments are literal argv.
        Without intervalSeconds, keep the worker alive for streaming/long polling;
        clean exits restart after 5 seconds. With intervalSeconds, run one polling
        pass and exit; a successful pass repeats after that delay. Failures retry
        with bounded backoff up to 60 seconds. Sources pause on system sleep and
        restart after wake. Exodia stops the process group, including helpers,
        when the source is disabled/removed or the app quits. Do not daemonize,
        detach, install LaunchAgents or arrange workers to survive Exodia.

        ## Emit events

        Write one UTF-8 JSON object per stdout line, and FLUSH it. Python receives
        PYTHONUNBUFFERED=1. Use stderr only for non-sensitive diagnostics; Exodia
        discards stderr and does not log script output. Maximum line 64 KiB and
        10 notifications/second/source; malformed lines do not become notifications.

        {"id":"upstream-event-123","title":"Message from Alex","body":"The build is ready","tint":"#299FD6","logo":"paperplane.fill","duration":8,"link":"https://example.com/message/123"}

        title is required (1..200 chars). Optional: body (up to 8000 chars), id (up
        to 256 bytes), tint, logo, duration, link. Event fields override source
        defaults. A stable id is deduplicated per source across launches while it
        remains in the retained history (500 events). Without id each event is new.
        Keep the upstream cursor/checkpoint in private storage so reconnects don't
        repeatedly deliver a backlog. Notifications aren't replayed on app launch.
        Link is optional: a pill without a link only dismisses. Links open only
        after a user click; supported schemes: https, http, tg, slack, linear,
        github, mailto. No executable, file or JavaScript links.

        logo is an SF Symbol or a local image name without extension. Put <name>.png,
        .jpg, .jpeg or .pdf (at most 2 MiB) in logos; no paths or remote image URLs.
        Bundled brand PDFs are also available. Unknown names fall back to a monogram.
        Color/logo are persisted with the event, so history keeps its presentation.

        ## Verify and maintain

        First validate the JSON and run the command once with synthetic output in
        a temporary directory. Then install the source and have it emit one uniquely
        identified setup event. Within a few seconds confirm the exact event id in
        history.json (the stored id is <source id>:<event id>). A running process
        alone does not prove delivery or a connection to the real upstream source.
        Tell the user which source/filter was connected and what was verified.
        Don't claim a Telegram connection from a synthetic test alone.

        Settings > Notifications and Notify > Sources show runtime/configuration
        errors and an enable switch. Disabling keeps the setup and event history.
        Removing a source deletes only its manifest and stops it; script files,
        credential-manager entries and notification history are preserved.
        """
    }
}
