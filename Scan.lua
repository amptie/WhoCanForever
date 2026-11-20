-- Scan: the player's own professions and recipes.
-- * Recipes come from C_TradeSkillUI, which has data only while the profession window is open.
-- * Which professions the character has (and their skill) comes from GetProfessions, at login
--   and on SKILL_LINES_CHANGED. A profession that was listed there once and is gone now has been
--   unlearned: it is removed and the guild is told (new revision).
local _, ns = ...
local S = {}
ns.Scan = S

local T = C_TradeSkillUI
local loginDone = false

local function Call(f, ...)
  if type(f) ~= "function" then return nil end
  local ok, a, b, c = pcall(f, ...)
  if not ok or ns.IsSecret(a) then return nil end
  return a, b, c
end

local function SameSet(a, b)
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

-- Professions from GetProfessions --------------------------------------------------------------
local function CurrentProfessions()
  if type(GetProfessions) ~= "function" then return nil end
  local ok, a, b, c, d, e, f = pcall(GetProfessions)
  if not ok then return nil end
  local present = {}
  for _, idx in ipairs({ a or false, b or false, c or false, d or false, e or false, f or false }) do
    if idx and not ns.IsSecret(idx) then
      -- GetProfessionInfo: name, icon, skillLevel, maxSkillLevel, numAbilities, spellOffset, skillLine, ...
      local ok2, n2, _, r2, m2, _, _, sl2 = pcall(GetProfessionInfo, idx)
      if ok2 and sl2 and not ns.IsSecret(sl2) then
        present[sl2] = { name = n2, rank = r2, max = m2 }
      end
    end
  end
  return present
end

function S.SyncProfessions()
  local rec = ns.Data.Mine()
  if not rec then return end
  local present = CurrentProfessions()
  if not present then return end
  local stash = ns.db.stash[ns.me] or {}
  ns.db.stash[ns.me] = stash
  local urgent, changed = false, false

  for sl, info in pairs(present) do
    local p = rec.profs[sl]
    if not p then
      -- learned (again)? A profession removed earlier at no lower skill is the same one coming
      -- back (e.g. data not loaded the moment it was missing): its recipes come back too.
      local old = stash[sl]
      if old and (info.rank or 0) >= (old.rank or 0) then
        p = old
      else
        p = { recipes = {}, scanned = false }
      end
      stash[sl] = nil
      rec.profs[sl] = p
      urgent = true
    end
    if not p.seen then p.seen = true end
    if p.name ~= info.name or p.rank ~= info.rank or p.max ~= info.max then
      p.name, p.rank, p.max = info.name, info.rank, info.max
      changed = true
    end
  end

  -- unlearned: only professions GetProfessions listed before (First Aid and the like may never
  -- show up there and are kept)
  if loginDone then
    for sl, p in pairs(rec.profs) do
      if p.seen and not present[sl] then
        rec.profs[sl] = nil
        p.seen = nil
        stash[sl] = p
        ns.Print(ns.L.REMOVED:format(ns.Data.ProfName(sl, p)))
        urgent = true
      end
    end
  end

  if urgent or changed then ns.Data.Touch(rec, urgent) end
end

-- Recipes from the open profession window --------------------------------------------------------
local function OpenProfessionID()
  local base = Call(T.GetBaseProfessionInfo)
  local id = type(base) == "table" and base.professionID or nil
  local child = Call(T.GetChildProfessionInfo)
  if (not id or id == 0) and type(child) == "table" then
    id = child.parentProfessionID or child.professionID
  end
  if not id or id == 0 or ns.IsSecret(id) then return nil end
  local info = (type(child) == "table" and (child.skillLevel or 0) > 0) and child or base
  return id, info
end

function S.ScanOpen()
  if not T or not Call(T.IsTradeSkillReady) then return end
  if Call(T.IsTradeSkillLinked) or Call(T.IsTradeSkillGuild) or Call(T.IsNPCCrafting) then return end
  if Call(T.IsDataSourceChanging) then return end
  local sl, info = OpenProfessionID()
  if not sl then return end
  local ids = Call(T.GetAllRecipeIDs)
  if type(ids) ~= "table" then return end

  local set, n = {}, 0
  for _, rid in ipairs(ids) do
    local r = Call(T.GetRecipeInfo, rid)
    if type(r) == "table" and r.learned and not r.isRecraft and not r.isDummyRecipe then
      set[rid] = true
      n = n + 1
    end
  end
  -- an empty list right after opening is the data still loading, not a profession without recipes
  if n == 0 then return end

  local rec = ns.Data.Mine()
  local p = rec.profs[sl]
  local isNew = not p
  if isNew then p = { recipes = {} }; rec.profs[sl] = p end
  local changed = isNew or not p.scanned or not SameSet(set, p.recipes or {})
  if changed then
    p.recipes = set
    if not p.scanned then ns.Print(ns.L.SCANNED:format(ns.Data.ProfName(sl, p), n)) end
    p.scanned = true
  end
  if type(info) == "table" then
    local name, rank, max = info.professionName, info.skillLevel, info.maxSkillLevel
    if name and name ~= "" and p.name ~= name then p.name = name; changed = true end
    -- the skill from GetProfessions wins where it knows the profession (no ping-pong between both)
    if not p.seen and rank and rank > 0 and (p.rank ~= rank or p.max ~= max) then p.rank, p.max = rank, max; changed = true end
  end
  if changed then ns.Data.Touch(rec, true) end
end

-- a recipe learned while the window is closed (trainer, recipe item)
local function OnRecipeLearned(_, recipeID)
  if not recipeID or ns.IsSecret(recipeID) then return end
  local rec = ns.Data.Mine()
  if not rec then return end
  local tradeSkillID, _, parentID = Call(T and T.GetTradeSkillLineForRecipe, recipeID)
  local p = (parentID and rec.profs[parentID]) or (tradeSkillID and rec.profs[tradeSkillID])
  if p and not p.recipes[recipeID] then
    p.recipes[recipeID] = true
    ns.Data.Touch(rec, true)
  end
end

local function Later() ns.Debounce("scan", 0.5, S.ScanOpen) end
ns.On("TRADE_SKILL_SHOW", Later)
ns.On("TRADE_SKILL_LIST_UPDATE", Later)
ns.On("TRADE_SKILL_DATA_SOURCE_CHANGED", Later)
ns.On("NEW_RECIPE_LEARNED", OnRecipeLearned)

ns.On("SKILL_LINES_CHANGED", function()
  ns.Debounce("skills", 1, S.SyncProfessions)
end)
ns.On("PLAYER_LOGIN", function()
  -- the first look only adds and updates; removing waits until the skill data has surely loaded
  C_Timer.After(3, function()
    ns.SafeCall(ns.Data.UpdateIdentity)
    ns.SafeCall(S.SyncProfessions)
  end)
  C_Timer.After(10, function()
    loginDone = true
    ns.SafeCall(S.SyncProfessions)
  end)
end)
ns.On("PLAYER_LEVEL_UP", function()
  ns.Debounce("identity", 2, ns.Data.UpdateIdentity)
end)

-- gathering skills without a recipe window: Herbalism, Skinning, Fishing, Archaeology
S.NO_RECIPES = { [182] = true, [393] = true, [356] = true, [794] = true }

-- own professions without recipe data yet (for the hint in the window)
function S.Unscanned()
  local rec = ns.Data.Mine()
  local out = {}
  for sl, p in pairs(rec and rec.profs or {}) do
    if not p.scanned and not S.NO_RECIPES[sl] then out[#out + 1] = ns.Data.ProfName(sl, p) end
  end
  table.sort(out)
  return out
end
