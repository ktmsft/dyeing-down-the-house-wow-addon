# Changelog

All notable changes to Dyeing Down The House are recorded here.

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
