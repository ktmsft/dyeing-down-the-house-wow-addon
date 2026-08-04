# Dyeing Down The House

Write it down without leaving the house.

You're hours deep into decorating. The wall wants a warmer green. You go to apply it —
you're out.

So off you go to fix that. And somewhere between the Dye Station, the auction house
and the bank alt, it's gone: *which* green was it? How many did you need? Two? Six?
And which of the fifteen flowers that mill into green is the cheap one this week?

Back to the house to check. Again.

Dyeing Down The House lets you write it down the second you notice — then remembers
it for you, prices it, and tells you the cheapest way to make it.

## 🏠 Note it down while you're standing right there

Select a dye on a piece of decor and a **Dye Needed** box appears in the panel, just
above the Cost line. Type how many you want. Done — you can go back to decorating.

No alt-tabbing to a spreadsheet, no "I'll remember." The number is captured at the
exact moment you know it.

## 📋 It remembers, so you don't have to

`/dye` opens the window. There are two ways to look at it, on two tabs.

**By Color Family** — ten tidy rows, one per color:

```
Color        Pigment   Flowers   Makeable   Short
▸ ■ Black          3       240         27       2
▸ ■ Blue           0        80          8
▸ ■ Brown          1       310         32       1
```

Because pigments and flowers belong to a **color**, not to a dye. Every black dye
mills from the same flowers and draws on the same pigment pile, so this is the view
that tells you what you can actually make. Open a color to see the flowers it mills
from — once, not repeated under every dye.

**By Dye** — the flat list, one row per dye, for when you care about a specific
one: what you have, what it costs to make, how many you still need.

"Own" means **everything** — every character's bags, every character's bank, and the
Warband bank, all totalled. That green you were sure you were out of might be sitting
on the alt you never play.

A green check appears next to a goal once you're covered, counting dyes you hold
*plus* pigment already sitting there ready to become more. No check, no worry.

## 💰 Then it tells you the cheapest way to make it

Dyes are Warband-bound — you can't buy one, so making it is the only route. But
there are fifteen flowers that mill into black, they're all still on the auction
house, and which one is cheapest changes week to week.

Hit **Scan** and every flower gets priced. The **Cost** column then shows what one
of each dye costs to make: ten of the cheapest flower of its color. Open a color and
you get every flower that mills into that family — how many you hold, how many dyes
that alone would make, and what going that route would cost. **Green on the cheapest
way in, red on a dearer one.** Cheapest first.

Hovering a color also tells you which of its flowers another family wants. Spending
them here is spending them there.

Already run **TradeSkillMaster** or **Auctionator**? Prices come straight out of
their database — instantly, anywhere in the world, no auction house trip required.
If you have neither, the built-in scan handles it at the AH. Pick whichever you like
in the options, or leave it on automatic and forget about it.

The prices are honest, too. It doesn't take the lowest buyout — one person listing a
single unit at a silly price would poison every verdict in the addon. It takes the
lowest price with real depth behind it, so a lone gouger can't move your numbers.

## 🪄 And it follows you to the crafting window

You've decided to craft. Open Dye Crafting and the addon is already there:

🟡 A yellow **!** on exactly the recipes you're short on — no scrolling the list
trying to remember which one it was.

📋 A **"You have 6 / need 10"** line under the recipe title, green once you get there.

✅ A green check or red X on every herb in the reagent picker: is *this* the cheapest
one to mill for *this* color, at today's prices? No more guessing which of fifteen
herbs is the cheap one.

All of it can be switched off if you'd rather it stayed out of the way.

## 🧮 Let the addon do the math

Ten of the *same* flower make a pigment. So forty flowers spread across four
different types make **zero** pigments, not four. The Flowers column knows the
difference — no hauling a bag of odds and ends to the mill for nothing.

Flowers that mill into two colors count toward both, because they genuinely can go
either way. Spending them on one just denies the other.

## 🔍 Find the one you meant

Can't remember what the green was called? Type `green` — you get the dyes literally
named "…Green…" **and** every dye in the green family, whatever it happens to be
called.

Sort by name, amount owned, goal, cost to make, or by how much of it you could make
right now.

## ⚙️ Configurable

Everything lives in one options panel. Pick your columns, show only the cheapest
flowers, lock the window, toggle the rainbow title.

Two collapsible checklists trim the list to what you care about: all 62 dyes grouped
by color with swatches, and every flower by name. Uncheck what you'll never make, and
scans stop wasting queries pricing it.

The window drags anywhere, resizes by the corner grip, remembers where you left it,
and collapses to a slim title bar if you'd rather tuck it away than close it.

## ⌨️ Commands

- `/dye` — toggle the window
- `/dye scan` — price the flowers
- `/dye source <auto|tsm|auctionator|blizzard>` — where prices come from
- `/dye search <text>` — filter by dye name or color family
- `/dye sort <alpha | price | owned>` — change the order (price = cost to craft)
- `/dye expand` · `/dye collapse` — open or close every color group
- `/dye hidezero` — hide dyes you have none of
- `/dye lock` · `/dye unlock` — freeze or free the window
- `/dye reset` — recenter the window
- `/dye options` — settings
- `/dye chars` — characters, and when each was last scanned
- `/dye forget <Name-Realm>` — drop a deleted character
- `/dye help` — the full list

`/dyes` and `/ddth` work too.

## 🌱 Optional: DataStore

Already run [DataStore](https://www.curseforge.com/wow/addons/datastore) and
DataStore_Containers? Dyes held by characters you haven't logged into this session
get counted too. Entirely optional — the addon works fine on its own.

## 📦 Install

Unzip into `World of Warcraft/_retail_/Interface/AddOns/`, make sure the folder is
named `DyeingDownTheHouse`, and restart. That's it, it works out of the box.

Midnight (12.0.7+). No libraries, no required dependencies.

---

KTM (abitofmoss) · MIT · bugs and suggestions welcome.
