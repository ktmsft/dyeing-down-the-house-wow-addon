-- Dyeing Down The House - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Data.lua — the dye, shade and herb tables.
--
-- Curse of Ula'tek (12.1) rebuilt the dye system, and this file was rebuilt with
-- it. What changed:
--
--   * Pigments are gone. There is no intermediate item any more.
--   * The 62 dye items became NINE, one per color family: "Blue Housing Dye" and
--     so on. Teal was retired, so the ten pigment colors become nine dyes.
--   * Crafting is one step. Take herbs to a Dye Station, be an alchemist or a
--     scribe, click it. There are no recipes in your crafting book at all.
--   * The 77 color NAMES (Alliance Blue, Dark Obsidium, Petal Pink) still exist,
--     but they are no longer items. Any Blue Housing Dye paints any blue shade,
--     which is the whole point of the change.
--
-- So there are now two different things that used to be one, and they are kept in
-- two tables. ns.DYES is the nine items you stock, count and set goals against.
-- ns.SHADES is the color names you can pick in the house, which cost a dye of
-- their family and are otherwise just a reference list.
--
-- The crafting chain:  HERBS -> DYE   (ns.HERBS_PER_DYE)
--
-- Everything is still grouped by COLOR: many herbs per color, one dye per color,
-- many shades per color. A herb can feed MORE THAN ONE color, which is why herbs
-- carry a list of colors rather than a single one — and why the flowers for a
-- color are a pool shared by every shade in that family.
--
-- ON UNVERIFIED DATA. The rule in this file has always been that an ID is read
-- from the game or it doesn't ship. Anything not yet confirmed is marked: item IDs
-- are left `nil`, and a shade whose family is an inference carries `guess = true`
-- so the UI can say so out loud.
--
-- MOST OF THAT IS NOW FILLED IN AT LOGIN. 12.1 ships C_DyeColor, which hands over
-- every shade's name and the dye item it costs, so Discover.lua reads the item IDs
-- and the shade -> family map straight from the client and clears the guess flags
-- as it goes. What is written below is the fallback, not the answer: it is what the
-- addon knows before the API replies, what the tests run against, and what keeps
-- the window populated if C_DyeColor is missing or renamed.
--
-- So DON'T hand-edit values here to match what the game reported. Discovery will
-- do it every session anyway, and a hand-copied ID is a second source of truth
-- that can drift. reference/12.1-verification.md tracks what genuinely remains.
--------------------------------------------------------------------------------

-- The nine dye colors. Order here is the default display order.
--
-- TEAL IS GONE. Blizzard retired the category outright: the shades that were teal
-- moved to blue or green, and Teal Dye Pigment converted to Blue Housing Dye.
ns.COLORS = {
	"black", "blue", "brown", "green", "orange",
	"purple", "red", "white", "yellow",
}

-- How many herbs one dye costs at the station.
--
-- CONFIRMED at a station on the 12.1 PTR (2026-08-10). Blizzard never stated a
-- ratio anywhere, so this was carried over from the old two-step chain -- 10 herbs
-- -> 1 pigment -> 1 dye -- on the reasoning that they described the change as
-- removing the middle step rather than repricing it. That reading turned out to be
-- right, but it was a reading until someone counted.
--
-- It stays a field rather than a magic number: every Makeable, Cost and
-- flowers-short figure in the addon is derived from it, so a balance change is a
-- one-line edit here instead of a hunt.
ns.HERBS_PER_DYE = ns.HERBS_PER_DYE or 10

-- The nine housing dye items. In game they are named "<Color> Housing Dye".
--
--   key    stable identifier — this is the COLOR key, because there is now exactly
--          one dye item per color. Goals, hidden flags and prices are keyed by it.
--   name   exact in-game name
--   id     retail item ID (number), or nil until read from the game
--   color  the color family, same string as the key
--
-- IDs ARE DELIBERATELY nil. Discover.lua fills them in at login from
-- C_DyeColor.GetDyeColorInfo, which reports the dye item each shade costs — so the
-- real IDs arrive from the client every session and never need to be written here.
--
-- `nil` is a fully supported state regardless: ResolveEntry in Core matches on the
-- item's exact name and learns the ID the first time one is seen in a bag, which is
-- the same path that has always covered an item Blizzard adds mid-patch. Between
-- the two, a colour counts whether or not the API answered.
ns.DYES = {
	{ key = "black",  name = "Black Housing Dye",  id = nil, color = "black" },
	{ key = "blue",   name = "Blue Housing Dye",   id = nil, color = "blue" },
	{ key = "brown",  name = "Brown Housing Dye",  id = nil, color = "brown" },
	{ key = "green",  name = "Green Housing Dye",  id = nil, color = "green" },
	{ key = "orange", name = "Orange Housing Dye", id = nil, color = "orange" },
	{ key = "purple", name = "Purple Housing Dye", id = nil, color = "purple" },
	{ key = "red",    name = "Red Housing Dye",    id = nil, color = "red" },
	{ key = "white",  name = "White Housing Dye",  id = nil, color = "white" },
	{ key = "yellow", name = "Yellow Housing Dye", id = nil, color = "yellow" },
}

