-- UI: search window. Left: recipes (filter by profession and text), right: who can make the
-- selected recipe, with online state and zone from the guild roster.
local _, ns = ...
local UI = {}
ns.UI = UI
local L = ns.L

local W, H = 700, 520
local ROW_H = 18
local LEFT_W = 340
local CRAFTER_ROWS = 10
local LIST_TOP = 94

local f, search, dropdown, onlineCheck, recipeList, crafterList, statusText, detailTitle, emptyText
local reagentList, reagentTitle, reagentEmpty
local catDropdown, subDropdown, slotDropdown
local selectedProf, selectedRecipe
-- detail filters, from the crafted item: item class, subclass, equip slot (by its display name)
local selectedCat, selectedSub, selectedSlot
local catOpts, subOpts, slotOpts = {}, {}, {}
local index, indexVersion = {}, -1
local profNames = {}
local membersWithData = 0
local pendingNames = {}

-- Helpers ----------------------------------------------------------------------------------------
local function RecipeName(rid)
  local ok, name = pcall(C_Spell.GetSpellName, rid)
  if ok and type(name) == "string" and name ~= "" then return name end
  if not pendingNames[rid] and C_Spell.RequestLoadSpellData then
    pendingNames[rid] = true
    pcall(C_Spell.RequestLoadSpellData, rid)
  end
  return nil
end

local function RecipeIcon(rid)
  local ok, tex = pcall(C_Spell.GetSpellTexture, rid)
  if ok then return tex end
end

local function IsOnline(guid)
  if guid == ns.me then return true end
  local m = ns.Roster.Member(guid)
  return m and m.online or false
end

local function ClassColored(name, class)
  if class and C_ClassColor and C_ClassColor.GetClassColor then
    local ok, c = pcall(C_ClassColor.GetClassColor, class)
    if ok and c and c.WrapTextInColorCode then return c:WrapTextInColorCode(name) end
  end
  return name
end

local function WhereText(guid)
  local m = ns.Roster.Member(guid)
  if guid == ns.me then
    local zone = GetRealZoneText and GetRealZoneText() or ""
    return "|cffffffff" .. (zone or "") .. "|r"
  end
  if not m then return "" end
  if m.online then
    if m.mobile then return "|cff888888" .. L.MOBILE .. "|r" end
    return "|cffffffff" .. (m.zone or "?") .. "|r"
  end
  local h = m.offlineHours
  if h then
    if h >= 24 then return "|cff666666" .. L.OFFLINE .. " " .. L.DAYS:format(math.floor(h / 24)) .. "|r" end
    return "|cff666666" .. L.OFFLINE .. " " .. L.HOURS:format(h) .. "|r"
  end
  return "|cff666666" .. L.OFFLINE .. "|r"
end

local function InsertLink(link)
  if not link then return end
  local cfu = rawget(_G, "ChatFrameUtil")
  if cfu and cfu.InsertLink then pcall(cfu.InsertLink, link); return end
  local old = rawget(_G, "ChatEdit_InsertLink")
  if old then pcall(old, link) end
end

local function Whisper(name)
  if not name then return end
  local cfu = rawget(_G, "ChatFrameUtil")
  if cfu and cfu.SendTell then pcall(cfu.SendTell, name); return end
  local old = rawget(_G, "ChatFrame_SendTell")
  if old then pcall(old, name) end
end

-- Reagents ---------------------------------------------------------------------------------------
-- C_TradeSkillUI.GetRecipeSchematic works for any recipe ID (Blizzard's crafting orders use it
-- for recipes the player does not know). Only the required slots are listed; optional and
-- finishing reagents are left out. A slot with several items (qualities) counts all of them.
local schematics = {}
local pendingItems = {}

