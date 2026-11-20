-- Minimap button: opens the window, can be dragged around the minimap, /wcf minimap hides it.
-- Own button instead of LibDBIcon: that library checks WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and
-- takes the wrong branch on Forever. Layout like LibDBIcon (tracking border, background, icon).
local _, ns = ...
local M = {}
ns.Minimap = M

local ICON = "Interface\\Icons\\Trade_BlackSmithing"
local button

local function Opts()
  local o = ns.db.opts
  o.minimap = o.minimap or { angle = 200, hide = false }
  return o.minimap
end

local function UpdatePosition()
  local a = math.rad(Opts().angle or 200)
  local x, y = math.cos(a), math.sin(a)
  local shape = rawget(_G, "GetMinimapShape") and GetMinimapShape() or "ROUND"
  if shape == "SQUARE" then
    -- on a square minimap the button runs along the edge
    local m = math.max(math.abs(x), math.abs(y))
    x, y = x / m, y / m
  end
  local r = Minimap:GetWidth() / 2 + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x * r, y * r)
end

-- radians; Lua 5.1 has math.atan2, newer Lua math.atan(y, x) (the global atan2 of WoW is in degrees)
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local s = Minimap:GetEffectiveScale()
  px, py = px / s, py / s
  Opts().angle = math.deg(atan2(py - my, px - mx)) % 360
  UpdatePosition()
end

local function Create()
  button = CreateFrame("Button", "WhoCanForeverMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = button:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")
  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -6)
  button.icon = icon

  button:SetScript("OnClick", function()
    ns.SafeCall(ns.UI.Toggle)
  end)
  button:SetScript("OnMouseDown", function() icon:SetTexCoord(0, 1, 0, 1) end)
  button:SetScript("OnMouseUp", function() icon:SetTexCoord(0.05, 0.95, 0.05, 0.95) end)
  button:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", OnDragUpdate)
    GameTooltip:Hide()
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(ns.L.TITLE)
    GameTooltip:AddLine(ns.L.MM_LEFT, 1, 1, 1)
    GameTooltip:AddLine(ns.L.MM_DRAG, 0.6, 0.6, 0.6)
    GameTooltip:AddLine(ns.L.MM_HIDE, 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UpdatePosition()
end

function M.Apply()
  if Opts().hide then
    if button then button:Hide() end
    return
  end
  if not button then Create() end
  button:Show()
  UpdatePosition()
end

function M.Toggle()
  local o = Opts()
  o.hide = not o.hide
  M.Apply()
end

ns.On("PLAYER_LOGIN", function()
  if not Minimap then return end
  M.Apply()
end)