-- Every shade you can paint a decor with: 62 that were items before 12.1, plus the
-- 15 added in Curse of Ula'tek. These are NOT items and have no count, no price and
-- no goal — a shade costs one dye of its family, and the family is what you stock.
-- They're here so the window can still answer "what can I actually paint with a
-- Blue Housing Dye", and so searching for a color name finds its family.
--
--   name   the color as it reads in the house customization panel (no "Dye" suffix)
--   color  the family whose dye it costs
--   guess  present and true when that family is INFERRED, not read from the game.
--          Discover.lua clears it the moment C_DyeColor confirms the placement, and
--          the window prints "family not confirmed" under any that are still set.
--          NOTHING CARRIES IT NOW. Every one of the 77 was read from C_DyeColor on
--          12.1 (10 August 2026). The field stays because a shade Blizzard adds
--          mid-patch arrives unplaced and wants somewhere honest to say so.
--
-- READ FROM THE GAME, and the reading moved sixteen of them.
--
-- Nine shipped as guesses and eight of those were right — including all four
-- ex-teal ones, so "teal split between blue and green" held exactly as written.
-- Note that it held HERE and failed for the herbs: the shades genuinely moved to
-- blue and green, while the herbs that used to feed teal did not follow them. Two
-- different questions that looked like one, which is most of why the herb map was
-- wrong for so long. Klaxxi Amber was the single bad guess — yellow, actually
-- orange.
--
-- THE OTHER SEVEN ARE THE INTERESTING ONES, because they were never guesses. They
-- came off the old dyes' pigments, the part of this file that was described as
-- solid, and they had been wrong since before 12.1:
--
--   Ironclaw       black  -> green      Vol'dun Taupe   brown  -> green
--   Stormsteel     black  -> blue       Holy Oak Tan    yellow -> white
--   Dusk Lily Grey blue   -> purple     Pinewood        yellow -> green
--   Dark Gold      brown  -> yellow
--
-- Read them and they are obvious in hindsight: pinewood IS green, and a taupe is
-- nearer green than brown. They read as safe because the name suggested a family
-- and the old data agreed, so nobody looked. Only the ones I had already flagged as
-- uncertain ever got checked — which is the failure worth remembering, because the
-- flag was doing the opposite of its job: it made everything unflagged look
-- verified.
ns.SHADES = {
	-- black
	{ name = "Dark Iron",           color = "black" },
	{ name = "Darkwood",            color = "black" },
	{ name = "Obsidium Black",      color = "black" },
	{ name = "Stormheim Grey",      color = "black" },
	{ name = "Dark Obsidium",       color = "black" }, -- 12.1: the pre-12.0.5 Obsidium Black
	-- blue
	{ name = "Alliance Blue",       color = "blue" },
	{ name = "Midnight Blue",       color = "blue" },
	{ name = "Nazjatar Navy",       color = "blue" },
	{ name = "Zephras Blue",        color = "blue" },
	{ name = "Stormsteel",          color = "blue" },                 -- was filed under black
	{ name = "Tranquility Blue",    color = "blue" },                 -- 12.1
	{ name = "Kul Tiran Steel",     color = "blue" },                 -- was teal
	{ name = "Tidesage Teal",       color = "blue" },                 -- was teal
	{ name = "Vortex Teal",         color = "blue" },                 -- was teal
	-- brown
	{ name = "Earthen Brown",       color = "brown" },
	{ name = "Heartwood",           color = "brown" },
	{ name = "Kalimdor Sand",       color = "brown" },
	{ name = "Mesquite Brown",      color = "brown" },
	{ name = "Pale Umber",          color = "brown" },
	{ name = "Timbermaw Brown",     color = "brown" },
	{ name = "Warm Teak",           color = "brown" },
	{ name = "Dark Mesquite",       color = "brown" }, -- 12.1: the pre-12.0.5 Mesquite Brown
	-- green
	{ name = "Dustwallow Green",    color = "green" },
	{ name = "Earthroot",           color = "green" },
	{ name = "Emerald Dreaming",    color = "green" },
	{ name = "Gravemoss Green",     color = "green" },
	{ name = "Grizzly Hills Green", color = "green" },
	{ name = "Lush Green",          color = "green" },
	{ name = "Silversage Green",    color = "green" },
	{ name = "Ironclaw",            color = "green" },                -- was filed under black
	{ name = "Vol'dun Taupe",       color = "green" },                -- was filed under brown
	{ name = "Pinewood",            color = "green" },                -- was filed under yellow
	{ name = "Amani Green",         color = "green" },                -- 12.1
	{ name = "Verdant Green",       color = "green" },                -- 12.1
	{ name = "Tirisfal Green",      color = "green" },                -- 12.1
	{ name = "Un'Goro Green",       color = "green" },                -- was teal
	-- orange
	{ name = "Bronze",              color = "orange" },
	{ name = "Copper",              color = "orange" },
	{ name = "Elwynn Pumpkin",      color = "orange" },
	{ name = "Kodohide Brown",      color = "orange" },
	{ name = "Foxflower Orange",    color = "orange" },               -- 12.1
	{ name = "Klaxxi Amber",        color = "orange" },               -- 12.1; guessed yellow
	-- purple
	{ name = "Arcwine",             color = "purple" },
	{ name = "Forsaken Plum",       color = "purple" },
	{ name = "Kirin Tor Violet",    color = "purple" },
	{ name = "Moonberry Amethyst",  color = "purple" },
	{ name = "Netherstorm Fuchsia", color = "purple" },
	{ name = "Nightsong Lilac",     color = "purple" },
	{ name = "Void Violet",         color = "purple" },
	{ name = "Dusk Lily Grey",      color = "purple" },               -- was filed under blue
	{ name = "Aethril Pink",        color = "purple" },               -- 12.1
	{ name = "Faded Mana",          color = "purple" },               -- 12.1
	-- red
	{ name = "Deep Mageroyal Red",  color = "red" },
	{ name = "Firebloom Red",       color = "red" },
	{ name = "Gilnean Rose",        color = "red" },
	{ name = "Hinterlands Hickory", color = "red" },
	{ name = "Horde Red",           color = "red" },
	{ name = "Mahogany",            color = "red" },
	{ name = "Rain Poppy Red",      color = "red" },
	{ name = "Ratchet Rust",        color = "red" },
	{ name = "Dusty Red",           color = "red" },                  -- 12.1
	{ name = "Dark Mahogany",       color = "red" },                  -- 12.1: the pre-12.0.5 Mahogany
	{ name = "Stonetalon Brick",    color = "red" },                  -- 12.1
	{ name = "Petal Pink",          color = "red" },                  -- 12.1; no pink family to put it in
	-- white
	{ name = "Basic Birch",         color = "white" },
	{ name = "Bone-White",          color = "white" },
	{ name = "Highborne Marble",    color = "white" },
	{ name = "Highland Birch",      color = "white" },
	{ name = "Holy Oak Tan",        color = "white" },                -- was filed under yellow
	{ name = "Pearl White",         color = "white" },                -- 12.1
	-- yellow
	{ name = "Brass",               color = "yellow" },
	{ name = "Gold",                color = "yellow" },
	{ name = "Sandfury Yellow",     color = "yellow" },
	{ name = "Savannah Gold",       color = "yellow" },
	{ name = "Sungrass Yellow",     color = "yellow" },
	{ name = "Zandalari Gold",      color = "yellow" },
	{ name = "Dark Gold",           color = "yellow" },               -- was filed under brown
}

