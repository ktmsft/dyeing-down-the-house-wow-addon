# Dyeing Down The House — technical notes

How the addon works and why it's built this way, written for someone with no World
of Warcraft background. The player-facing description — the one that ships in the
package and goes on CurseForge — is [CURSEFORGE.md](CURSEFORGE.md).

## The problem

WoW added player housing, where you decorate furniture with **dyes**. Dyes are
inventory items. You either buy them on the game's player-run marketplace (the
Auction House) or craft them:

```
10 identical herbs  →  1 pigment  →  1 dye
```

Everything groups into **10 color families**. One pigment per color; many herbs mill
into it; many dyes come out of it. A herb can belong to more than one family — the
same 40 Poppy are simultaneously a blue resource and a red one, and spending them on
either denies the other.

Inventory isn't one place. It's:

- each character's **bags** (many characters per account),
- each character's private **bank**,
- one **shared account-wide bank** ("Warband bank").

So *"how many Midnight Blue Dye do I own, and is it cheaper to craft or buy the
rest?"* means aggregating a partially-observable, multi-actor inventory and joining
it against live market prices. That's what this does.

## Platform constraints

Addons are **Lua 5.1** running inside the game client.

- **No filesystem, no network, no threads.** Persistence is one global table the
  client serializes on logout. No database, no migrations — a `version` field and a
  recursive defaults-merge ([Core.lua:128](Core.lua#L128)).
- **Event-driven.** Frames register for client events (`BAG_UPDATE_DELAYED`,
  `AUCTION_HOUSE_SHOW`, …). There's no main loop.
- **The API is unstable and undocumented.** Blizzard's UI is itself Lua; addons
  extend it by reaching into internal frame objects that get renamed between patches.
- **Partial observability.** Bank contents are only readable while a bank window is
  open. Elsewhere the same call reports zero slots — not an error, just silence.

## Layout

Seven files, loaded in dependency order via a manifest
([DyeingDownTheHouse.toc](DyeingDownTheHouse.toc)):

| File | |
|---|---|
| [Data.lua](Data.lua) | Static data: 62 dyes, 10 pigments, ~95 herbs — name, item ID, color(s) |
| [Core.lua](Core.lua) | State and logic: scanning, persistence, recipe math, price scraping, filter/sort |
| [Prices.lua](Prices.lua) | Pluggable price sources — TSM / Auctionator / the built-in scan |
| [UI.lua](UI.lua) | The window — sortable, column-configurable, expandable table |
| [Options.lua](Options.lua) | Settings panel |
| [Crafting.lua](Crafting.lua) | Decorates the game's *own* crafting window |
| [Housing.lua](Housing.lua) | Injects a goal field into the game's *own* decorating panel |

Core exposes an `ns.*` namespace; the UI layers only read from it. Core also defaults
every UI entry point to a no-op at load ([Core.lua:76-81](Core.lua#L76-L81)) so the
data engine survives the presentation layer failing to load. That was a real crash —
a bag event firing a timer into a `nil` callback.

## Problems worth describing

### 1. Aggregating a partially-observable inventory

Each character writes `DB.chars[charKey] = {bags, bank, bagsSeen, bankSeen}`. Bags
rescan on every bag event; bank and Warband are snapshots taken whenever a bank
window happens to open. Totals sum over all characters, then add the shared Warband
bank **once**, outside the character loop ([Core.lua:437](Core.lua#L437)) — the
obvious bug is multiplying shared inventory by roster size.

The hard case is cache invalidation with no event to hook. Crafting can pull reagents
straight from the shared bank; an auction sale can remove a stack the addon never saw
leave. Bags don't change, nothing fires, and the snapshot keeps lying.

The fix ([Core.lua:281](Core.lua#L281)) uses a different API (`GetItemCount`) that
reports bank contents from anywhere — but only for what the *current* character can
reach. Enough to detect a shortfall, not enough to attribute it. So the pass is
deliberately **monotonically decreasing**: it only subtracts, draining the private
bank before the shared one, and ignores anything that would inflate a total.
Under-reporting for a few minutes is recoverable. Over-reporting silently corrupts
everything downstream.

Same shape of problem in item resolution ([Core.lua:182](Core.lua#L182)): match by
numeric ID, fall back to name — but **only for entries that have no ID yet**. Two
different items can share a display name across expansions, so name-matching an
already-identified item would both miscount and overwrite a correct ID.

### 2. Bill-of-materials math over a shared pool

The naive yield is wrong in a way that's easy to miss. Milling needs **10 of the same
herb**, so a color's pigment yield is `Σ floor(count_i / 10)` per herb — not
`floor(Σ count_i / 10)` ([Core.lua:824](Core.lua#L824)). 7+7+7+7+9 herbs yield 0
pigments; the naive formula claims 3.

On top of that, craft-vs-buy: one dye costs 10 units of a single herb, so
`craft_cost = 10 × herb_price` compared against the dye's own market price, per herb,
cheapest first ([Core.lua:916](Core.lua#L916)). The same verdict renders as a
check/X overlay inside the game's own ingredient picker
([Crafting.lua:129](Crafting.lua#L129)).

### 3. A price statistic that resists manipulation

Prices come from scraping the Auction House. The API is throttled and async: submit
one query, wait for a result event, check `IsThrottledMessageSystemReady()` before the
next. So the scanner is a queue-driven state machine advanced by several event types.

The statistic matters more than the plumbing. *Lowest listed price* is trivially
manipulable — one seller lists 1 unit at a nonsense price and every downstream
calculation is poisoned. Instead `ComputeMarketPrice`
([Core.lua:633](Core.lua#L633)) sorts cheapest-first, accumulates quantity, and
returns the price at which **200 units are cumulatively available** — the price of
the 200th-cheapest unit. A 5-unit spite listing can't reach that depth. If the whole
market is thinner than 200, it returns the dearest listing: what clearing it would
actually cost. Pure function, directly unit-tested.

### 4. An async state machine with no way to fail safely

The first version of that scanner was a pure event chain: send a query, wait for its
result event, send the next. It shipped, and it hung — reliably, after 8 to 12 items.

The cause is that Blizzard's rate limiter doesn't reject a query you send too fast,
it **drops it silently**. No results event, no error event, nothing. An event chain
with no timeout has no way to notice that; it just waits forever. 8–12 is roughly one
burst allowance. `IsThrottledMessageSystemReady()` exists but only tells you the
limiter's state *before* you send — it can't tell you the send you just made was the
one that tripped it.

The general lesson is that any state machine driven purely by callbacks from a system
you don't control needs an independent liveness source, because "the callback never
came" is invisible from inside the callback model. The fix adds three:

- **Pacing** — a floor on the gap between queries, on top of the throttle check.
- **A watchdog** — every dispatch bumps a generation counter and arms a timer against
  it. If the reply doesn't land, the timer retries the item, and after a few attempts
  skips it. The generation counter is what makes this safe: a reply that arrives
  after its watchdog fired is recognizably stale, so retry and reply can't both
  advance the scan and desynchronize the queue index.
- **Reply verification** — results carry the item they belong to, and one that isn't
  the in-flight query is discarded. Without this, a late answer to an abandoned query
  would be stored as whatever item happens to be current, silently mispricing it.

Failing loudly matters as much as recovering: a scan that skips items now says so,
because quietly pricing 40 of 60 leaves craft-vs-buy verdicts confidently wrong with
nothing on screen to explain why.

### 5. Depending on addons you don't ship

The real fix for a slow, throttled, AH-only scan is to not do it. Players who run
TradeSkillMaster or Auctionator already have a maintained price database, readable
instantly and anywhere. [Prices.lua](Prices.lua) turns the price feed into a small
registry of sources — `Ready()`, `GetPrice(entry)`, `instant` — ordered by
preference, with the built-in scan as the always-available fallback.

Three rules make depending on someone else's addon survivable:

- **Detect the API, not the addon.** `IsAddOnLoaded` returns true for an addon that
  is present but not yet initialized; calling into it then produces an error in
  *their* code with *your* name on it. Each source tests for the actual function it
  intends to call.
- **Every call is wrapped.** Auctionator's API deliberately raises on a bad caller ID
  or a non-number item ID. A price lookup must never be able to abort a scan, so the
  whole per-item call is `pcall`ed and a failure counts as "no price" — which is
  already a normal outcome.
- **A pinned source that vanishes falls back without being rewritten.** If someone
  selects TSM and later disables it, the addon uses the next best source but leaves
  the preference alone, so re-enabling TSM restores it instead of silently having
  been changed to something else.

Signatures were verified against each addon's own source rather than documentation
(both projects' doc sites were down): `Auctionator.API.v1.GetAuctionPriceByItemID`,
`TSM_API.GetCustomPriceValue` / `ToItemString`.

## Integrating with a moving target

`Crafting.lua` and `Housing.lua` decorate Blizzard's own frames — internal objects
that load on demand and change between patches. The house editor path is
`HouseEditorFrame.CustomizeModeFrame.DecorCustomizationsPane.dyeSlotFramesByChannel[ch].CurrentSwatch.dyeColorInfo`.

Strategy throughout: feature-detect every access, `pcall`-wrap every call, assume no
frame exists. Recipe rows match to dyes by parsing the item ID out of the row's own
hyperlink ([Crafting.lua:20](Crafting.lua#L20)) rather than trusting position or
display name. `hooksecurefunc` appends behavior without replacing anything. Comments
record the exact frame shapes observed and the date they were verified, so a future
break is diagnosable instead of mysterious.

One guard worth flagging: the craft verdict is tri-state (`true` / `false` / `nil` for
unknown), and the code avoids Lua's `and/or` ternary idiom because it collapses
`false` into `nil` — which would have silently made the red "not worth it" marker
never appear ([Crafting.lua:137-139](Crafting.lua#L137-L139)).

## Tests and build

The game client can't be scripted from CI, so
[tests/test_dyeingdownthehouse.lua](tests/test_dyeingdownthehouse.lua) is a stub
harness: a fake WoW API (bag containers, item cache, timers, event dispatch,
profession schematics), the real `Data.lua` and `Core.lua` loaded against it, a
synthetic dataset injected, **242 assertions** under LuaJIT. Covers herb-overlap
double-counting, the same-herb milling floor, market-depth pricing edge cases, the
monotonic-decrease invariant, color-family search, sort tie-breaking, and the "Core
survives with no UI" contract.

[tools/build.ps1](tools/build.ps1) takes the version from the manifest as the single
source of truth, refuses to package if tests fail, byte-compiles every shipped file
to catch syntax errors, strips marked debug blocks from the shipped copies only, and
emits `dist/DyeingDownTheHouse-0.1.0.zip` in the layout CurseForge expects.

## Summary

~2,500 lines of Lua embedded in a game client, solving a small but awkward data
problem: reconcile an eventually-consistent, multi-actor, partially-observable
inventory into account-wide totals; run bill-of-materials math over a many-to-many
resource graph with integer-batch constraints; scrape a throttled async marketplace
into a manipulation-resistant price statistic; surface it in its own UI and by
decorating a third party's undocumented, load-on-demand interface. No filesystem, no
network, no threads, one serialized table for persistence.
