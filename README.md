# Dyeing Down The House

An account-wide tally of every housing dye across your bags, bank and Warband bank —
with goals, recipes and auction prices. Color your world.

Dyes are scattered across every character, two kinds of bank, and a three-step
crafting chain. This puts it all in one window: what you own, what you still need,
what you can make right now, and whether it's cheaper to mill it or just buy it.

---

## The window

`/dye` opens it. One row per dye.

| Column | |
|---|---|
| **Dye** | with a swatch of its color family |
| **Have** | account-wide — every character's bags and bank, plus the Warband bank |
| **Pigment** | pigments of that color you hold, and in ( ) how many of *this* dye they'd make |
| **Flowers** | flowers of that color you hold, and in ( ) how many of *this* dye they'd mill into |
| **Value** | what your stock is worth at auction |
| **Dye Needed** | your goal — type a number straight into the box |

Click a header to sort, click again to flip it. Every column except Dye and Have can
be switched off, and the window shrinks to fit.

A green check appears next to your goal once you're covered — counting dyes you hold
*plus* pigment ready to become more.

**Hover a dye** for the full picture: color family, owned, needed, pigments and
flowers held with the dyes each would make, total craftable now. If you're short, it
says which — "Craft 4 more to reach it" or "Short 3 pigment (30 flowers)".

**Click a dye** to expand it into the flowers it mills from. Each one shows how many
you hold, how many dyes that alone makes, and the craft cost — **green if it beats
buying the dye outright, red if it doesn't.** Cheapest first. The hopeless ones can
be hidden.

---

## Counting, properly

**Every character, both banks.** The Warband bank is shared, so it's counted once no
matter how many alts you have.

**Live.** Updates as you loot, craft, sell, or spend reagents.

**It catches what other trackers miss.** The game only reveals bank contents while
you're standing at a bank, so those numbers are snapshots. When a work order pulls
reagents out of the Warband bank, or an auction sells a stack you never touched,
nothing in your bags changes — and most addons keep insisting the items are there.
This one cross-checks what you can actually reach and corrects itself. It only ever
revises *down*, never up. Next bank visit restores exact numbers.

**Milling is counted the way the game does it.** Ten of the *same* flower make a
pigment. Forty flowers across four types make **zero** pigments, not four. The
Flowers column knows.

**Shared flowers count in both families**, because they genuinely can go either way.
Spending them on one just denies the other.

`/dye chars` lists who's feeding the totals and when each was last seen.
`/dye forget <Name-Realm>` drops a deleted alt.

---

## Auction prices

Open the AH, hit **Scan** (or `/dye scan`). Progress floats above the window; last
scan time is on the button's tooltip.

It doesn't store the lowest buyout. One 1-unit listing at a silly price would poison
every craft-vs-buy verdict in the addon. It takes the lowest price with real depth
behind it — what you'd actually pay buying a real quantity — so a lone gouger can't
move the number. Thin market? It tells you what clearing it costs.

Scans skip pigments and anything you've unchecked. No queries wasted on dyes you
don't care about.

---

## It works inside Blizzard's windows too

- **Dye Crafting list** — a yellow **!** on recipes you're below goal on.
- **Dye Crafting detail** — a "You have 6 / need 10" line under the title, green once
  you're there.
- **Pigment reagent picker** — green check or red X on every herb: is milling *this*
  one worth it for *this* color, at current prices? No more guessing which of fifteen
  herbs is the cheap one.
- **House decorating panel** — with a dye selected, a "Dye Needed" box appears above
  the Cost line. Set the goal while you're looking at the furniture.

All four can be switched off.

---

## Search and sort

Search filters by dye name **or color family** — typing `blue` finds the dyes named
"…Blue…" *and* every dye in the blue family, whatever it's called. **Clear** resets
filter and sort together.

Sort by name, owned, goal, value, or craftability — and craftability splits three
ways: total, from pigments you hold, or from flowers you hold. Unpriced dyes always
sink to the bottom.

---

## Options

`/dye options`, or the button on the window.

- **Columns** — Pigment, Flowers, Value, Dye Needed
- **Hide cost-prohibitive flowers** — drop the ones that cost more to mill than the
  dye costs to buy
- **Lock the window**
- **Track dyes needed in housing panel**
- **Mark cost-worthy herbs when crafting**
- **Rainbow title** (off = plain)
- **Dyes to show** — all 62, grouped by color with swatches. Uncheck what you don't
  care about
- **Flowers to show** — by name, all quality tiers together. Check All / Uncheck All
  on both

The window drags anywhere, resizes by the corner grip, remembers where you left it,
and locks. The **−** button collapses it to a slim title bar if you'd rather tuck it
away than close it.

---

## Commands

| | |
|---|---|
| `/dye` | toggle the window |
| `/dye scan` | price everything (at the auction house) |
| `/dye search <text>` | filter by dye name or color family |
| `/dye sort <alpha \| price \| owned>` | change the order |
| `/dye hidezero` | hide dyes you have none of |
| `/dye lock` · `/dye unlock` | freeze or free the window |
| `/dye reset` | recenter the window |
| `/dye options` | settings |
| `/dye chars` | characters, and when each was last scanned |
| `/dye forget <Name-Realm>` | drop a deleted character |
| `/dye help` | the full list |

`/dyes` and `/ddth` also work.

---

## Optional: DataStore

If [DataStore](https://www.curseforge.com/wow/addons/datastore) and
DataStore_Containers are installed, characters you haven't logged into this session
get counted too. Not required. Your own scans always win, and the Warband bank is
never taken from DataStore — that would multiply it by your roster size.

---

## Notes

Dye and flower data is read from the game's own Dye Crafting recipes, not guessed:
every ID is the actual recipe output, every color read from the pigment the recipe
consumes. If an ID ever drifts, the addon recovers by name and remembers.

Blizzard's crafting and housing frames are internal and shift between patches, so
every hook is defensive. If one moves in a future patch the decoration quietly stops
appearing instead of breaking your UI.

---

KTM (abitofmoss) · MIT · bugs and suggestions welcome.
