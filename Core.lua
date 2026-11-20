-- WhoCanForever: who in the guild knows which recipe.
-- Core: namespace, events, safe calls, saved variables, slash commands, strings.
local ADDON, ns = ...
_G.WhoCanForever = ns

ns.PREFIX = "WhoCanF"          -- addon message prefix (max 16 chars)
ns.PROTO = "1"                 -- protocol version; messages of another version are ignored
ns.dataVersion = 0             -- bumped whenever any record changes (the UI rebuilds on it)

-- Strings ----------------------------------------------------------------------------------------
local L = {
  TITLE = "WhoCanForever",
  SEARCH = "Search recipe...",
  ALL_PROFESSIONS = "All professions",
  ONLINE_ONLY = "Online only",
  CRAFTERS = "Who can make it",
  SELECT_RECIPE = "Select a recipe on the left.",
  NO_RESULTS = "No recipes found.",
  OFFLINE = "offline",
  MOBILE = "mobile app",
  STATUS = "%d members with data, %d recipes",
  OPEN_HINT = "Open these professions once to share your recipes: %s",
  NOT_IN_GUILD = "You are not in a guild.",
  CLICK_WHISPER = "Click: whisper",
  SHIFT_LINK = "Shift-click: link in chat",
  ERROR = "An error occurred (/wcf errors shows the details).",
  SCANNED = "%s: %d recipes saved.",
  REMOVED = "%s is no longer known and was removed.",
  YOU = "you",
  DAYS = "%dd",
  HOURS = "%dh",
  RESTRICTED = "This realm restricts addon chat messages. Guild sharing should still work.",
  RIGHT_MENU = "Right-click: options",
  REAGENTS = "Reagents",
  NO_REAGENTS = "No reagent data for this recipe.",
  REAGENT_HINT = "in bags / needed  (+bank)",
  MAKES = "makes %d-%d",
  MAKES_ONE = "makes %d",
  WHISPER = "Whisper",
  ASK = "Ask for this recipe",
  ASK_TEXT = "Hi! Could you craft %s for me?",
  INVITE = "Invite to group",
  MORE = "More options...",
  ALL_TYPES = "All item types",
  ALL_SUBTYPES = "All subtypes",
  ALL_SLOTS = "All slots",
  NO_ITEM = "No item (enchants etc.)",
  RESET = "Reset filters",
  MM_LEFT = "Left-click: open/close",
  MM_DRAG = "Drag: move button",
  MM_HIDE = "/wcf minimap: hide/show button",
}
if GetLocale() == "deDE" then
  L.SEARCH = "Rezept suchen..."
  L.ALL_PROFESSIONS = "Alle Berufe"
  L.ONLINE_ONLY = "Nur online"
  L.CRAFTERS = "Wer kann es herstellen"
  L.SELECT_RECIPE = "Links ein Rezept auswählen."
  L.NO_RESULTS = "Keine Rezepte gefunden."
  L.MOBILE = "Mobile App"
  L.STATUS = "%d Mitglieder mit Daten, %d Rezepte"
  L.OPEN_HINT = "Öffne diese Berufe einmal, um deine Rezepte zu teilen: %s"
  L.NOT_IN_GUILD = "Du bist in keiner Gilde."
  L.CLICK_WHISPER = "Klick: anflüstern"
  L.SHIFT_LINK = "Shift-Klick: Link in den Chat"
  L.ERROR = "Ein Fehler ist aufgetreten (/wcf errors zeigt Details)."
  L.SCANNED = "%s: %d Rezepte gespeichert."
  L.REMOVED = "%s ist nicht mehr bekannt und wurde entfernt."
  L.YOU = "du"
  L.DAYS = "%dT"
  L.HOURS = "%dStd"
  L.RESTRICTED = "Dieser Realm beschränkt Addon-Nachrichten im Chat. Das Teilen in der Gilde sollte trotzdem gehen."
  L.RIGHT_MENU = "Rechtsklick: Optionen"
  L.REAGENTS = "Materialien"
  L.NO_REAGENTS = "Keine Materialdaten für dieses Rezept."
  L.REAGENT_HINT = "im Gepäck / benötigt  (+Bank)"
  L.MAKES = "ergibt %d-%d"
  L.MAKES_ONE = "ergibt %d"
  L.WHISPER = "Anflüstern"
  L.ASK = "Nach diesem Rezept fragen"
  L.ASK_TEXT = "Hi! Könntest du mir %s herstellen?"
  L.INVITE = "In Gruppe einladen"
  L.MORE = "Weitere Optionen..."
  L.ALL_TYPES = "Alle Itemtypen"
  L.ALL_SUBTYPES = "Alle Untertypen"
  L.ALL_SLOTS = "Alle Slots"
  L.NO_ITEM = "Kein Item (Verzauberungen usw.)"
  L.RESET = "Filter zurücksetzen"
  L.MM_LEFT = "Linksklick: öffnen/schließen"
  L.MM_DRAG = "Ziehen: Button verschieben"
  L.MM_HIDE = "/wcf minimap: Button aus-/einblenden"
