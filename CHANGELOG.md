# Changelog

All notable changes to Dyeing Down The House are recorded here.

## [2.0.0] — 2026-08-11 (Curse of Ula'tek, 12.1)

Blizzard rebuilt the dye system in Curse of Ula'tek. Pigments are gone, the 62 dye
items became nine, and crafting is one step at the dye station instead of two. The
addon is rebuilt to match, which is why this is a 2.0.

**This build targets 12.1 and will not work correctly on 12.0.7.**

### Changed

- **Nine colors instead of 62 dyes.** One row per color: Black, Blue, Brown, Green,
  Orange, Purple, Red, White, Yellow. That's what the game stocks now, so that's
  what the window counts and what goals are set against.
- **Teal is gone.** Blizzard retired the category. Its shades moved to blue or
  green, and a teal goal moves with them.
- **Eight color names sit under a different dye than they used to.** Every one of
  the 77 names is now read from the game, and eight of them turned out to have
  been filed wrong — some since long before this patch. Pinewood, Ironclaw and
  Vol'dun Taupe are green; Stormsteel is blue; Dusk Lily Grey is purple; Holy Oak
  Tan is white; Dark Gold is yellow; Klaxxi Amber is orange. If you had a goal
  against one of those, it now counts toward the dye it actually costs.
- **Two tabs again, for two different questions.** By Color is the nine dyes you
  stock — what you have, what your flowers would make, what you still need. By Dye
  is the 77 color names, which is where the numbers get typed.
- **Open a color to see the shades it paints.** All 77 of them, the 15 new ones
  included, in a block of their own under the flowers: a rule, a "Paints 7 colors"
  heading, then the names two across. They're a reference — nothing to hold, count
  or click — and running them down the same column as the flowers made them read
  as flower rows with their numbers missing. Searching a shade name finds its
  family, so typing "obsidium" takes you to Black and pulls the match to the
  front. Turn the list off in the options if you'd rather just see flowers.
- **The Pigment column is gone**, along with the pigments. Makeable covers what it
  was for: how many you could make right now from the flowers on hand.
- **Goals are set per color name, and the family adds them up.** You want five
  Alliance Blue for a wall and three Midnight Blue for the trim; the Blue row says
  you need eight Blue Housing Dye. Set the numbers on the **By Dye** tab, read the
  totals on **By Color**. One place to type, one place to look, and they can't
  disagree.
- **Goals you already had are kept.** They were per-color before there was
  anywhere else to put them, so each one carries over as an unassigned entry on
  its family — it still counts toward the total, and you can edit or clear it from
  the By Dye tab.
- Dye counts from before the patch are cleared rather than carried across. Those
  items don't exist any more and the replacements arrive by mail you have to
  collect, so counting them would claim dyes you don't have yet. Bags recount on
  login and the bank on its next visit.
- Hiding a color needs every one of its old shades to have been unticked. One
  unticked shade shouldn't hide a whole family.

### Added

- **The dyes are read from the game, not from a table.** 12.1 ships an API that
  reports every color's name and the dye item it costs, so the addon learns the
  nine item IDs and which of the 77 colors belongs to which family at login,
  every session. Blizzard adding colors mid-patch now needs no update from me.
- **A "Dye Needed" panel under the house dye window**, styled from the panel above
  it. A row per color the decor is wearing — every dye slot, not just one — with
  the shade's name, which family it costs, how many you hold account-wide, what
  your flowers would make, and a box to set the goal. A color used by two slots
  says "x2", because that's two dyes it'll spend.
- **The dye station is marked up.** The recipes didn't disappear in 12.1,
  they moved out of your crafting book and into the station. So the markers are
  back: a flag on any color you're short of, a "have X / need Y" line under the
  recipe, and a green check on the cheapest flower to make that color out of. Ten
  of one flower makes a dye and a color has up to fifteen to choose from, so that
  last one is the only part of the decision the window doesn't help with.
- **The flowers each color is made from come from the game.** The list you get is
  what the Dye Station's own recipes say — checked against them, not carried over
  from the old pigment ones — so it's right from the first login, station visit or
  no station visit. Standing at a station the addon reads them again and remembers
  what it saw, so if Blizzard moves a flower between colors it fixes itself on
  your next visit rather than waiting for an update from me. Same for how many
  flowers one dye costs. The last hand-maintained table in the addon stops being
  one.
- **Window opacity is adjustable** in the options. It starts exactly where it
  always was; drag it down if you'd rather see the house through it.

### Fixed

- **Blue was counting flowers it can't use.** The herbs each color is made from
  were carried over from the old pigment recipes, and every herb that used to make
  teal was folded into blue on the reasoning that the teal pigment became Blue
  Housing Dye. It doesn't work that way: those herbs dropped teal and kept the
  color they already had — Lichbloom is black, Hochenblume purple, Marrowroot
  brown. Thirteen of them, all sitting in blue, so blue showed 31 flowers where
  it has 18 and Makeable offered blue dyes you couldn't actually make. Bruiseweed
  was teal only, so the fold sent it to blue; it's green. Every other color was
  right.
- **`/dye hidezero` actually hides things now.** It set a flag, said it had
  worked, and filtered nothing. Colors you've set a goal for still show — hiding
  what you have none of shouldn't hide the ones you still need to make.

## [1.3.0] — 2026-08-04

Housing dyes are Warband-bound as of this patch, in preparation for 12.1. They can't
be traded or listed, so a dye has no auction price any more. Flowers still sell as
they always did, and that's the half of the recipe you actually pay for.

### Changed

- **Scans price flowers only.** Querying a dye that can't be listed returns nothing,
  and the auction API is rate limited, so those wasted queries were coming out of
  the budget the flowers needed. Same for TSM and Auctionator: neither has a dye
  price to give.
- **The Value column is now Cost:** what one of that dye costs to make, ten of the
  cheapest flower of its color. Sorting on it puts the cheapest to make first.
- **The expand view compares flowers against each other.** Green is the cheapest way
  into that color, red is a dearer one. It used to mean "cheaper than buying the
  dye", which is no longer a thing you can do.
- Same change to the green check and red X in the pigment reagent picker: the check
  marks the cheapest flower for the color you're milling for.
- "Hide cost-prohibitive flowers" is now "Show only the cheapest flowers".
- Dye prices saved before the patch are cleared on first login. They were priced
  against a market that no longer exists, and a stale number is worse than none.
- The first login after updating gives you the heads up in chat, once, for anyone
  who didn't read the patch notes. The short version is also on the Scan button's
  tooltip and the Cost column's.

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
