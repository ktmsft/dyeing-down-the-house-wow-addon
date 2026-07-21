# Dyeing Down The House

An account-wide tally of every housing dye across your bags, bank and Warband
bank — with goals, recipes and auction prices. Colour your world.

## What it does

- **Counts every dye you own, account-wide.** Bags, character bank and the
  Warband bank are all totalled, across every character. Counts update live as
  you loot, craft, sell or spend.
- **Set a goal per dye** ("Dye needed"). The list shows how far short you are,
  and the Dye Crafting window marks the recipes still worth making.
- **Recipe planning.** Every dye expands to the flowers it's milled from — how
  many of each you hold, how many dyes those can make, and whether it's cheaper
  to craft the dye or just buy it outright. Costly flowers can be hidden.
- **Auction prices.** At the auction house, `/dye scan` prices every dye from the
  live market (using the lowest price with real depth behind it, so a single
  gouging listing can't skew the value). The scan time is shown in the window.
- **Search and sort.** Filter by dye name *or* colour family — typing `blue`
  finds every blue-family dye. Sort by name, amount owned, value, or craftability.

## Using it

- `/dye` — toggle the window (also on the minimap addon compartment).
- `/dye scan` — price the dyes (run it at the auction house).
- `/dye search <text>` — filter by dye name or colour family.
- `/dye sort <alpha | price | owned>` — change the order.
- `/dye options` — open the settings panel (column visibility, the dye and
  flower show/hide lists, rainbow title, window lock).
- `/dye help` — the full command list.

The window can be locked in place, or collapsed to a slim title bar for players
who'd rather keep it out of the way than close it.

## Optional dependencies

If [DataStore](https://www.curseforge.com/wow/addons/datastore) and
DataStore_Containers are installed, dyes held by characters you haven't logged
into this session are counted too.

## Author

KTM (abitofmoss). Released under the MIT license.