-- Every herb. A herb turns into one or more colors' dyes at the station.
--
--   key     stable identifier
--   name    exact in-game name
--   id      retail item ID (number)
--   colors  list of color keys this herb makes dye for
--
-- Several herbs appear under more than one color (Writhebark feeds black, brown AND
-- orange), and several have one entry per quality tier sharing a name. Both are
-- deliberate: the tiers count separately because they're separate items, but they
-- hide together in the options, by name.
--
-- READ FROM THE GAME on 12.1 (10 August 2026), off the Dye Station's own recipes:
-- 17 flowers per color, except blue and green with 18. Discover.lua re-reads it at
-- every station visit, so this is the fallback rather than the answer — but it is
-- now a fallback that matches what the station said, which it did not before.
--
-- THE TEAL FOLD WAS WRONG, and it is worth saying how. The groupings were carried
-- over from the pigment each herb milled into pre-12.1, on the reasoning that
-- removing the middle step doesn't change which herbs are which color. That part
-- held: every color came back identical except two. What did not hold was the
-- exception bolted onto it — that every herb which fed teal now feeds BLUE,
-- because the teal pigment itself converted to Blue Housing Dye.
--
-- It doesn't. An ex-teal herb dropped teal and kept whatever else it had:
-- Lichbloom is black, Hochenblume is purple, Marrowroot is brown. Bruiseweed was
-- teal only, so the fold had nowhere to put it but blue, and the station says
-- green. Thirteen herbs in all, and blue was carrying every one of them — 31
-- flowers against the real 18, so Makeable had been claiming blue dyes that could
-- not be made.
--
-- The tell that convinced me was Tranquility Bloom: a teal/white herb, and 12.1's
-- new blue is called Tranquility Blue. It is white only. The names rhymed and the
-- inference was still wrong, which is the argument for reading the game rather
-- than reasoning about it — an item conversion said nothing about the herbs that
-- fed it, and one piece of corroboration made a guess feel like a finding.
ns.HERBS = {
	{ key = "adderstongue_36903",      name = "Adder's Tongue",      id = 36903, colors = { "brown", "green" } },
	{ key = "akundasbite_152507",      name = "Akunda's Bite",       id = 152507, colors = { "blue" } },
	{ key = "arathorsspear_210808",    name = "Arathor's Spear",     id = 210808, colors = { "red", "yellow" } },
	{ key = "arathorsspear_210809",    name = "Arathor's Spear",     id = 210809, colors = { "red", "yellow" } },
	{ key = "arathorsspear_210810",    name = "Arathor's Spear",     id = 210810, colors = { "red", "yellow" } },
	{ key = "argentleaf_236776",       name = "Argentleaf",          id = 236776, colors = { "blue", "purple" } },
	{ key = "argentleaf_236777",       name = "Argentleaf",          id = 236777, colors = { "blue", "purple" } },
	{ key = "azeroot_236774",          name = "Azeroot",             id = 236774, colors = { "black", "brown" } },
	{ key = "azeroot_236775",          name = "Azeroot",             id = 236775, colors = { "black", "brown" } },
	{ key = "azsharasveil_52985",      name = "Azshara's Veil",      id = 52985, colors = { "black", "green" } },
	{ key = "blessingblossom_210805",  name = "Blessing Blossom",    id = 210805, colors = { "black", "green" } },
	{ key = "blessingblossom_210806",  name = "Blessing Blossom",    id = 210806, colors = { "black", "green" } },
	{ key = "blessingblossom_210807",  name = "Blessing Blossom",    id = 210807, colors = { "black", "green" } },
	{ key = "briarthorn_2450",         name = "Briarthorn",          id = 2450, colors = { "brown" } },
	{ key = "bruiseweed_2453",         name = "Bruiseweed",          id = 2453, colors = { "green" } },
	{ key = "bubblepoppy_191467",      name = "Bubble Poppy",        id = 191467, colors = { "blue", "green" } },
	{ key = "bubblepoppy_191468",      name = "Bubble Poppy",        id = 191468, colors = { "blue", "green" } },
	{ key = "bubblepoppy_191469",      name = "Bubble Poppy",        id = 191469, colors = { "blue", "green" } },
	{ key = "cinderbloom_52983",       name = "Cinderbloom",         id = 52983, colors = { "brown", "red" } },
	{ key = "deathblossom_169701",     name = "Death Blossom",       id = 169701, colors = { "black", "blue" } },
	{ key = "desecratedherb_89639",    name = "Desecrated Herb",     id = 89639, colors = { "black", "brown" } },
	{ key = "dreamingglory_22786",     name = "Dreaming Glory",      id = 22786, colors = { "brown", "yellow" } },
	{ key = "dreamleaf_124102",        name = "Dreamleaf",           id = 124102, colors = { "blue", "green" } },
	{ key = "fadeleaf_3818",           name = "Fadeleaf",            id = 3818, colors = { "black" } },
	{ key = "felweed_22785",           name = "Felweed",             id = 22785, colors = { "black", "green" } },
	{ key = "fjarnskaggl_124104",      name = "Fjarnskaggl",         id = 124104, colors = { "white", "yellow" } },
	{ key = "foxflower_124103",        name = "Foxflower",           id = 124103, colors = { "brown", "orange" } },
	{ key = "frostweed_109124",        name = "Frostweed",           id = 109124, colors = { "blue" } },
	{ key = "goldclover_36901",        name = "Goldclover",          id = 36901, colors = { "orange", "yellow" } },
	{ key = "goldensansam_13464",      name = "Golden Sansam",       id = 13464, colors = { "orange" } },
	{ key = "gorgrondflytrap_109126",  name = "Gorgrond Flytrap",    id = 109126, colors = { "brown", "yellow" } },
	{ key = "greentealeaf_72234",      name = "Green Tea Leaf",      id = 72234, colors = { "green", "yellow" } },
	{ key = "icethorn_36906",          name = "Icethorn",            id = 36906, colors = { "blue", "white" } },
	{ key = "kingsblood_3356",         name = "Kingsblood",          id = 3356, colors = { "purple" } },
	{ key = "lichbloom_36905",         name = "Lichbloom",           id = 36905, colors = { "black" } },
	{ key = "luredrop_210799",         name = "Luredrop",            id = 210799, colors = { "blue", "orange" } },
	{ key = "luredrop_210800",         name = "Luredrop",            id = 210800, colors = { "blue", "orange" } },
	{ key = "luredrop_210801",         name = "Luredrop",            id = 210801, colors = { "blue", "orange" } },
	{ key = "mageroyal_785",           name = "Mageroyal",           id = 785, colors = { "red" } },
	{ key = "manalily_236778",         name = "Mana Lily",           id = 236778, colors = { "red", "yellow" } },
	{ key = "manalily_236779",         name = "Mana Lily",           id = 236779, colors = { "red", "yellow" } },
	{ key = "marrowroot_168589",       name = "Marrowroot",          id = 168589, colors = { "brown" } },
	{ key = "mycobloom_210796",        name = "Mycobloom",           id = 210796, colors = { "brown", "white" } },
	{ key = "mycobloom_210797",        name = "Mycobloom",           id = 210797, colors = { "brown", "white" } },
	{ key = "mycobloom_210798",        name = "Mycobloom",           id = 210798, colors = { "brown", "white" } },
	{ key = "nagrandarrowbloom_109128", name = "Nagrand Arrowbloom",  id = 109128, colors = { "black", "green" } },
	{ key = "orbinid_210802",          name = "Orbinid",             id = 210802, colors = { "purple" } },
	{ key = "orbinid_210803",          name = "Orbinid",             id = 210803, colors = { "purple" } },
	{ key = "orbinid_210804",          name = "Orbinid",             id = 210804, colors = { "purple" } },
	{ key = "peacebloom_2447",         name = "Peacebloom",          id = 2447, colors = { "white" } },
	{ key = "risingglory_168586",      name = "Rising Glory",        id = 168586, colors = { "white", "yellow" } },
	{ key = "riverbud_152505",         name = "Riverbud",            id = 152505, colors = { "black", "green" } },
	{ key = "saxifrage_191464",        name = "Saxifrage",           id = 191464, colors = { "red", "white", "yellow" } },
	{ key = "saxifrage_191465",        name = "Saxifrage",           id = 191465, colors = { "red", "white", "yellow" } },
	{ key = "saxifrage_191466",        name = "Saxifrage",           id = 191466, colors = { "red", "white", "yellow" } },
	{ key = "seastalk_152511",         name = "Sea Stalk",           id = 152511, colors = { "brown", "yellow" } },
	{ key = "silkweed_72235",          name = "Silkweed",            id = 72235, colors = { "blue" } },
	{ key = "silverleaf_765",          name = "Silverleaf",          id = 765, colors = { "blue" } },
	{ key = "stormvine_52984",         name = "Stormvine",           id = 52984, colors = { "blue" } },
	{ key = "sungrass_8838",           name = "Sungrass",            id = 8838, colors = { "yellow" } },
	{ key = "swiftthistle_2452",       name = "Swiftthistle",        id = 2452, colors = { "green" } },
	{ key = "terocone_22789",          name = "Terocone",            id = 22789, colors = { "blue" } },
	{ key = "whiptail_52988",          name = "Whiptail",            id = 52988, colors = { "white", "yellow" } },
	{ key = "writhebark_191470",       name = "Writhebark",          id = 191470, colors = { "black", "brown", "orange" } },
	{ key = "writhebark_191471",       name = "Writhebark",          id = 191471, colors = { "black", "brown", "orange" } },
	{ key = "writhebark_191472",       name = "Writhebark",          id = 191472, colors = { "black", "brown", "orange" } },
	{ key = "yserallineseed_128304",   name = "Yseralline Seed",     id = 128304, colors = { "black" } },
	{ key = "herb_109125", name = "Fireweed", id = 109125, colors = { "orange", "red" } },
	{ key = "herb_109127", name = "Starflower", id = 109127, colors = { "blue" } },
	{ key = "herb_109129", name = "Talador Orchid", id = 109129, colors = { "purple", "white" } },
	{ key = "herb_124101", name = "Aethril", id = 124101, colors = { "purple" } },
	{ key = "herb_151565", name = "Astral Glory", id = 151565, colors = { "red" } },
	{ key = "herb_152506", name = "Star Moss", id = 152506, colors = { "red" } },
	{ key = "herb_152508", name = "Winter's Kiss", id = 152508, colors = { "white" } },
	{ key = "herb_152509", name = "Siren's Pollen", id = 152509, colors = { "orange" } },
	{ key = "herb_168487", name = "Zin'anthid", id = 168487, colors = { "purple" } },
	{ key = "herb_168583", name = "Widowbloom", id = 168583, colors = { "orange", "red" } },
	{ key = "herb_170554", name = "Vigil's Torch", id = 170554, colors = { "green", "purple" } },
	{ key = "herb_191460", name = "Hochenblume", id = 191460, colors = { "purple" } },
	{ key = "herb_191461", name = "Hochenblume", id = 191461, colors = { "purple" } },
	{ key = "herb_191462", name = "Hochenblume", id = 191462, colors = { "purple" } },
	{ key = "herb_22787", name = "Ragveil", id = 22787, colors = { "white" } },
	{ key = "herb_22791", name = "Netherbloom", id = 22791, colors = { "red" } },
	{ key = "herb_22792", name = "Nightmare Vine", id = 22792, colors = { "orange" } },
	{ key = "herb_22793", name = "Mana Thistle", id = 22793, colors = { "purple" } },
	{ key = "herb_236761", name = "Tranquility Bloom", id = 236761, colors = { "white" } },
	{ key = "herb_236767", name = "Tranquility Bloom", id = 236767, colors = { "white" } },
	{ key = "herb_236770", name = "Sanguithorn", id = 236770, colors = { "green", "orange" } },
	{ key = "herb_236771", name = "Sanguithorn", id = 236771, colors = { "green", "orange" } },
	{ key = "herb_36904", name = "Tiger Lily", id = 36904, colors = { "red" } },
	{ key = "herb_36907", name = "Talandra's Rose", id = 36907, colors = { "purple" } },
	{ key = "herb_52986", name = "Heartblossom", id = 52986, colors = { "orange" } },
	{ key = "herb_52987", name = "Twilight Jasmine", id = 52987, colors = { "purple" } },
	{ key = "herb_72237", name = "Rain Poppy", id = 72237, colors = { "orange", "red" } },
	{ key = "herb_79010", name = "Snow Lily", id = 79010, colors = { "white" } },
	{ key = "herb_79011", name = "Fool's Cap", id = 79011, colors = { "purple" } },
}

-- Shade record ID -> its entry in ns.SHADES, for reading a dye straight off the
-- house panel.
--
-- DELIBERATELY EMPTY. 12.1's dyeSlotInfo is all IDs and no names — { ID, channel,
-- dyeColorCategoryID, dyeColorID, orderIndex } — so an unpainted slot tells you
-- nothing a name lookup can use, and `dyeColorID` is the only handle on which
-- shade is actually applied. Those record IDs are not published and have not been
-- read from the game yet, so there is nothing honest to put here.
--
-- Housing.lua consults this first and falls through to matching on the shade's
-- NAME when it comes up empty, which is why the panel still works without it. Fill
-- it in from `/dye probe api` (the Enum and C_ namespace behind the dye system)
-- rather than by pairing numbers up with colours that look about right.
ns.SHADE_BY_COLORID = {}