local function Schematic(rid)
  local c = schematics[rid]
  if c then return c end
  local get = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic
  if not get then return nil end
  local ok, s = pcall(get, rid, false)
  if not ok or type(s) ~= "table" or ns.IsSecret(s) then return nil end
  local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  local out = { outputItemID = s.outputItemID, qmin = s.quantityMin, qmax = s.quantityMax, reagents = {} }
  for _, slot in ipairs(s.reagentSlotSchematics or {}) do
    local need = slot.quantityRequired or 0
    if need > 0 and (slot.required ~= false or (basic and slot.reagentType == basic)) then
      local ids = {}
      for _, r in ipairs(slot.reagents or {}) do
        if r.itemID then ids[#ids + 1] = r.itemID end
      end
      if #ids > 0 then out.reagents[#out.reagents + 1] = { itemIDs = ids, need = need } end
    end
  end
  -- an empty list may be data still loading: only a filled one is kept
  if #out.reagents > 0 then schematics[rid] = out end
  return out
end

local function ItemName(id)
  local name = C_Item.GetItemNameByID(id)
  if name then return name end
  if not pendingItems[id] and C_Item.RequestLoadItemDataByID then
    pendingItems[id] = true
    pcall(C_Item.RequestLoadItemDataByID, id)
  end
  return nil
end

local function ItemColored(id, text)
  local q = C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex .. text .. "|r" end
  return text
end

local function ItemLink(id)
  local ok, _, link = pcall(C_Item.GetItemInfo, id)
  if ok then return link end
end

-- the link for chat: the crafted item where the recipe has one, else the recipe spell
local function RecipeLink(rid)
  local s = Schematic(rid)
  local link = s and s.outputItemID and ItemLink(s.outputItemID)
  if link then return link end
  local ok, spellLink = pcall(C_Spell.GetSpellLink, rid)
  if ok then return spellLink end
end

local function Count(ids, bank)
  local n = 0
  for _, id in ipairs(ids) do
    local ok, c = pcall(C_Item.GetItemCount, id, bank and true or false)
    if ok and type(c) == "number" then n = n + c end
  end
  return n
end

-- Player menu ------------------------------------------------------------------------------------
local function Invite(name)
  local fn = C_PartyInfo and C_PartyInfo.InviteUnit
  if fn then pcall(fn, name) end
end

local function AskForRecipe(name, rid)
  local link = RecipeLink(rid) or RecipeName(rid) or ""
  local text = L.ASK_TEXT:format(link)
  local cfu = rawget(_G, "ChatFrameUtil")
  if cfu and cfu.SendTellWithMessage and pcall(cfu.SendTellWithMessage, name, text) then return end
  Whisper(name)
  InsertLink(text)
end

-- Blizzard's own player menu (add friend, ignore, copy name, report ...), as the chat opens it
local function BlizzardMenu(name, guid, owner)
  local open = rawget(_G, "UnitPopup_OpenMenu")
  if type(open) ~= "function" then return end
  pcall(open, "FRIEND", {
    name = name, chatTarget = name, guid = guid, ownerFrame = owner,
    chatFrame = rawget(_G, "DEFAULT_CHAT_FRAME") or rawget(_G, "ChatFrame1"),
  })
end

local function ShowPlayerMenu(owner, c)
  local m = ns.Roster.Member(c.guid)
  local name = (m and m.name) or c.rec.name
  if not name or not MenuUtil or not MenuUtil.CreateContextMenu then return end
  local online = IsOnline(c.guid) and c.guid ~= ns.me
  local rid = selectedRecipe
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle(ClassColored(ns.Roster.NameOf(c.guid, c.rec), c.rec.class))
    local b = root:CreateButton(L.WHISPER, function() Whisper(name) end)
    b:SetEnabled(online)
    if rid then
      b = root:CreateButton(L.ASK, function() AskForRecipe(name, rid) end)
      b:SetEnabled(online)
    end
    b = root:CreateButton(L.INVITE, function() Invite(name) end)
    b:SetEnabled(online)
    if rawget(_G, "UnitPopup_OpenMenu") then
      root:CreateDivider()
      b = root:CreateButton(L.MORE, function()
        -- one frame later: the context menu closes first
        C_Timer.After(0, function() BlizzardMenu(name, c.guid, owner) end)
      end)
      b:SetEnabled(online)
    end
  end)
end

