-- Comm: sharing records between addon users.
--
-- Transport: today only the guild channel (GUILD addon messages, which go through even on
-- realms that restrict addon chat messages; custom channels are refused there). A later
-- server-wide transport plugs into C.transports; messages and records stay the same.
--
-- Messages (prefix "WhoCanF", fields separated by "^", numbers in base 36):
--   A^1^guid^rev               "I have this character at this revision" (owners on login/change)
--   I^1^token                  "what do you have?" (on login); one holder answers with a digest
--   G^1^token^guid:rev;...     digest, the answer to I (several messages for big guilds)
--   Q^1^guid:rev,guid:rev,...  "send me these records (at least this rev)"; the owner answers at
--                              once, other holders of that rev later (and only if nobody did)
--   D^1^guid^rev^i^n^chunk     a record, in n chunks
-- Rule everywhere: the higher revision wins. Records travel through any holder, so the data of
-- members who are offline still reaches new users.
local _, ns = ...
local C = {}
ns.Comm = C

local PREFIX, PROTO = ns.PREFIX, ns.PROTO
local CHUNK = 200          -- payload bytes per D message (limit 255 with the header)
local MAX_CHUNKS = 80
local REQUEST_HOLD = 20    -- a guid asked for (by anyone) is not asked for again this soon

C.transports = {
  guild = { kind = "GUILD", Available = function() return IsInGuild() end },
}
C.active = "guild"

local B36 = function(n) return ns.Data.B36(n) end
local function N36(s) return s and tonumber(s, 36) end

local queue = {}
local tokens, MAX_TOKENS = 5, 5          -- client throttle per prefix: a burst, then ~1 per second
local lastRefill = GetTime()
local pausedUntil = 0
local stats = { sent = 0, received = 0, throttled = 0, refused = 0 }
local lastCode

local requested = {}     -- [guid] = { rev, at } someone asked for this rev of it
local wanted = {}        -- [guid] = rev, to ask for in the next Q
local seenData = {}      -- [guid] = { rev, at } first chunk of a record someone else sent
local lastSent = {}      -- [guid] = { rev, at } we queued this record
local incoming = {}      -- [sender|guid|rev] = { n, parts, got, at }
local digestSeen = {}    -- [token] = true once any digest for it went out
local myToken
local lastAnnounced = {} -- [guid] = rev

-- Sending --------------------------------------------------------------------------------------
local function CanSend()
  if InCombatLockdown() then return false end
  local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
  if f then
    local ok, v = pcall(f)
    if ok and not ns.IsSecret(v) and v then return false end
  end
  return true
end

local function Pump()
  local now = GetTime()
  tokens = math.min(MAX_TOKENS, tokens + (now - lastRefill))
  lastRefill = now
  if #queue == 0 or now < pausedUntil or not CanSend() then return end
  while tokens >= 1 and #queue > 0 do
    local m = queue[1]
    if m.cancel and m.cancel() then
      table.remove(queue, 1)
    else
      local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, m.text, m.kind, m.target)
      if ns.IsSecret(res) then res = 0 end
      if not ok then
        table.remove(queue, 1)
        stats.refused = stats.refused + 1
        lastCode = "error"
        ns.Debug("send error", tostring(res))
      elseif res == 3 or res == 8 then
        -- throttled by the client: the message stays first in line
        stats.throttled = stats.throttled + 1
        pausedUntil = now + 2
        return
      elseif res == nil or res == 0 or res == true then
        table.remove(queue, 1)
        tokens = tokens - 1
        stats.sent = stats.sent + 1
        if m.onSent then m.onSent() end
      else
        table.remove(queue, 1)
        stats.refused = stats.refused + 1
        lastCode = tostring(res)
        ns.Debug("send refused", tostring(res), m.text:sub(1, 30))
      end
    end
  end
end