end
ns.L = L

-- Helpers ----------------------------------------------------------------------------------------
function ns.IsSecret(v)
  if type(issecretvalue) ~= "function" then return false end
  local ok, s = pcall(issecretvalue, v)
  return ok and s == true
end

function ns.Print(...)
  print("|cff33ccffWhoCan|r:", ...)
end

function ns.Debug(...)
  if ns.db and ns.db.debug then print("|cff888888WhoCan dbg:|r", ...) end
end

local errorSaid = false
function ns.SafeCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    local db = ns.db
    if db then
      db.errors = db.errors or {}
      table.insert(db.errors, 1, date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(err))
      while #db.errors > 30 do table.remove(db.errors) end
    end
    if not errorSaid then errorSaid = true; ns.Print(L.ERROR) end
  end
  return ok, err
end

-- one shared "do this a little later, once" helper: a second call before the first fired is merged
local timers = {}
function ns.Debounce(key, delay, fn)
  if timers[key] then return end
  timers[key] = true
  C_Timer.After(delay, function()
    timers[key] = nil
    ns.SafeCall(fn)
  end)
end

function ns.Changed()
  ns.dataVersion = ns.dataVersion + 1
  if ns.UI and ns.UI.OnDataChanged then ns.UI.OnDataChanged() end
end

-- Events -----------------------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local handlers = {}
function ns.On(event, fn)
  local list = handlers[event]
  if not list then
    if not pcall(frame.RegisterEvent, frame, event) then
      ns.Debug("unknown event", event)
      return
    end
    list = {}
    handlers[event] = list
  end
  list[#list + 1] = fn
end
frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do ns.SafeCall(list[i], event, ...) end
end)

-- Saved variables --------------------------------------------------------------------------------
local function InitDB()
  local db = _G.WhoCanForeverDB
  if type(db) ~= "table" then db = {} end
  _G.WhoCanForeverDB = db
  db.schema = db.schema or 1
  db.chars = db.chars or {}         -- [guid] = record (see Data.lua)
  db.own = db.own or {}             -- [guid] = true for the account's own characters
  db.stash = db.stash or {}         -- [guid] = { [skillLine] = profession } removed professions, see Scan.lua
  db.opts = db.opts or {}
  db.errors = db.errors or {}
  ns.db = db
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  InitDB()
end)

ns.On("PLAYER_LOGIN", function()
  ns.me = UnitGUID("player")
  ns.myName = UnitName("player")   -- on Forever "First Surname" for the player
  ns.db.own[ns.me] = true
  if ns.Data then ns.Data.Mine() end
end)

-- Slash commands ---------------------------------------------------------------------------------
SLASH_WHOCANFOREVER1 = "/wcf"
SLASH_WHOCANFOREVER2 = "/whocan"
SlashCmdList.WHOCANFOREVER = function(msg)
  ns.SafeCall(function()
    msg = strtrim(msg or "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
      ns.UI.Toggle()
    elseif cmd == "sync" then
      ns.Comm.Hello(true)
      ns.Print("sync requested")
    elseif cmd == "status" then
      ns.Status()
    elseif cmd == "minimap" then
      ns.Minimap.Toggle()
    elseif cmd == "debug" then
      ns.db.debug = not ns.db.debug
      ns.Print("debug", ns.db.debug and "on" or "off")
    elseif cmd == "errors" then
      if #ns.db.errors == 0 then ns.Print("no errors") end
      for i = 1, math.min(#ns.db.errors, 10) do print(ns.db.errors[i]) end
    elseif cmd == "clearerrors" then
      wipe(ns.db.errors)
    else
      ns.UI.Show(msg)
    end
  end)
end

function _G.WhoCanForever_OnCompartmentClick()
  ns.SafeCall(ns.UI.Toggle)
end

function ns.Status()
  local nChars, nOwn = 0, 0
  for guid in pairs(ns.db.chars) do
    nChars = nChars + 1
    if ns.db.own[guid] then nOwn = nOwn + 1 end
  end
  ns.Print(("records: %d (own characters: %d)"):format(nChars, nOwn))
  local mine = ns.Data.Mine()
  for sl, p in pairs(mine and mine.profs or {}) do
    local n = 0
    for _ in pairs(p.recipes or {}) do n = n + 1 end
    print(("  %s (%d): skill %d/%d, %s"):format(ns.Data.ProfName(sl, p), sl, p.rank or 0, p.max or 0,
      p.scanned and (n .. " recipes") or "not scanned yet"))
  end
  local f = C_ChatInfo and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
  local ok, restricted = false, nil
  if f then ok, restricted = pcall(f) end
  print("  addon chat restricted:", ok and tostring(restricted) or "?")
  local g = C_TradeSkillUI and C_TradeSkillUI.IsGuildTradeSkillsEnabled
  local ok2, enabled = false, nil
  if g then ok2, enabled = pcall(g) end
  print("  Blizzard guild recipes enabled:", ok2 and tostring(enabled) or "?")
  print("  comm:", ns.Comm.StatusText())
end
