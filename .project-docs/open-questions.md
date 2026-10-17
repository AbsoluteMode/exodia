# Open questions

- Community updates: may a prepared update apply on ordinary app exit? User
  choice is pending. Later cancels the current installation; holding Ready
  alone does not disarm Sparkle's installer. Release gate and evidence:
  [community updates](decisions/2026-10-17-community-updates.md).

- The historical STT watchdog incident has no captured provider frame trace.
  Manual finalization is supported and verified on synthetic audio; whether
  the original stall was caused by the network or provider remains unknown.
- Reasoning-token counts for the historical slow cleanup were not recorded.
  New local diagnostics enable future attribution without recording content.