-- Index ------------------------------------------------------------------------------------------
local function BuildIndex()
  if indexVersion == ns.dataVersion then return end
  indexVersion = ns.dataVersion
  index, profNames, membersWithData = {}, {}, 0
  for guid, rec in pairs(ns.Data.Visible()) do
    local has = false
    for sl, p in pairs(rec.profs) do
      if not ns.Scan.NO_RECIPES[sl] then profNames[sl] = ns.Data.ProfName(sl, p) end
      if p.scanned then has = true end
      for rid in pairs(p.recipes or {}) do
        local e = index[rid]
        if not e then e = { sl = sl, crafters = {} }; index[rid] = e end
        e.crafters[#e.crafters + 1] = { guid = guid, rec = rec, prof = p }
      end
    end
    if has then membersWithData = membersWithData + 1 end
  end
  if selectedProf and not profNames[selectedProf] then selectedProf = nil end
  if dropdown then dropdown.Refresh() end
end

-- Item metadata of a recipe (for the detail filters) ---------------------------------------------
local NO_ITEM = -1      -- recipes without a crafted item (enchants and the like)
local metas = {}

local function Meta(rid)
  local m = metas[rid]
  if m then return m end
  m = { class = NO_ITEM }
  local s = Schematic(rid)
  local item = s and s.outputItemID
  if item and item > 0 and C_Item.GetItemInfoInstant then
    local ok, _, _, _, equipLoc, _, classID, subID = pcall(C_Item.GetItemInfoInstant, item)
    if ok and classID then
      m.item, m.class, m.sub = item, classID, subID
      if type(equipLoc) == "string" and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" then
        local name = rawget(_G, equipLoc)
        m.slot = (type(name) == "string" and name ~= "") and name or equipLoc
      end
    end
  end
  -- only a known schematic is final; without one the recipe may get its data later
  if s then metas[rid] = m end
  return m
end

local function ClassName(c)
  if c == NO_ITEM then return L.NO_ITEM end
  local ok, n = pcall(C_Item.GetItemClassInfo, c)
  return (ok and n) or ("#" .. tostring(c))
end

local function SubName(c, s)
  local ok, n = pcall(C_Item.GetItemSubClassInfo, c, s)
  return (ok and n) or ("#" .. tostring(s))
end

-- counts -> sorted option list { key, label = "Name (n)" }
local function Options(counts, nameOf)
  local out = {}
  for key, n in pairs(counts) do
    local name = nameOf(key)
    out[#out + 1] = { key = key, name = name, label = name .. "  |cff999999(" .. n .. ")|r" }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function CountOnline(e)
  local n = 0
  for _, c in ipairs(e.crafters) do if IsOnline(c.guid) then n = n + 1 end end
  return n
end

-- List widget ------------------------------------------------------------------------------------
local function CreateList(parent, width, height, setup)
  local list = CreateFrame("Frame", nil, parent)
  list:SetSize(width, height)
  list.items, list.offset, list.rows = {}, 0, {}
  local n = math.floor(height / ROW_H)
  for i = 1, n do
    local b = CreateFrame("Button", nil, list)
    b:SetHeight(ROW_H)
    b:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    b:SetPoint("RIGHT", list, "RIGHT", -8, 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetColorTexture(0.2, 0.5, 1, 0.25)
    b.sel:Hide()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(ROW_H - 2, ROW_H - 2)
    b.icon:SetPoint("LEFT", 2, 0)
    b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.right:SetPoint("RIGHT", -4, 0)
    b.right:SetJustifyH("RIGHT")
    b.right:SetWordWrap(false)
    b.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.left:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    b.left:SetPoint("RIGHT", b.right, "LEFT", -6, 0)
    b.left:SetJustifyH("LEFT")
    b.left:SetWordWrap(false)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list.rows[i] = b
  end
  -- a thin scroll indicator on the right
  local track = list:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("TOPRIGHT", 0, 0)
  track:SetPoint("BOTTOMRIGHT", 0, 0)
  track:SetWidth(4)
  track:SetColorTexture(1, 1, 1, 0.05)
  local thumb = list:CreateTexture(nil, "ARTWORK")
  thumb:SetWidth(4)
  thumb:SetColorTexture(1, 1, 1, 0.35)

  function list.Update()
    local total = #list.items
    local maxOffset = math.max(0, total - n)
    if list.offset > maxOffset then list.offset = maxOffset end
    for i, b in ipairs(list.rows) do
      local item = list.items[list.offset + i]
      if item then
        setup(b, item)
        b:Show()
      else
        b:Hide()
      end
    end
    if total > n then
      local h = math.max(12, height * n / total)
      thumb:SetHeight(h)
      thumb:ClearAllPoints()
      thumb:SetPoint("TOPRIGHT", 0, -(height - h) * list.offset / maxOffset)
      thumb:Show()
    else
      thumb:Hide()
    end
  end
  function list.SetItems(items, keepOffset)
    list.items = items
    if not keepOffset then list.offset = 0 end
    list.Update()
  end
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    local maxOffset = math.max(0, #list.items - n)
    list.offset = math.min(maxOffset, math.max(0, list.offset - delta * 3))
    list.Update()
  end)
  return list
end

-- Rows ---------------------------------------------------------------------------------------------
local function SetupRecipe(b, item)
  b.item = item
  b.icon:SetTexture(RecipeIcon(item.rid) or 134400)
  b.icon:Show()
  b.left:SetText(item.name)
  b.right:SetText(("|cff40ff40%d|r / %d"):format(item.online, #item.e.crafters))
  b.sel:SetShown(item.rid == selectedRecipe)
  b:SetScript("OnClick", function(self)
    local it = self.item
    if IsShiftKeyDown() then
      InsertLink(RecipeLink(it.rid))
      return
    end
    selectedRecipe = it.rid
    UI.Refresh(true)
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetSpellByID, GameTooltip, self.item.rid) then
      GameTooltip:SetText(self.item.name)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.SHIFT_LINK, 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
end

local function SetupCrafter(b, c)
  b.item = c
  b.icon:Hide()
  b.icon:SetWidth(1)
  local name = ns.Roster.NameOf(c.guid, c.rec)
  if c.guid == ns.me then name = name .. " (" .. L.YOU .. ")" end
  local rank = (c.prof.rank and c.prof.rank > 0) and (" |cff999999" .. c.prof.rank .. "|r") or ""
  b.left:SetText(ClassColored(name, c.rec.class) .. rank)
  b.right:SetText(WhereText(c.guid))
  b.sel:Hide()
  b:SetScript("OnClick", function(self, button)
    local it = self.item
    if button == "RightButton" then
      ShowPlayerMenu(self, it)
    elseif it.guid ~= ns.me and IsOnline(it.guid) then
      local m = ns.Roster.Member(it.guid)
      Whisper((m and m.name) or it.rec.name)
    end
  end)
  b:SetScript("OnEnter", function(self)
    local it = self.item
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(ClassColored(ns.Roster.NameOf(it.guid, it.rec), it.rec.class))
    if it.rec.level then GameTooltip:AddLine(LEVEL and (LEVEL .. " " .. it.rec.level) or it.rec.level, 1, 1, 1) end
    GameTooltip:AddLine(WhereText(it.guid))
    GameTooltip:AddLine(" ")
    for sl, p in pairs(it.rec.profs) do
      GameTooltip:AddDoubleLine(ns.Data.ProfName(sl, p), (p.rank or 0) .. "/" .. (p.max or 0), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    if it.guid ~= ns.me and IsOnline(it.guid) then
      GameTooltip:AddLine(L.CLICK_WHISPER, 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(L.RIGHT_MENU, 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
end

local function SetupReagent(b, r)
  b.item = r
  local id = r.itemIDs[1]
  b.icon:SetTexture((C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or 134400)
  b.icon:Show()
  local name = ItemName(id) or ("#" .. id)
  b.left:SetText(ItemColored(id, name))
  local have, total = Count(r.itemIDs, false), Count(r.itemIDs, true)
  local color = have >= r.need and "|cff40ff40" or "|cffff5050"
  local bank = total > have and ("  |cff888888(+" .. (total - have) .. ")|r") or ""
  b.right:SetText(color .. have .. "|r / " .. r.need .. bank)
  b.sel:Hide()
  b:SetScript("OnClick", function(self)
    if IsShiftKeyDown() then InsertLink(ItemLink(self.item.itemIDs[1])) end
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not pcall(GameTooltip.SetItemByID, GameTooltip, self.item.itemIDs[1]) then
      GameTooltip:SetText(name)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.REAGENT_HINT, 0.6, 0.6, 0.6)
    GameTooltip:AddLine(L.SHIFT_LINK, 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
end

-- Refresh ----------------------------------------------------------------------------------------
function UI.Refresh(keepOffset)
  if not f or not f:IsShown() then return end
  BuildIndex()
  local q = (search:GetText() or ""):lower()
  local onlineOnly = ns.db.opts.onlineOnly
  local base = {}
  for rid, e in pairs(index) do
    if not selectedProf or e.sl == selectedProf then
      local name = RecipeName(rid)
      if name and (q == "" or name:lower():find(q, 1, true)) then
        local online = CountOnline(e)
        if not onlineOnly or online > 0 then
          base[#base + 1] = { rid = rid, name = name, e = e, online = online, meta = Meta(rid) }
        end
      end
    end
  end

  -- detail filters: each dropdown offers what the filters before it leave over (with counts);
  -- a choice that is no longer on offer is dropped
  local cats, subs, slots = {}, {}, {}
  for _, it in ipairs(base) do cats[it.meta.class] = (cats[it.meta.class] or 0) + 1 end
  if selectedCat and not cats[selectedCat] then selectedCat = nil end
  if selectedCat and selectedCat ~= NO_ITEM then
    for _, it in ipairs(base) do
      if it.meta.class == selectedCat and it.meta.sub then subs[it.meta.sub] = (subs[it.meta.sub] or 0) + 1 end
    end
  end
  if selectedSub and not subs[selectedSub] then selectedSub = nil end
  for _, it in ipairs(base) do
    local m = it.meta
    if m.slot and (not selectedCat or m.class == selectedCat) and (not selectedSub or m.sub == selectedSub) then
      slots[m.slot] = (slots[m.slot] or 0) + 1
    end
  end
  if selectedSlot and not slots[selectedSlot] then selectedSlot = nil end
  catOpts = Options(cats, ClassName)
  subOpts = Options(subs, function(s) return SubName(selectedCat, s) end)
  slotOpts = Options(slots, function(s) return s end)
  catDropdown.Refresh()
  subDropdown.Refresh()
  slotDropdown.Refresh()
  if subDropdown.SetEnabled then subDropdown:SetEnabled(#subOpts > 0) end
  if slotDropdown.SetEnabled then slotDropdown:SetEnabled(#slotOpts > 0) end

  local items = {}
  for _, it in ipairs(base) do
    local m = it.meta
    if (not selectedCat or m.class == selectedCat) and (not selectedSub or m.sub == selectedSub)
        and (not selectedSlot or m.slot == selectedSlot) then
      items[#items + 1] = it
    end
  end
  table.sort(items, function(a, b) return a.name < b.name end)
  recipeList.SetItems(items, keepOffset)

  local e = selectedRecipe and index[selectedRecipe]
  local crafters = {}
  if e then
    for _, c in ipairs(e.crafters) do
      if not onlineOnly or IsOnline(c.guid) then crafters[#crafters + 1] = c end
    end
    table.sort(crafters, function(a, b)
      local oa, ob = IsOnline(a.guid), IsOnline(b.guid)
      if oa ~= ob then return oa end
      return ns.Roster.NameOf(a.guid, a.rec) < ns.Roster.NameOf(b.guid, b.rec)
    end)
    detailTitle:SetText((RecipeName(selectedRecipe) or "?") .. "  |cff999999" .. (profNames[e.sl] or "") .. "|r")
  else
    detailTitle:SetText(L.CRAFTERS)
  end
  crafterList.SetItems(crafters, true)
  emptyText:SetText(#items == 0 and L.NO_RESULTS or (not e and L.SELECT_RECIPE or ""))

  local s = e and Schematic(selectedRecipe)
  local reagents = s and s.reagents or {}
  local title = L.REAGENTS
  if s and s.qmin and s.qmax and (s.qmin > 1 or s.qmax > 1) then
    title = title .. "  |cff999999" .. (s.qmin == s.qmax and L.MAKES_ONE:format(s.qmin) or L.MAKES:format(s.qmin, s.qmax)) .. "|r"
  end
  reagentTitle:SetText(title)
  reagentTitle:SetShown(e and true or false)
  reagentList.SetItems(reagents, true)
  reagentEmpty:SetText((e and #reagents == 0) and L.NO_REAGENTS or "")

  local status
  if not IsInGuild() then
    status = L.NOT_IN_GUILD
  else
    local n = 0
    for _ in pairs(index) do n = n + 1 end
    status = L.STATUS:format(membersWithData, n)
    local missing = ns.Scan.Unscanned()
    if #missing > 0 then status = status .. "   |cffffcc00" .. L.OPEN_HINT:format(table.concat(missing, ", ")) .. "|r" end
  end
  statusText:SetText(status)
end

function UI.OnDataChanged()
  if f and f:IsShown() then ns.Debounce("ui", 0.2, function() UI.Refresh(true) end) end
end
UI.OnRosterChanged = UI.OnDataChanged

ns.On("SPELL_DATA_LOAD_RESULT", function(_, spellID)
  if pendingNames[spellID] then
    pendingNames[spellID] = nil
    if f and f:IsShown() then ns.Debounce("names", 0.3, function() UI.Refresh(true) end) end
  end
end)

ns.On("ITEM_DATA_LOAD_RESULT", function(_, itemID)
  if pendingItems[itemID] then
    pendingItems[itemID] = nil
    if f and f:IsShown() then ns.Debounce("names", 0.3, function() UI.Refresh(true) end) end
  end
end)

-- bag contents changed: the reagent counts
ns.On("BAG_UPDATE_DELAYED", function()
  if f and f:IsShown() and selectedRecipe then reagentList.Update() end
end)

-- Frame ------------------------------------------------------------------------------------------
-- A dropdown: "all" plus opts() = { { key, label } }, get() the current key (nil = all), set(key)
local ALL = "__all"
local function CreateDropdown(parent, width, allLabel, opts, get, set)
  local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and dd and dd.SetupMenu then
    dd:SetWidth(width)
    dd:SetupMenu(function(_, root)
      local function isSel(v)
        local cur = get()
        if cur == nil then return v == ALL end
        return cur == v
      end
      local function setSel(v)
        set(v ~= ALL and v or nil)
        selectedRecipe = nil
        UI.Refresh()
      end
      root:CreateRadio(allLabel, isSel, setSel, ALL)
      for _, o in ipairs(opts()) do root:CreateRadio(o.label, isSel, setSel, o.key) end
    end)
    function dd.Refresh() pcall(dd.GenerateMenu, dd) end
    return dd
  end
  -- fallback: a button that steps through the options
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  function b.Refresh()
    local cur, label = get(), allLabel
    for _, o in ipairs(opts()) do if o.key == cur then label = o.label end end
    b:SetText(label)
  end
  b:SetScript("OnClick", function()
    local list, cur, nextKey = opts(), get(), nil
    if cur == nil then nextKey = list[1] and list[1].key
    else
      for i, o in ipairs(list) do if o.key == cur then nextKey = list[i + 1] and list[i + 1].key end end
    end
    set(nextKey)
    selectedRecipe = nil
    UI.Refresh()
  end)
  b.Refresh()
  return b
end

local function ProfessionOptions()
  local list = {}
  for sl, name in pairs(profNames) do list[#list + 1] = { key = sl, label = name } end
  table.sort(list, function(a, b) return a.label < b.label end)
  return list
end

local function Create()
  f = CreateFrame("Frame", "WhoCanForeverFrame", UIParent, "BasicFrameTemplateWithInset")
  f:SetSize(W, H)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, rel, x, y = self:GetPoint()
    ns.db.opts.pos = { point, rel, x, y }
  end)
  local pos = ns.db.opts.pos
  if type(pos) == "table" and pos[1] then
    f:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
  else
    f:SetPoint("CENTER")
  end
  tinsert(UISpecialFrames, "WhoCanForeverFrame")

  local title = f.TitleText
  if not title then
    title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
  end
  title:SetText(L.TITLE)

  search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
  search:SetSize(220, 20)
  search:SetPoint("TOPLEFT", 18, -34)
  search:SetAutoFocus(false)
  if search.Instructions then search.Instructions:SetText(L.SEARCH) end
  search:HookScript("OnTextChanged", function() selectedRecipe = nil; UI.Refresh() end)

  dropdown = CreateDropdown(f, 180, L.ALL_PROFESSIONS, ProfessionOptions,
    function() return selectedProf end,
    function(v)
      -- another profession: the detail filters start over
      selectedProf, selectedCat, selectedSub, selectedSlot = v, nil, nil, nil
    end)
  dropdown:SetPoint("LEFT", search, "RIGHT", 14, 0)

  -- second row: detail filters
  catDropdown = CreateDropdown(f, 180, L.ALL_TYPES, function() return catOpts end,
    function() return selectedCat end,
    function(v) selectedCat, selectedSub = v, nil end)
  catDropdown:SetPoint("TOPLEFT", 14, -64)
  subDropdown = CreateDropdown(f, 180, L.ALL_SUBTYPES, function() return subOpts end,
    function() return selectedSub end,
    function(v) selectedSub = v end)
  subDropdown:SetPoint("LEFT", catDropdown, "RIGHT", 10, 0)
  slotDropdown = CreateDropdown(f, 160, L.ALL_SLOTS, function() return slotOpts end,
    function() return selectedSlot end,
    function(v) selectedSlot = v end)
  slotDropdown:SetPoint("LEFT", subDropdown, "RIGHT", 10, 0)
  local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  reset:SetSize(110, 22)
  reset:SetPoint("LEFT", slotDropdown, "RIGHT", 10, 0)
  reset:SetText(L.RESET)
  reset:SetScript("OnClick", function()
    selectedProf, selectedCat, selectedSub, selectedSlot, selectedRecipe = nil, nil, nil, nil, nil
    search:SetText("")
    UI.Refresh()
  end)

  onlineCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  onlineCheck:SetSize(24, 24)
  onlineCheck:SetPoint("LEFT", dropdown, "RIGHT", 14, 0)
  local cbText = onlineCheck.text or onlineCheck.Text
  if not cbText then
    cbText = onlineCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbText:SetPoint("LEFT", onlineCheck, "RIGHT", 2, 0)
  end
  cbText:SetText(L.ONLINE_ONLY)
  onlineCheck:SetChecked(ns.db.opts.onlineOnly and true or false)
  onlineCheck:SetScript("OnClick", function(self)
    ns.db.opts.onlineOnly = self:GetChecked() and true or false
    UI.Refresh()
  end)

  local listH = H - LIST_TOP - 34
  recipeList = CreateList(f, LEFT_W, listH, SetupRecipe)
  recipeList:SetPoint("TOPLEFT", 14, -LIST_TOP)

  local divider = f:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 1, 1, 0.1)
  divider:SetWidth(1)
  divider:SetPoint("TOPLEFT", recipeList, "TOPRIGHT", 8, 0)
  divider:SetPoint("BOTTOMLEFT", recipeList, "BOTTOMRIGHT", 8, 0)

  detailTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  detailTitle:SetPoint("TOPLEFT", recipeList, "TOPRIGHT", 18, -2)
  detailTitle:SetPoint("RIGHT", f, "RIGHT", -16, 0)
  detailTitle:SetJustifyH("LEFT")
  detailTitle:SetWordWrap(false)

  local rightW = W - LEFT_W - 46
  crafterList = CreateList(f, rightW, CRAFTER_ROWS * ROW_H, SetupCrafter)
  crafterList:SetPoint("TOPLEFT", recipeList, "TOPRIGHT", 16, -24)

  emptyText = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  emptyText:SetPoint("CENTER", crafterList, "CENTER")

  reagentTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  reagentTitle:SetPoint("TOPLEFT", crafterList, "BOTTOMLEFT", 2, -10)
  reagentTitle:SetPoint("RIGHT", f, "RIGHT", -16, 0)
  reagentTitle:SetJustifyH("LEFT")
  reagentTitle:SetWordWrap(false)

  local reagentH = listH - 24 - CRAFTER_ROWS * ROW_H - 32
  reagentList = CreateList(f, rightW, reagentH, SetupReagent)
  reagentList:SetPoint("TOPLEFT", crafterList, "BOTTOMLEFT", 0, -32)

  reagentEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  reagentEmpty:SetPoint("TOPLEFT", reagentList, "TOPLEFT", 4, -4)

  statusText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  statusText:SetPoint("BOTTOMLEFT", 16, 12)
  statusText:SetPoint("RIGHT", f, "RIGHT", -16, 0)
  statusText:SetJustifyH("LEFT")
  statusText:SetWordWrap(false)

  f:SetScript("OnShow", function()
    ns.Roster.Request()
    UI.Refresh()
  end)
  f:Hide()

  -- keep zones and online state fresh while the window is open (the server limits roster requests)
  C_Timer.NewTicker(30, function()
    if f:IsShown() then ns.Roster.Request() end
  end)
end

function UI.Show(query)
  if not f then Create() end
  f:Show()
  if query and query ~= "" then search:SetText(query) end
  UI.Refresh()
end

function UI.Toggle()
  if f and f:IsShown() then f:Hide() else UI.Show() end
end
