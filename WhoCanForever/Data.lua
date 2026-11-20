-- Data: one record per character, keyed by GUID (never by name: Forever has surnames and
-- several own characters may share a first name). The record does not depend on the guild,
-- so a later server-wide transport can reuse it unchanged.
--
-- record = {
--   name = "First Surname", class = "PALADIN", level = 60, guild = "Guild name",
--   rev = <server time of the owner's last change>,     -- higher rev wins everywhere
--   profs = { [skillLineID] = { name, rank, max, scanned = bool, recipes = { [recipeID] = true },
--                               seen = bool (own chars only: listed by GetProfessions once) } },
--   got = <local time() the record arrived>             -- not transmitted
-- }
local _, ns = ...
local D = {}
ns.Data = D

local MAX_RECIPES = 3000     -- per profession, against broken or hostile data

-- base 36 keeps recipe IDs short in messages
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
function D.B36(n)
  n = math.floor(tonumber(n) or 0)
  if n <= 0 then return "0" end
  local s = ""
  while n > 0 do
    local r = n % 36
    s = DIGITS:sub(r + 1, r + 1) .. s
    n = (n - r) / 36
  end
  return s
end
local function N36(s) return s and tonumber(s, 36) end

function D.Split(s, sep)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  return out
end

-- the separators of the format never appear inside a field
local function Clean(s)
  s = tostring(s or "")
  return (s:gsub("[%^~:,|]", ""))
end

function D.Now()
  return (GetServerTime and GetServerTime()) or time()
end

function D.Get(guid) return ns.db.chars[guid] end

function D.Mine()
  if not ns.me or not ns.db then return nil end
  local rec = ns.db.chars[ns.me]
  if not rec then
    rec = { profs = {}, rev = 0 }
    ns.db.chars[ns.me] = rec
  end
  rec.profs = rec.profs or {}
  return rec
end

-- something in the own record changed: new revision, tell the guild (urgent = recipes changed)
function D.Touch(rec, urgent)
  rec.rev = math.max(D.Now(), (rec.rev or 0) + 1)
  ns.Changed()
  if ns.Comm then ns.Comm.ScheduleAnnounce(urgent) end
end

-- name, class, level and guild of the logged-in character
function D.UpdateIdentity()
  local rec = D.Mine()
  if not rec then return end
  local name = UnitName("player")
  local _, class = UnitClass("player")
  local level = UnitLevel("player")
  local guild = IsInGuild() and GetGuildInfo("player") or nil
  if IsInGuild() and not guild then return end     -- guild info not loaded yet, try again later
  if ns.IsSecret(name) or ns.IsSecret(class) or ns.IsSecret(level) or ns.IsSecret(guild) then return end
  if rec.name ~= name or rec.class ~= class or rec.level ~= level or rec.guild ~= guild then
    local guildChanged = rec.guild ~= guild
    rec.name, rec.class, rec.level, rec.guild = name, class, level, guild
    D.Touch(rec, guildChanged)
  end
end

function D.ProfName(sl, p)
  local f = C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName
  if f then
    local ok, name = pcall(f, sl)
    if ok and type(name) == "string" and name ~= "" and not ns.IsSecret(name) then return name end
  end
  return (p and p.name) or ("#" .. tostring(sl))
end

-- Records shown in the window: same guild as the player, still on the guild roster (the roster
-- has the GUIDs). Before the roster has loaded, the guild name alone decides.
function D.Visible()
  local out = {}
  local guild = ns.Roster.guild
  if not guild then return out end
  local rosterReady = ns.Roster.count > 0
  for guid, rec in pairs(ns.db.chars) do
    if rec.guild == guild and rec.profs and (not rosterReady or ns.Roster.byGuid[guid]) then
      out[guid] = rec
    end
  end
  return out
end

-- Serialization ----------------------------------------------------------------------------------
-- name^class^guild^level^prof~prof~...   prof = id:rank:max:scanned:name:r,r,r (base 36)
function D.Serialize(rec)
  local profs = {}
  for sl, p in pairs(rec.profs or {}) do
    local ids = {}
    for rid in pairs(p.recipes or {}) do ids[#ids + 1] = rid end
    table.sort(ids)
    for i = 1, #ids do ids[i] = D.B36(ids[i]) end
    profs[#profs + 1] = table.concat({ D.B36(sl), D.B36(p.rank), D.B36(p.max), p.scanned and "1" or "0",
      Clean(p.name), table.concat(ids, ",") }, ":")
  end
  return table.concat({ Clean(rec.name), Clean(rec.class), Clean(rec.guild), D.B36(rec.level),
    table.concat(profs, "~") }, "^")
end

function D.Deserialize(s)
  if type(s) ~= "string" then return nil end
  local f = D.Split(s, "^")
  if #f ~= 5 then return nil end
  local rec = { name = f[1], class = f[2], guild = f[3] ~= "" and f[3] or nil, level = N36(f[4]), profs = {} }
  if rec.name == "" then return nil end
  if f[5] ~= "" then
    for _, ps in ipairs(D.Split(f[5], "~")) do
      local p = D.Split(ps, ":")
      if #p ~= 6 then return nil end
      local sl = N36(p[1])
      if not sl then return nil end
      local prof = { rank = N36(p[2]) or 0, max = N36(p[3]) or 0, scanned = p[4] == "1",
        name = p[5] ~= "" and p[5] or nil, recipes = {} }
      if p[6] ~= "" then
        local ids = D.Split(p[6], ",")
        if #ids > MAX_RECIPES then return nil end
        for _, id in ipairs(ids) do
          local rid = N36(id)
          if rid then prof.recipes[rid] = true end
        end
      end
      rec.profs[sl] = prof
    end
  end
  return rec
end

-- a record received from the guild; returns true when it was newer and stored
function D.Store(guid, rev, payload)
  rev = tonumber(rev)
  if not rev or type(guid) ~= "string" or not guid:match("^Player%-") then return false end
  local old = ns.db.chars[guid]
  if old and (old.rev or 0) >= rev then return false end
  local rec = D.Deserialize(payload)
  if not rec then ns.Debug("bad record", guid); return false end
  rec.rev = rev
  rec.got = time()
  -- an own character keeps its local flags (seen) where the profession is still there
  if old and old.profs then
    for sl, p in pairs(rec.profs) do
      if old.profs[sl] then p.seen = old.profs[sl].seen end
    end
  end
  ns.db.chars[guid] = rec
  ns.Changed()
  return true
end