function C.Send(text, opts)
  local t = C.transports[C.active]
  if not t or not t.Available() then return false end
  local m = { text = text, kind = t.kind, target = t.target }
  if opts then m.cancel, m.onSent = opts.cancel, opts.onSent end
  queue[#queue + 1] = m
  return true
end

local function Msg(kind, ...)
  return table.concat({ kind, PROTO, ... }, "^")
end

-- Announce / hello -----------------------------------------------------------------------------
local function AnnounceGuid(guid, force)
  local rec = ns.Data.Get(guid)
  if not rec or not rec.rev or rec.rev == 0 then return end
  if not force and lastAnnounced[guid] == rec.rev then return end
  lastAnnounced[guid] = rec.rev
  C.Send(Msg("A", guid, B36(rec.rev)))
end

function C.Announce()
  if not ns.me then return end
  AnnounceGuid(ns.me)
end

function C.ScheduleAnnounce(urgent)
  if urgent then ns.Debounce("announceU", 5, C.Announce)
  else ns.Debounce("announce", 120, C.Announce) end
end

-- on login (and /wcf sync): own characters of this guild, then ask the guild what it has
function C.Hello(force)
  if not IsInGuild() or not ns.Roster.guild then return false end
  if not force and C.helloGuild == ns.Roster.guild then return true end
  C.helloGuild = ns.Roster.guild
  for guid in pairs(ns.db.own) do
    local rec = ns.Data.Get(guid)
    if rec and rec.guild == ns.Roster.guild then AnnounceGuid(guid, force) end
  end
  myToken = B36(math.random(1, 2000000000))
  C.Send(Msg("I", myToken))
  return true
end

-- Requests -------------------------------------------------------------------------------------
local function FlushWants()
  local now = GetTime()
  local batch = {}
  local function flush()
    if #batch > 0 then C.Send(Msg("Q", table.concat(batch, ","))) end
    batch = {}
  end
  for guid, rev in pairs(wanted) do
    local r = requested[guid]
    local known = ns.Data.Get(guid)
    local stillNeeded = not known or (known.rev or 0) < rev
    if stillNeeded and not (r and r.rev >= rev and now - r.at < REQUEST_HOLD) then
      requested[guid] = { rev = rev, at = now }
      batch[#batch + 1] = guid .. ":" .. B36(rev)
      if #batch >= 7 then flush() end
    end
  end
  flush()
  wipe(wanted)
end

local function Want(guid, rev)
  if (wanted[guid] or 0) >= rev then return end
  wanted[guid] = rev
  ns.Debounce("want", 1 + math.random() * 1.5, FlushWants)
end

local function SendRecord(guid, rec, isOwner)
  local payload = ns.Data.Serialize(rec)
  local n = math.max(1, math.ceil(#payload / CHUNK))
  if n > MAX_CHUNKS then ns.Debug("record too big", guid); return end
  local rev = rec.rev
  local job = { started = false, queuedAt = GetTime() }
  -- a holder that is not the owner drops the whole record if someone else began sending it first
  local cancel = not isOwner and function()
    if job.started then return false end
    local s = seenData[guid]
    return s and s.rev >= rev and s.at >= job.queuedAt
  end or nil
  lastSent[guid] = { rev = rev, at = GetTime() }
  for i = 1, n do
    local part = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
    C.Send(Msg("D", guid, B36(rev), B36(i), B36(n), part), {
      cancel = cancel,
      onSent = function() job.started = true end,
    })
  end
end

local function Respond(guid, minRev)
  local rec = ns.Data.Get(guid)
  if not rec or not rec.profs or not rec.rev or rec.rev < (minRev or 0) then return end
  local ls = lastSent[guid]
  if ls and ls.rev == rec.rev and GetTime() - ls.at < 15 then return end
  local isOwner = guid == ns.me
  local delay = isOwner and 0.3 or (3 + math.random() * 5)
  local askedAt = GetTime()
  C_Timer.After(delay, function()
    ns.SafeCall(function()
      local r = ns.Data.Get(guid)
      if not r or not r.rev then return end
      local s = seenData[guid]
      if not isOwner and s and s.rev >= r.rev and s.at >= askedAt then return end
      local ls2 = lastSent[guid]
      if ls2 and ls2.rev == r.rev and GetTime() - ls2.at < 15 then return end
      SendRecord(guid, r, isOwner)
    end)
  end)
end

local function SendDigest(token)
  if digestSeen[token] then return end
  local entries = {}
  for guid, rec in pairs(ns.Data.Visible()) do
    if rec.rev then entries[#entries + 1] = guid .. ":" .. B36(rec.rev) end
  end
  if #entries == 0 then return end
  local head = Msg("G", token) .. "^"
  local line = {}
  local len = #head
  for _, e in ipairs(entries) do
    if len + #e + 1 > 250 then
      C.Send(head .. table.concat(line, ";"))
      line, len = {}, #head
    end
    line[#line + 1] = e
    len = len + #e + 1
  end
  if #line > 0 then C.Send(head .. table.concat(line, ";")) end
end

-- Receiving ------------------------------------------------------------------------------------
local function IsSelf(sender)
  if sender == ns.myName then return true end
  if Ambiguate then
    local ok, short = pcall(Ambiguate, sender, "none")
    if ok and short == ns.myName then return true end
  end
  return false
end

local function OnData(text, sender)
  local guid, rev36, i36, n36, part = text:match("^D%^%w+%^([^%^]+)%^(%w+)%^(%w+)%^(%w+)%^(.*)$")
  local rev, i, n = N36(rev36), N36(i36), N36(n36)
  if not (guid and rev and i and n) or n < 1 or n > MAX_CHUNKS or i < 1 or i > n then return end
  local now = GetTime()
  if i == 1 then
    local s = seenData[guid]
    if not s or s.rev <= rev then seenData[guid] = { rev = rev, at = now } end
  end
  local known = ns.Data.Get(guid)
  if known and (known.rev or 0) >= rev then return end
  for k, a in pairs(incoming) do
    if now - a.at > 120 then incoming[k] = nil end
  end
  local key = sender .. "|" .. guid .. "|" .. rev
  local a = incoming[key]
  if not a then
    a = { n = n, parts = {}, got = 0, at = now }
    incoming[key] = a
  end
  if a.n ~= n then incoming[key] = nil; return end
  if not a.parts[i] then
    a.parts[i] = part
    a.got = a.got + 1
  end
  if a.got == a.n then
    incoming[key] = nil
    if ns.Data.Store(guid, rev, table.concat(a.parts)) then ns.Debug("stored", guid, "from", sender) end
  end
end

local function OnMessage(text, sender)
  local kind = text:sub(1, 1)
  local f = ns.Data.Split(text, "^")
  if f[2] ~= PROTO then return end
  local now = GetTime()
  if kind == "D" then
    OnData(text, sender)
  elseif kind == "A" then
    local guid, rev = f[3], N36(f[4])
    if not guid or not rev then return end
    local known = ns.Data.Get(guid)
    if not known or (known.rev or 0) < rev then Want(guid, rev) end
  elseif kind == "Q" then
    for _, e in ipairs(ns.Data.Split(f[3] or "", ",")) do
      local guid, rev36 = e:match("^([^:]+):(%w+)$")
      local rev = N36(rev36)
      if guid and rev then
        local r = requested[guid]
        if not r or r.rev <= rev then requested[guid] = { rev = rev, at = now } end
        if wanted[guid] and wanted[guid] <= rev then wanted[guid] = nil end
        Respond(guid, rev)
      end
    end
  elseif kind == "I" then
    local token = f[3]
    if not token or token == myToken then return end
    C_Timer.After(2 + math.random() * 6, function() ns.SafeCall(SendDigest, token) end)
  elseif kind == "G" then
    local token = f[3]
    if not token then return end
    digestSeen[token] = true
    if token ~= myToken then return end
    for _, e in ipairs(ns.Data.Split(f[4] or "", ";")) do
      local guid, rev36 = e:match("^([^:]+):(%w+)$")
      local rev = N36(rev36)
      if guid and rev then
        local known = ns.Data.Get(guid)
        if not known or (known.rev or 0) < rev then Want(guid, rev) end
      end
    end
  end
end

ns.On("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
  if ns.IsSecret(prefix) or ns.IsSecret(text) or ns.IsSecret(channel) or ns.IsSecret(sender) then return end
  if prefix ~= PREFIX or type(text) ~= "string" or type(sender) ~= "string" then return end
  if channel ~= C.transports[C.active].kind then return end
  local kind = text:sub(1, 1)
  if IsSelf(sender) then
    -- our own digest echo still marks the token as answered
    if kind == "G" then
      local token = ns.Data.Split(text, "^")[3]
      if token then digestSeen[token] = true end
    end
    return
  end
  stats.received = stats.received + 1
  OnMessage(text, sender)
end)

ns.On("PLAYER_LOGIN", function()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
  end
  C_Timer.NewTicker(0.25, function() ns.SafeCall(Pump) end)
  -- hello once the guild roster (and with it the guild name) has loaded
  local tries = 0
  local function try()
    tries = tries + 1
    local ok, done = ns.SafeCall(C.Hello)
    if not (ok and done) and IsInGuild() and tries < 6 then C_Timer.After(15, try) end
  end
  C_Timer.After(12, try)
end)

ns.On("PLAYER_GUILD_UPDATE", function()
  -- joined another guild: hello there (Hello does nothing for the guild it already greeted)
  ns.Debounce("guildhello", 8, function() C.Hello(false) end)
end)

function C.StatusText()
  return ("queue %d, sent %d, received %d, throttled %d, refused %d%s"):format(#queue, stats.sent,
    stats.received, stats.throttled, stats.refused, lastCode and (" (last code " .. lastCode .. ")") or "")
end
