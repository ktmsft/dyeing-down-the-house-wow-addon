# Changelog

All notable changes to Dyeing Down The House are recorded here.

## [0.2.0] — 2026-07-21

### Added

- **Two tabs.** Pigments and flowers belong to a color, not to a dye — every black
  dye mills from the same flowers and draws on the same pigment pile — so the two
  questions want different columns and now get their own views.
  - **By Color Family** — one row per color: `Pigment · Flowers · Makeable · Short`.
    Opens onto that family's flowers, listed once instead of repeating under every
    dye of the color. Clickable headers sort the families, so you can see at a glance
    which color you're richest in or where the work is.
  - **By Dye** — the flat per-dye list exactly as before, opening onto one dye's
    flowers.
- Colors open and close on the family tab, and a search opens whatever it matched.
  `/dye expand` and `/dye collapse` do the lot.
- The color row's tooltip calls out flowers that also feed another family, so the
  contention between colors is visible rather than implied.
- **Price sources.** If you run TradeSkillMaster or Auctionator, prices can be read
  straight from their database — instantly, anywhere in the world, with no auction
  house visit and no queries at all. Choose in the options panel or with
  `/dye source <auto | tsm | auctionator | blizzard>`; "auto" uses the best one
  installed and falls back to the built-in scan when neither is. `/dye source` on its
  own reports what you're using and what's available.
- The Scan button becomes "Prices" and works anywhere when an instant source is
  active.

### Changed

- Expanded flower lists now sit in their own panel — a faint tint carried up onto the
  row you opened, a color stripe down the left, and a line closing the bottom. The
  column dividers no longer run through them, which was making a flower list look
  like dye rows whose columns had broken.
- Flower rows no longer highlight on mouse-over; nothing happened when you clicked
  them.

### Fixed

- **Auction house scans no longer stop partway.** Blizzard silently drops auction
  queries once you exceed its rate limit — no results, no error — and the scanner
  was a pure event chain with no timeout, so one dropped reply stranded the whole
  run (reported as "it stops after 8 or 12 items"). Queries are now paced, and each
  one is watchdogged: no reply in time and the item is retried, then skipped. A
  single dead item can no longer strand the ones behind it.
- Results are matched against the item actually queried, so a late reply to a
  timed-out query can't be filed as another item's price.
- A partial scan now says so in chat instead of finishing quietly.

## [0.1.0] — 2026-07-21

First release.

- Account-wide dye counts across bags, character bank and the Warband bank, with
  live updates on loot, craft, sale and reagent spend.
- Per-dye goals ("Dye needed"), surfaced in the main window and on the Dye
  Crafting recipe list and detail panel.
- Recipe breakdown: expand any dye to see the flowers it's milled from, how many
  you hold, how many dyes those make, and a craft-vs-buy verdict per flower.
  Cost-prohibitive flowers can be hidden.
- Green check / red X on herbs in the pigment reagent picker, showing whether
  milling that herb is worth it for the pigment's color.
- Auction-house pricing via `/dye scan`, using the lowest price with real market
  depth behind it so thin listings can't distort the value.
- Search by dye name or color family; sort by name, amount owned, value, or
  craftability.
- Settings panel: column visibility, collapsible dye and flower show/hide lists,
  a rainbow or plain title, and a window lock.
- Window can collapse to a slim title bar.
- Optional DataStore support for offline characters' dyes.
