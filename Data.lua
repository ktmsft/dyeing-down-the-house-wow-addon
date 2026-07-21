local ADDON, ns = ...

--------------------------------------------------------------------------------
-- !!! PLACEHOLDER DATA — NOT REAL GAME IDs !!!
--
-- These tables are intentionally EMPTY. The real dye/herb/pigment names and item
-- IDs must come from the player — this addon never guesses item IDs (a wrong ID
-- both mis-counts and can overwrite a real one when two items share a name).
--
-- The schema below is what the pure-logic code and tests are written against.
-- Names known from the community chart + the in-game pigment list are recorded in
-- reference/pigment-dye-chart.md; they get baked in here once verified and once
-- item IDs exist.
--
-- The crafting chain, from the chart:  10 HERBS -> 1 PIGMENT -> 1 DYE
-- (milling herbs -> pigment needs Alchemy/Inscription; the Dye Station, found in
-- the Neighbourhood, converts pigment -> dye and also needs Alchemy/Inscription.)
-- Everything is grouped by COLOUR: one pigment per colour, many herbs per colour,
-- many dyes per colour. A herb can feed MORE THAN ONE colour (the chart's
-- overlaps), which is why herbs carry a list of colours.
--------------------------------------------------------------------------------

-- The ten dye colours. Order here is the default display order.
ns.COLORS = {
	"black", "blue", "brown", "green", "orange",
	"purple", "red", "teal", "white", "yellow",
}

