# Dyeing Down The House

You're hours deep into decorating. The Square Woolen Rug wants a warmer green — and
when you go to apply it, you're out.

So off you go to fix that. And somewhere between the Dye Station, the auction house
and the bank alt, you get lost... how many did you need? Two? Six? And which of the
fifteen flowers that make green is the cheap one this week?

Back to the house to check. Again.

Dyeing Down The House lets you write it down the second you notice — then remembers
it for you, prices it, and tells you the cheapest way to make it.

## 🏠 Note it down in your house while you're decorating

Select a dye on a piece of decor and a **Dye Needed** box appears in the default panel, just
above the Cost line. Type how many you want. Done — you can go back to decorating.

No alt-tabbing to a spreadsheet, no "I'll remember." The number is captured at the
exact moment you know it.

## 📋 It remembers, so you don't have to

`/dye` opens the window on two tabs.

**By Color** — nine rows, one per color, because nine dyes is what the game has
now:

```
Color       Have   Flowers   Makeable   Cost      Dye Needed
▸ ■ Black     27       240         24   ~41g/ea      30
▸ ■ Blue       8        80          8   ~12g/ea
▸ ■ Brown     32       310         31   ~28g/ea      35
```

Open a color and you get two things: the flowers it's made from, cheapest first, and
every shade that color paints — all 77 of them, so you can see at a glance that one
Blue Housing Dye covers Alliance Blue, Midnight Blue, Tranquility Blue and the rest.

**By Dye** — the 77 color names, one row each, and this is where you say what you
want. Five Alliance Blue for the wall, three Midnight Blue for the trim. What that
*costs* is eight Blue Housing Dye, and the By Color tab has already worked it out.
You type the number in one place and read the total in the other, so the two can
never drift apart.

"Have" means **everything** — every character's bags, every character's bank, and the
Warband bank, all totalled. That green you were sure you were out of might be sitting
on the alt you never play.

A green check appears next to a goal once you actually hold that many. Flowers that
could still become dyes don't tick it off early — you haven't made them yet. Whether
your stock *can* close the gap is what the Makeable column is for.

## 💰 Then it tells you the cheapest way to make it

Dyes are Warband-bound, so you can't buy one and making it is the only route. But
there are fifteen flowers that make black, they're all still on the auction house,
and which one is cheapest changes week to week.

Hit **Scan** and every flower gets priced. The **Cost** column then shows what one
dye of that color costs to make: ten of its cheapest flower. Open a color and you
get every flower that makes it — how many you hold, how many dyes that alone would
make, and what going that route would cost. **Green on the cheapest way in, red on a
dearer one.** Cheapest first.

Already run **TradeSkillMaster** or **Auctionator**? Prices come straight out of
their database — instantly, anywhere in the world, no auction house trip required.
If you have neither, the built-in scan handles it at the AH. Pick whichever you like
in the options, or leave it on automatic and forget about it.

The prices are honest, too. It doesn't take the lowest buyout — one person listing a
single unit at a silly price would poison every verdict in the addon. It takes the
lowest price with real depth behind it, so a lone gouger can't move your numbers.

## 🪄 And it follows you to the dye station

Standing at a station, the addon is already there:

🟡 A marker on any color you're short of, so the ones worth making stand out in
the game's own list.

📋 A **"You have 6 / need 10"** line under the recipe title, green once you get there.

🌿 **Which flower to use** — "Use Silverleaf — 24 held, makes 2". Ten of one flower
makes a dye and a color has up to fifteen that will do it, so this is the only part
of the decision the window leaves to you. It answers from what's in your bags, so it
works before you've ever scanned a price; once you have, it names the cheapest.

All of it can be switched off if you'd rather it stayed out of the way.

## 🧮 Let the addon do the math

Ten of the *same* flower make a dye. So forty flowers spread across four different
types make **zero** dyes, not four. The Flowers column knows the difference — no
hauling a bag of odds and ends to the station for nothing.

Flowers that make two colors count toward both, because they genuinely can go either
way. Spending them on one just denies the other, and hovering a color says which of
its flowers another one wants.

## 🔍 Find the one you meant

Can't remember what the green was called? Type `obsidium` and you land on Black,
with Dark Obsidium and Obsidium Black pulled to the top of the row. The search reads
all 77 shade names, not just the nine items — which is the point, because the shade
name is the thing you actually had in mind.

Sort by name, amount held, goal, cost to make, how much you could make right now, or
how far off your goal you are.

## ⚙️ Configurable

Everything lives in one options panel. Pick your columns, show only the cheapest
flowers, lock the window, toggle the rainbow title, and set how see-through the
window is if you'd rather look at the house through it.

Two collapsible checklists trim the list to what you care about: the nine colors
with swatches and a count of the shades each one paints, and every flower by name.
Uncheck what you'll never make, and scans stop wasting queries pricing it.

The window drags anywhere, resizes by the corner grip, remembers where you left it,
and collapses to a slim title bar if you'd rather tuck it away than close it.

## ⌨️ Commands

- `/dye` — toggle the window
- `/dye scan` — price the flowers
- `/dye source <auto|tsm|auctionator|blizzard>` — where prices come from
- `/dye search <text>` — filter by color, or by a shade name like "obsidium"
- `/dye sort <alpha | price | owned>` — change the order (price = cost to make)
- `/dye tab <color | dye>` — switch tabs
- `/dye expand` · `/dye collapse` — open or close every color
- `/dye hidezero` — hide colors you have no dye of
- `/dye lock` · `/dye unlock` — freeze or free the window
- `/dye reset` — recenter the window
- `/dye options` — settings
- `/dye chars` — characters, and when each was last scanned
- `/dye forget <Name-Realm>` — drop a deleted character
- `/dye help` — the full list

`/dyes` and `/ddth` work too.

## 🌱 Plays nicely with what you already run

None of these are required. If you happen to have them, they make it better.

💰 **[TradeSkillMaster](https://www.curseforge.com/wow/addons/tradeskill-master)** or
**[Auctionator](https://www.curseforge.com/wow/addons/auctionator)** — prices come
straight from their database instead of scanning: instant, anywhere in the world, no
auction house trip. Have both? Pick one in the options or with `/dye source`. Leave it
on automatic and it just uses whichever you've got.

🎒 **[DataStore](https://www.curseforge.com/wow/addons/datastore)** +
DataStore_Containers — dyes held by characters you haven't logged into this session
get counted too.

Without any of them the addon still does everything: it scans the auction house
itself, and counts every character it has seen.

## 📦 Install

Unzip into `World of Warcraft/_retail_/Interface/AddOns/`, make sure the folder is
named `DyeingDownTheHouse`, and restart. That's it, it works out of the box.

**Curse of Ula'tek (12.1) and up.** That patch rebuilt the dye system from the
ground up — pigments removed, 62 dye items down to nine, crafting in one step at the
station — so 2.0 is built for it and won't read a 12.0.7 client correctly. Stay on
1.3.0 until Curse of Ula'tek goes live.

No libraries, no required dependencies.

---

KTM (abitofmoss) · All Rights Reserved · bugs and suggestions welcome.
