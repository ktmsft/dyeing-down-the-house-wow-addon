# Changelog

All notable changes to Dyeing Down The House are recorded here.

## [1.3.0] — 2026-08-04

Dyes are Warband-bound as of this patch. They can't be traded or listed, so a dye
has no auction price any more — but flowers still sell as they always did, and
that's the half of the recipe you actually pay for.

### Changed

- **Scans price flowers only.** Querying a dye that can't be listed returns nothing,
  and the auction API is rate limited — those wasted queries were coming out of the
  budget the flowers needed. Same for TSM and Auctionator: neither has a dye price
  to give.
- **The Value column is now Cost** — what one of that dye costs to make, ten of the
  cheapest flower of its color. Sorting on it puts the cheapest to make first.
- **The expand view compares flowers against each other.** Green is the cheapest way
  into that color, red is a dearer one. It used to mean "cheaper than buying the
  dye", which is no longer a thing you can do.
- Same change to the green check and red X in the pigment reagent picker: the check
  marks the cheapest flower for the color you're milling for.
- "Hide cost-prohibitive flowers" is now "Show only the cheapest flowers".
- Dye prices saved before the patch are cleared on first login. They were priced
  against a market that no longer exists, and a stale number is worse than none.
- The first login after updating says all this in chat, once, for anyone who didn't
  read the patch notes. It's also on the Scan button's tooltip and the Cost column's.

## [1.2.0] — 2026-07-21

### Added

- **Two tabs.** Pigments and flowers belong to a color, not to a dye — every black dye mills from the same flowers and draws on the same pigment pile — so the two questions want different columns and now get their own views.
- **By Color Family** — one row per color: `Pigment · Flowers · Makeable · Short`. Short is how many dyes you still need across the family, so you can read it straight against Makeable and see whether your stock covers it. Open a color for the flowers it mills from, listed once instead of repeating under every dye. Clickable headers sort the families, so you can tell at a glance which color you're richest in and where the work is.
- **By Dye** — the flat per-dye list exactly as before, opening onto one dye's flowers.
- Colors open and close on the family tab, and a search opens whatever it matched. `/dye expand` and `/dye collapse` do the lot.
- The color row's tooltip calls out flowers that also feed another family, so the contention between colors is visible rather than implied.
- **Price sources.** If you run TradeSkillMaster or Auctionator, prices can be read straight from their database — instantly, anywhere in the world, with no auction house visit and no queries at all. Choose in the options panel or with `/dye source <auto | tsm | auctionator | blizzard>`. "Auto" uses the best one installed and falls back to the built-in scan when neither is; `/dye source` on its own reports what you're using and what's available.
- The Scan button becomes "Prices" and works anywhere when an instant source is active.

### Changed

- Expanded flower lists now sit in their own panel — a faint tint carried up onto the row you opened, a color stripe down the left, and a line closing the bottom. The column dividers no longer run through them, which was making a flower list look like dye rows whose columns had broken.
- Flower rows no longer highlight on mouse-over; nothing happened when you clicked them.

### Fixed

- **Auction house scans no longer stop partway.** Blizzard silently drops auction queries once you exceed its rate limit — no results, no error — and the scanner was a pure event chain with no timeout, so one dropped reply stranded the whole run (reported as "it stops after 8 or 12 items"). Queries are now paced, and each one is watchdogged: no reply in time and the item is retried, then skipped. A single dead item can no longer strand the ones behind it.
- Results are matched against the item actually queried, so a late reply to a timed-out query can't be filed as another item's price.
- A partial scan now says so in chat instead of finishing quietly.
- **A goal counts as met only when you actually hold the dyes.** The green check next to a goal used to count pigment in your bags as already covering it, so a dye could show a tick while the crafting window was still flagging it to craft. One definition now, everywhere; whether pigment can close the gap is what the Makeable column answers.
- **Short counts dyes, not dye types.** It used to add 1 per dye under its goal, so a family you needed 33 more of showed "1 short" — and sitting next to Makeable, which is a quantity, that read as covered when it wasn't.

## [0.1.0] — 2026-07-21

First release.

- Account-wide dye counts across bags, character bank and the Warband bank, with live updates on loot, craft, sale and reagent spend.
- Per-dye goals ("Dye needed"), surfaced in the main window and on the Dye Crafting recipe list and detail panel.
- Recipe breakdown: expand any dye to see the flowers it's milled from, how many you hold, how many dyes those make, and a craft-vs-buy verdict per flower. Cost-prohibitive flowers can be hidden.
- Green check / red X on herbs in the pigment reagent picker, showing whether milling that herb is worth it for the pigment's color.
- Auction-house pricing via `/dye scan`, using the lowest price with real market depth behind it so thin listings can't distort the value.
- Search by dye name or color family; sort by name, amount owned, value, or craftability.
- Settings panel: column visibility, collapsible dye and flower show/hide lists, a rainbow or plain title, and a window lock.
- Window can collapse to a slim title bar.
- Optional DataStore support for offline characters' dyes.
