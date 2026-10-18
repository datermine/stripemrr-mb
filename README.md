# stripe-mrr

A tiny native macOS menu bar app that shows your Stripe MRR (e.g. `$12,345`) and refreshes every 3 hours. No dependencies beyond the Swift toolchain that ships with Xcode / Command Line Tools.

Clicking the number shows MRR, ARR, subscription count, last update time, **Refresh Now** (⌘R), and **Open Billing Overview** (⌘O).

To keep the number off-screen (e.g. while screen sharing), choose **Set Menu Bar Text…** and enter any text or emoji. The menu bar shows that instead, and the numbers stay visible in the menu when you click it. **Clear Menu Bar Text** brings the number back. The setting persists across restarts.

## How MRR is computed

Stripe has no API endpoint for the Billing overview's MRR figure, so it's computed from subscriptions the way Stripe describes it:

- Subscriptions with status `active` or `past_due` (trials excluded)
- Each item's price × quantity, normalized to a month (yearly ÷ 12, weekly × 52/12, daily × 365/12, and `interval_count` respected)
- Tiered (volume/graduated) and package (`transform_quantity`) pricing supported
- Item- and subscription-level discounts applied (percent-off and amount-off), expired discounts ignored
- Tax excluded

Expect it to land very close to the dashboard but not always exactly on it: the dashboard figure updates roughly daily, while this reflects subscriptions as of the last refresh. Run `make print` to compare.

**Known gaps:** metered (usage-based) items aren't counted (the menu shows how many were skipped); coupons restricted to specific products are applied to the whole subscription; multiple currencies are shown as separate totals, not converted.

## Setup

1. **Create a restricted key** in Stripe: Developers → API keys → Create restricted key → *Powering an integration you built* → *Choose your own*. Set **Subscriptions → Read**, everything else **None**. If a request fails for lack of a permission, Stripe's error names it — add that one as Read.

2. **Store it in the Keychain** (run in your own terminal; paste the key when prompted):

   ```sh
   security add-generic-password -s stripe-mrr -a "$USER" -w
   ```

   The app reads it via `/usr/bin/security`, so there's no Keychain access prompt. `STRIPE_API_KEY` in the environment overrides the Keychain, which is handy for testing.

3. **Check the number** against the dashboard:

   ```sh
   make print
   ```

   Prints MRR per subscription, then totals.

4. **Install** so it runs now and at every login:

   ```sh
   make install
   ```

## Make targets

| Target           | What it does                                                                      |
| ---------------- | --------------------------------------------------------------------------------- |
| `make`           | Build `build/stripe-mrr`                                                          |
| `make print`     | Build, compute MRR once, print a per-subscription breakdown                       |
| `make install`   | Build, copy to `~/.local/bin/stripe-mrr`, install and load the LaunchAgent        |
| `make uninstall` | Stop the app and remove the binary and LaunchAgent (the Keychain item is kept)   |

After editing `main.swift`, `make install` rebuilds and restarts it.

## Where things live

| What        | Where                                                   |
| ----------- | ------------------------------------------------------- |
| Source      | `main.swift`                                            |
| Binary      | `~/.local/bin/stripe-mrr`                               |
| LaunchAgent | `~/Library/LaunchAgents/local.stripe-mrr.plist` (label `local.stripe-mrr`) |
| API key     | Keychain, service `stripe-mrr`                          |
| Settings    | `defaults read stripe-mrr` (menu bar text)              |

## Behavior

- Refreshes when the last successful fetch is older than 3 hours; checks every 5 minutes and on wake from sleep, so it catches up after the Mac was asleep.
- On failure it keeps showing the last value with a `⚠︎` and retries every 5 minutes. The error is shown in the menu (hover for the full message).
- **Quit** stops it until next login. If it crashes, launchd restarts it.
- Refresh interval and other settings are constants at the top of `main.swift`.

## Troubleshooting

- **Not visible in the menu bar:** on notched MacBooks, a crowded menu bar hides overflow items. Quit some other menu bar apps.
- **`No Stripe key in Keychain`:** redo setup step 2.
- **`Stripe 401` / `403`:** key revoked or missing a permission; the message says which.
- **`Error 3 (ignored)` during `make install`:** harmless; it's the attempt to stop a previous instance that wasn't loaded.
- **Status:** `launchctl print gui/$(id -u)/local.stripe-mrr | grep state`
- **Rotate the key:** `security delete-generic-password -s stripe-mrr`, then redo step 2.