-- One pigment per colour. In game they are named "<Colour> Dye Pigment"
-- (e.g. "Black Dye Pigment").
--
--   key    stable identifier — NEVER change; referenced by colour
--   name   exact in-game name
--   id     retail item ID (number)
--   color  which colour bucket it belongs to
--
-- Names CONFIRMED from the in-game craft list; IDs resolved in-game from those
-- names (2026-07-20). Six IDs were double-confirmed across two passes; the other
-- four resolved once the pigments were crafted/owned (recipe-book visibility alone
-- doesn't cache an item for the name->id lookup).
ns.PIGMENTS = {
	{ key = "black_pigment",  name = "Black Dye Pigment",  id = 262639, color = "black" },
	{ key = "blue_pigment",   name = "Blue Dye Pigment",   id = 262643, color = "blue" },
	{ key = "brown_pigment",  name = "Brown Dye Pigment",  id = 262642, color = "brown" },
	{ key = "green_pigment",  name = "Green Dye Pigment",  id = 262647, color = "green" },
	{ key = "orange_pigment", name = "Orange Dye Pigment", id = 262656, color = "orange" },
	{ key = "purple_pigment", name = "Purple Dye Pigment", id = 262625, color = "purple" },
	{ key = "red_pigment",    name = "Red Dye Pigment",    id = 262655, color = "red" },
	{ key = "teal_pigment",   name = "Teal Dye Pigment",   id = 262628, color = "teal" },
	{ key = "white_pigment",  name = "White Dye Pigment",  id = 260947, color = "white" },
	{ key = "yellow_pigment", name = "Yellow Dye Pigment", id = 262648, color = "yellow" },
}

-- Every herb. A herb mills into one or more colours' pigments.
--
--   key     stable identifier
--   name    exact in-game name
--   id      retail item ID (number)
--   colors  list of colour keys this herb mills into (the chart's columns it sits in)
--   expac   expansion label, tooltip only
--
-- Example shape (fake id, overlapping herb):
--   { key = "deathblossom", name = "Death Blossom", id = 000101,
--     colors = { "black", "blue", "brown" }, expac = "Shadowlands" },
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
	{ key = "bruiseweed_2453",         name = "Bruiseweed",          id = 2453, colors = { "teal" } },
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
	{ key = "lichbloom_36905",         name = "Lichbloom",           id = 36905, colors = { "black", "teal" } },
	{ key = "luredrop_210799",         name = "Luredrop",            id = 210799, colors = { "blue", "orange" } },
	{ key = "luredrop_210800",         name = "Luredrop",            id = 210800, colors = { "blue", "orange" } },
	{ key = "luredrop_210801",         name = "Luredrop",            id = 210801, colors = { "blue", "orange" } },
	{ key = "mageroyal_785",           name = "Mageroyal",           id = 785, colors = { "red" } },
	{ key = "manalily_236778",         name = "Mana Lily",           id = 236778, colors = { "red", "yellow" } },
	{ key = "manalily_236779",         name = "Mana Lily",           id = 236779, colors = { "red", "yellow" } },
	{ key = "marrowroot_168589",       name = "Marrowroot",          id = 168589, colors = { "brown", "teal" } },
	{ key = "mycobloom_210796",        name = "Mycobloom",           id = 210796, colors = { "brown", "white" } },
	{ key = "mycobloom_210797",        name = "Mycobloom",           id = 210797, colors = { "brown", "white" } },
	{ key = "mycobloom_210798",        name = "Mycobloom",           id = 210798, colors = { "brown", "white" } },
	{ key = "nagrandarrowbloom_109128", name = "Nagrand Arrowbloom",  id = 109128, colors = { "black", "green" } },
	{ key = "orbinid_210802",          name = "Orbinid",             id = 210802, colors = { "purple", "teal" } },
	{ key = "orbinid_210803",          name = "Orbinid",             id = 210803, colors = { "purple", "teal" } },
	{ key = "orbinid_210804",          name = "Orbinid",             id = 210804, colors = { "purple", "teal" } },
	{ key = "peacebloom_2447",         name = "Peacebloom",          id = 2447, colors = { "white" } },
	{ key = "risingglory_168586",      name = "Rising Glory",        id = 168586, colors = { "white", "yellow" } },
	{ key = "riverbud_152505",         name = "Riverbud",            id = 152505, colors = { "black", "green" } },
	{ key = "saxifrage_191464",        name = "Saxifrage",           id = 191464, colors = { "red", "white", "yellow" } },
	{ key = "saxifrage_191465",        name = "Saxifrage",           id = 191465, colors = { "red", "white", "yellow" } },
	{ key = "saxifrage_191466",        name = "Saxifrage",           id = 191466, colors = { "red", "white", "yellow" } },
	{ key = "seastalk_152511",         name = "Sea Stalk",           id = 152511, colors = { "brown", "yellow" } },
	{ key = "silkweed_72235",          name = "Silkweed",            id = 72235, colors = { "blue", "teal" } },
	{ key = "silverleaf_765",          name = "Silverleaf",          id = 765, colors = { "blue" } },
	{ key = "stormvine_52984",         name = "Stormvine",           id = 52984, colors = { "blue", "teal" } },
	{ key = "sungrass_8838",           name = "Sungrass",            id = 8838, colors = { "yellow" } },
	{ key = "swiftthistle_2452",       name = "Swiftthistle",        id = 2452, colors = { "green" } },
	{ key = "terocone_22789",          name = "Terocone",            id = 22789, colors = { "blue", "teal" } },
	{ key = "whiptail_52988",          name = "Whiptail",            id = 52988, colors = { "white", "yellow" } },
	{ key = "writhebark_191470",       name = "Writhebark",          id = 191470, colors = { "black", "brown", "orange" } },
	{ key = "writhebark_191471",       name = "Writhebark",          id = 191471, colors = { "black", "brown", "orange" } },
	{ key = "writhebark_191472",       name = "Writhebark",          id = 191472, colors = { "black", "brown", "orange" } },
	{ key = "yserallineseed_128304",   name = "Yseralline Seed",     id = 128304, colors = { "black", "teal" } },
	{ key = "herb_109125", name = "Fireweed", id = 109125, colors = { "orange", "red" } },
	{ key = "herb_109127", name = "Starflower", id = 109127, colors = { "teal" } },
	{ key = "herb_109129", name = "Talador Orchid", id = 109129, colors = { "purple", "white" } },
	{ key = "herb_124101", name = "Aethril", id = 124101, colors = { "purple" } },
	{ key = "herb_151565", name = "Astral Glory", id = 151565, colors = { "red" } },
	{ key = "herb_152506", name = "Star Moss", id = 152506, colors = { "red" } },
	{ key = "herb_152508", name = "Winter's Kiss", id = 152508, colors = { "white" } },
	{ key = "herb_152509", name = "Siren's Pollen", id = 152509, colors = { "orange", "teal" } },
	{ key = "herb_168487", name = "Zin'anthid", id = 168487, colors = { "purple" } },
	{ key = "herb_168583", name = "Widowbloom", id = 168583, colors = { "orange", "red" } },
	{ key = "herb_170554", name = "Vigil's Torch", id = 170554, colors = { "green", "purple" } },
	{ key = "herb_191460", name = "Hochenblume", id = 191460, colors = { "purple", "teal" } },
	{ key = "herb_191461", name = "Hochenblume", id = 191461, colors = { "purple", "teal" } },
	{ key = "herb_191462", name = "Hochenblume", id = 191462, colors = { "purple", "teal" } },
	{ key = "herb_22787", name = "Ragveil", id = 22787, colors = { "white" } },
	{ key = "herb_22791", name = "Netherbloom", id = 22791, colors = { "red" } },
	{ key = "herb_22792", name = "Nightmare Vine", id = 22792, colors = { "orange" } },
	{ key = "herb_22793", name = "Mana Thistle", id = 22793, colors = { "purple" } },
	{ key = "herb_236761", name = "Tranquility Bloom", id = 236761, colors = { "teal", "white" } },
	{ key = "herb_236767", name = "Tranquility Bloom", id = 236767, colors = { "teal", "white" } },
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

-- Every dye. Each dye is made from one pigment of its colour.
--
--   key    stable identifier — referenced by goals and saved variables
--   name   exact in-game name
--   id     retail item ID (number)
--   color  the dye's colour (selects its pigment)
--
-- Sourced authoritatively from the "Dye Crafting" profession recipes, read in-game
-- (2026-07-20): every dye's ID is the recipe output, and its colour is read from the
-- pigment the recipe consumes — nothing guessed. 62 dyes.
ns.DYES = {
	-- black
	{ key = "darkiron",           name = "Dark Iron Dye",           id = 259109, color = "black" },
	{ key = "darkwood",           name = "Darkwood Dye",            id = 259098, color = "black" },
	{ key = "ironclaw",           name = "Ironclaw Dye",            id = 259111, color = "black" },
	{ key = "obsidiumblack",      name = "Obsidium Black Dye",      id = 259121, color = "black" },
	{ key = "stormheimgrey",      name = "Stormheim Grey Dye",      id = 259123, color = "black" },
	{ key = "stormsteel",         name = "Stormsteel Dye",          id = 259104, color = "black" },
	-- blue
	{ key = "allianceblue",       name = "Alliance Blue Dye",       id = 259115, color = "blue" },
	{ key = "dusklilygrey",       name = "Dusk Lily Grey Dye",      id = 259153, color = "blue" },
	{ key = "midnightblue",       name = "Midnight Blue Dye",       id = 259135, color = "blue" },
	{ key = "nazjatarnavy",       name = "Nazjatar Navy Dye",       id = 259146, color = "blue" },
	{ key = "zephrasblue",        name = "Zephras Blue Dye",        id = 259129, color = "blue" },
	-- brown
	{ key = "darkgold",           name = "Dark Gold Dye",           id = 259112, color = "brown" },
	{ key = "earthenbrown",       name = "Earthen Brown Dye",       id = 259122, color = "brown" },
	{ key = "heartwood",          name = "Heartwood Dye",           id = 259103, color = "brown" },
	{ key = "kalimdorsand",       name = "Kalimdor Sand Dye",       id = 259128, color = "brown" },
	{ key = "mesquitebrown",      name = "Mesquite Brown Dye",      id = 259096, color = "brown" },
	{ key = "paleumber",          name = "Pale Umber Dye",          id = 259101, color = "brown" },
	{ key = "timbermawbrown",     name = "Timbermaw Brown Dye",     id = 259145, color = "brown" },
	{ key = "volduntaupe",        name = "Vol'dun Taupe Dye",       id = 259141, color = "brown" },
	{ key = "warmteak",           name = "Warm Teak Dye",           id = 259053, color = "brown" },
	-- green
	{ key = "dustwallowgreen",    name = "Dustwallow Green Dye",    id = 259133, color = "green" },
	{ key = "earthroot",          name = "Earthroot Dye",           id = 259150, color = "green" },
	{ key = "emeralddreaming",    name = "Emerald Dreaming Dye",    id = 259134, color = "green" },
	{ key = "gravemossgreen",     name = "Gravemoss Green Dye",     id = 259143, color = "green" },
	{ key = "grizzlyhillsgreen",  name = "Grizzly Hills Green Dye", id = 259147, color = "green" },
	{ key = "lushgreen",          name = "Lush Green Dye",          id = 259114, color = "green" },
	{ key = "silversagegreen",    name = "Silversage Green Dye",    id = 259124, color = "green" },
	-- orange
	{ key = "bronze",             name = "Bronze Dye",              id = 259108, color = "orange" },
	{ key = "copper",             name = "Copper Dye",              id = 259105, color = "orange" },
	{ key = "elwynnpumpkin",      name = "Elwynn Pumpkin Dye",      id = 259118, color = "orange" },
	{ key = "kodohidebrown",      name = "Kodohide Brown Dye",      id = 259132, color = "orange" },
	-- purple
	{ key = "arcwine",            name = "Arcwine Dye",             id = 259131, color = "purple" },
	{ key = "forsakenplum",       name = "Forsaken Plum Dye",       id = 259144, color = "purple" },
	{ key = "kirintorviolet",     name = "Kirin Tor Violet Dye",    id = 259116, color = "purple" },
	{ key = "moonberryamethyst",  name = "Moonberry Amethyst Dye",  id = 259140, color = "purple" },
	{ key = "netherstormfuchsia", name = "Netherstorm Fuchsia Dye", id = 259119, color = "purple" },
	{ key = "nightsonglilac",     name = "Nightsong Lilac Dye",     id = 259130, color = "purple" },
	{ key = "voidviolet",         name = "Void Violet Dye",         id = 259126, color = "purple" },
	-- red
	{ key = "deepmageroyalred",   name = "Deep Mageroyal Red Dye",  id = 259151, color = "red" },
	{ key = "firebloomred",       name = "Firebloom Red Dye",       id = 259127, color = "red" },
	{ key = "gilneanrose",        name = "Gilnean Rose Dye",        id = 259139, color = "red" },
	{ key = "hinterlandshickory", name = "Hinterlands Hickory Dye", id = 259152, color = "red" },
	{ key = "hordered",           name = "Horde Red Dye",           id = 259113, color = "red" },
	{ key = "mahogany",           name = "Mahogany Dye",            id = 259102, color = "red" },
	{ key = "rainpoppyred",       name = "Rain Poppy Red Dye",      id = 259154, color = "red" },
	{ key = "ratchetrust",        name = "Ratchet Rust Dye",        id = 259142, color = "red" },
	-- teal
	{ key = "kultiransteel",      name = "Kul Tiran Steel Dye",     id = 259110, color = "teal" },
	{ key = "tidesageteal",       name = "Tidesage Teal Dye",       id = 259148, color = "teal" },
	{ key = "ungorogreen",        name = "Un'Goro Green Dye",       id = 259125, color = "teal" },
	{ key = "vortexteal",         name = "Vortex Teal Dye",         id = 259136, color = "teal" },
	-- white
	{ key = "basicbirch",         name = "Basic Birch Dye",         id = 259078, color = "white" },
	{ key = "bonewhite",          name = "Bone-White Dye",          id = 259120, color = "white" },
	{ key = "highbornemarble",    name = "Highborne Marble Dye",    id = 259149, color = "white" },
	{ key = "highlandbirch",      name = "Highland Birch Dye",      id = 259099, color = "white" },
	-- yellow
	{ key = "brass",              name = "Brass Dye",               id = 259107, color = "yellow" },
	{ key = "gold",               name = "Gold Dye",                id = 258838, color = "yellow" },
	{ key = "holyoaktan",         name = "Holy Oak Tan Dye",        id = 259100, color = "yellow" },
	{ key = "pinewood",           name = "Pinewood Dye",            id = 259097, color = "yellow" },
	{ key = "sandfuryyellow",     name = "Sandfury Yellow Dye",     id = 259117, color = "yellow" },
	{ key = "savannahgold",       name = "Savannah Gold Dye",       id = 259138, color = "yellow" },
	{ key = "sungrassyellow",     name = "Sungrass Yellow Dye",     id = 259137, color = "yellow" },
	{ key = "zandalarigold",      name = "Zandalari Gold Dye",      id = 259106, color = "yellow" },
}
