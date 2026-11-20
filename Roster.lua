-- Roster: guild members by GUID with online state and zone. Works for members without the addon.
local _, ns = ...
local R = { byGuid = {}, count = 0, guild = nil }
ns.Roster = R

local PRUNE_AFTER = 30 * 86400    -- a record of this guild not on the roster for 30 days is dropped

local function Safe(v)
  if ns.IsSecret(v) then return nil end
  return v
end

function R.Request()
  if not IsInGuild() then return end
  if C_GuildInfo and C_GuildInfo.GuildRoster then pcall(C_GuildInfo.GuildRoster) end
end

function R.Refresh()
  wipe(R.byGuid)
  R.count = 0
  if not IsInGuild() then R.guild = nil; return end
  local guild = GetGuildInfo("player")
  if guild and not ns.IsSecret(guild) then R.guild = guild end
  local n = GetNumGuildMembers() or 0
  if ns.IsSecret(n) then return end
  local lastOnline = rawget(_G, "GetGuildRosterLastOnline")
  for i = 1, n do
    local name, _, _, level, _, zone, _, _, isOnline, _, class, _, _, isMobile, _, _, guid = GetGuildRosterInfo(i)
    guid = Safe(guid)
    if guid then
      local m = { name = Safe(name), level = Safe(level), zone = Safe(zone), online = Safe(isOnline) and true or false,
        class = Safe(class), mobile = Safe(isMobile) and true or false, index = i }
      if not m.online and lastOnline then
        local ok, y, mo, d, h = pcall(lastOnline, i)
        if ok and not ns.IsSecret(y) and type(y) == "number" then
          m.offlineHours = ((y * 365 + (mo or 0) * 30 + (d or 0)) * 24) + (h or 0)
        end
      end
      R.byGuid[guid] = m
      R.count = R.count + 1
    end
  end
  R.Prune()
end

-- records of this guild whose character left: drop after PRUNE_AFTER (own characters are kept)
function R.Prune()
  if not R.guild or R.count == 0 then return end
  local now = time()
  local changed = false
  for guid, rec in pairs(ns.db.chars) do
    if rec.guild == R.guild then
      if R.byGuid[guid] then
        rec.lastRoster = now
      elseif not ns.db.own[guid] then
        rec.lastRoster = rec.lastRoster or now
        if now - rec.lastRoster > PRUNE_AFTER then
          ns.db.chars[guid] = nil
          changed = true
        end
      end
    end
  end
  if changed then ns.Changed() end
end

function R.Member(guid) return R.byGuid[guid] end

-- display name: the roster's current name, else the one in the record
function R.NameOf(guid, rec)
  local m = R.byGuid[guid]
  local name = (m and m.name) or (rec and rec.name) or "?"
  if Ambiguate then
    local ok, short = pcall(Ambiguate, name, "guild")
    if ok and type(short) == "string" then name = short end
  end
  return name
end

ns.On("GUILD_ROSTER_UPDATE", function()
  ns.Debounce("roster", 0.5, function()
    R.Refresh()
    ns.Data.UpdateIdentity()
    if ns.UI and ns.UI.OnRosterChanged then ns.UI.OnRosterChanged() end
  end)
end)

ns.On("PLAYER_GUILD_UPDATE", function()
  ns.Debounce("guildupdate", 1, function()
    R.Request()
    R.Refresh()
    ns.Data.UpdateIdentity()
    ns.Changed()
  end)
end)

ns.On("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
  if isLogin or isReload then R.Request() end
end)
