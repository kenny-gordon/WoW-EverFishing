local _, EverFishing = ...
EverFishing = EverFishing or _G.EverFishing or {}
_G.EverFishing = EverFishing

EverFishing.Data = {
    MAIN_HAND_SLOT = 16,
    FISHING_ITEM_CLASS_ID = 2,
    FISHING_POLE_SUBCLASS_IDS = {
        [20] = true,
        [25] = true,
    },
    FISHING_SPELL_IDS = { 7620, 131474 },
    LURES = {
        { id = 6529, name = "Shiny Bauble", bonus = 25, minimumSkill = 1 },
        { id = 6530, name = "Nightcrawlers", bonus = 50, minimumSkill = 50 },
        { id = 6811, name = "Aquadynamic Fish Lens", bonus = 50, minimumSkill = 50 },
        { id = 6532, name = "Bright Baubles", bonus = 75, minimumSkill = 100 },
        { id = 7307, name = "Flesh Eating Worm", bonus = 75, minimumSkill = 100 },
        { id = 6533, name = "Aquadynamic Fish Attractor", bonus = 100, minimumSkill = 100 },
    },
}