# Housing pigment & dye reference

Source: community "WoW Housing – Pigment and Dye Chart v2.0" by Kido EU
(Holt-DieAldor / Aholt-ArgentDawn), plus the in-game Housing Dye Pigment craft list.
This file is the human-readable spec that `Data.lua` is filled from. Nothing here
is baked into the addon until the item IDs are sourced and the mapping verified —
the addon never guesses IDs.

## Conversion

    10 herbs  ->  1 pigment  ->  1 dye

- Milling herbs into pigment requires **Alchemy or Inscription**.
- The **Dye Station** (found in the Neighbourhood) converts pigment -> dye and
  also requires Alchemy or Inscription.

Encoded as `ns.HERBS_PER_PIGMENT = 10`, `ns.PIGMENTS_PER_DYE = 1` in Core.lua.

## Colours (10)

    black  blue  brown  green  orange  purple  red  teal  white  yellow

## Pigments — CONFIRMED from the in-game craft list

One pigment per colour, named `<Colour> Dye Pigment`:

Item IDs harvested in-game 2026-07-20 via `/ddth harvest`:

| colour | pigment name        | item ID |
|--------|---------------------|---------|
| black  | Black Dye Pigment   | 262639  |
| blue   | Blue Dye Pigment    | 262643  |
| brown  | Brown Dye Pigment   | 262642  |
| green  | Green Dye Pigment   | 262647  |
| orange | Orange Dye Pigment  | 262656  |
| purple | Purple Dye Pigment  | 262625  |
| red    | Red Dye Pigment     | 262655  |
| teal   | Teal Dye Pigment    | 262628  |
| white  | White Dye Pigment   | 260947  |
| yellow | Yellow Dye Pigment  | 262648  |

(White at 260947 sits apart from the 2626xx cluster the others share — noted, not a
typo; confirmed identical across two harvest passes.)

## Herbs — DRAFT, NEEDS VERIFICATION

The chart lists, per colour, one herb per expansion. Crucially, several herbs
appear under MORE THAN ONE colour (e.g. Death Blossom under black/blue/brown,
Cinderbloom under brown/red/teal, Silkweed under blue/teal). Those overlaps are
the whole point of the cross-colour planner, so they must be exactly right.

Rather than risk transcribing ~120 cells from an image, the herb->colour mapping,
the dye list, and every item ID are best sourced authoritatively from the game's
own profession/recipe API (see the open question in chat). Once that lands it gets
written here as the source of truth, then into `Data.lua`.

## Dyes — from the chart (names to verify, IDs TODO)

Grouped by colour, roughly darkest→lightest as drawn:

- **black:** Dark Iron, Darkwood, Ironclaw, Obsidium Black, Stormheim Grey, Stormsteel
- **blue:** Alliance Blue, Dusk Lily Grey, Midnight Blue, Nazjatar Navy, Zephras Blue
- **brown:** Dark Gold, Earthen Brown, Heartwood, Kalimdor Sand, Mesquite Brown,
  Pale Umber, Timbermaw Brown, Vol'dun Taupe, Warm Teak
- **green:** Dustwallow Green, Earthroot, Emerald Dreaming, Gravemoss Green,
  Grizzly Hills Green, Lush Green, Silversage Green
- **orange:** Bronze, Copper, Elwynn Pumpkin, Koboldhide Brown
- **purple:** Arcwine, Forsaken Plum, Kirin Tor Violet, Moonberry Amethyst,
  Netherstorm Fuchsia, Nightsong Lilac, Void Violet
- **red:** Deep Mageroyal Red, Firebloom Red, Gilnean Rose, Hinterlands Hickory,
  Horde Red, Mahogany, Rain Poppy Red, Ratchet Rust
- **teal:** Kul Tiran Steel, Tidesage Teal, Un'goro Green, Vortex Teal
- **white:** Basic Birch, Bone-White, Highborne Marble, Highland Birch
- **yellow:** Brass, Gold, Holy Oak Tan, Pinewood, Sandfury Yellow, Savannah Gold,
  Sungrass Yellow, Zandalari Gold

(Some entries — e.g. "Koboldhide Brown" under orange, "Un'goro Green" under teal,
"Hinterlands Hickory" under red — read oddly against their colour column and are
flagged for verification against the game data.)
