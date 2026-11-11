--[[
MooSpeak UI: minimap button, options window and the "You're not a
Tauren!" confirmation. Uses only frame templates present in every
supported client (BasicFrameTemplateWithInset, UICheckButtonTemplate,
UIPanelButtonTemplate, InputBoxTemplate) and builds its own labels
instead of relying on template child names, which differ between clients.
]]

local _, ns = ...
local Core = ns.Core

local UI = {}
ns.UI = UI

local minimapButton, optionsFrame, confirmFrame

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function label(parent, text, font)
	local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlight")
	fs:SetText(text)
	fs:SetJustifyH("LEFT")
	return fs
end

local function checkbox(parent, text, note)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(26, 26)
	local fs = label(parent, text)
	fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
	cb.label = fs
	if note then
		local n = label(parent, note, "GameFontDisableSmall")
		n:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -2)
		cb.note = n
	end
	return cb
end

local function dialogFrame(name, width, height)
	local f = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(width, height)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	table.insert(UISpecialFrames, name) -- close with Escape
	f:Hide()
	return f
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

local function placeMinimapButton()
	local angle = math.rad(MooSpeakDB.minimap.angle or 225)
	local radius = Minimap:GetWidth() / 2 + 10
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function showMinimapTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("MooSpeak")
	if Core.IsEnabled() then
		GameTooltip:AddLine("Mooing: ON", 0.2, 1, 0.2)
	else
		GameTooltip:AddLine("Mooing: OFF", 1, 0.3, 0.3)
	end
	GameTooltip:AddLine("Left-click: turn mooing on/off", 1, 1, 1)
	GameTooltip:AddLine("Right-click: options", 1, 1, 1)
	GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

local function createMinimapButton()
	local b = CreateFrame("Button", "MooSpeakMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetTexture(Core.ICON)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	icon:SetPoint("TOPLEFT", 7, -6)
	b.icon = icon

	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetPoint("TOPLEFT")

	b:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			UI.ToggleOptions()
		else
			Core.Toggle()
		end
		if GameTooltip:IsOwned(self) then showMinimapTooltip(self) end
	end)
	b:SetScript("OnEnter", showMinimapTooltip)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	b:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			MooSpeakDB.minimap.angle = math.deg(atan2(py - my, px - mx)) % 360
			placeMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		self:UnlockHighlight()
	end)

	minimapButton = b
	placeMinimapButton()
end

---------------------------------------------------------------------------
-- Options window
---------------------------------------------------------------------------

local function createOptions()
	local f = dialogFrame("MooSpeakOptions", 380, 330)

	local title = label(f, "MooSpeak Options", "GameFontHighlight")
	title:SetPoint("TOP", 0, -6)

	local icon = f:CreateTexture(nil, "ARTWORK")
	icon:SetSize(40, 40)
	icon:SetTexture(Core.ICON)
	icon:SetPoint("TOPLEFT", 18, -36)

	local heading = label(f, "MooSpeak", "GameFontNormalLarge")
	heading:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
	local sub = label(f, "Speak the tongue of the Tauren.", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)

	local enable = checkbox(f, "Moo my chat")
	enable:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", -4, -14)
	enable:SetScript("OnClick", function(self)
		Core.RequestEnable(self:GetChecked())
	end)
	f.enableCheck = enable

	local honorary = checkbox(f, "Honorary Tauren", "Moo without the Earth Mother's disapproval.")
	honorary:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 0, -6)
	honorary:SetScript("OnClick", function(self)
		Core.SetHonoraryTauren(self:GetChecked())
	end)
	f.honoraryCheck = honorary

	local minimapCheck = checkbox(f, "Show minimap button")
	minimapCheck:SetPoint("TOPLEFT", honorary, "BOTTOMLEFT", 0, -18)
	minimapCheck:SetScript("OnClick", function(self)
		MooSpeakDB.minimap.hide = not self:GetChecked()
		UI.Refresh()
	end)
	f.minimapCheck = minimapCheck

	local previewLabel = label(f, "Preview", "GameFontNormal")
	previewLabel:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 4, -14)

	local input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	input:SetSize(330, 22)
	input:SetAutoFocus(false)
	input:SetMaxLetters(255)
	input:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 4, -4)
	f.previewInput = input

	local output = label(f, "", "GameFontHighlightSmall")
	output:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -4, -6)
	output:SetWidth(340)
	output:SetWordWrap(true)
	f.previewOutput = output

	input:SetScript("OnTextChanged", function(self)
		local lines = ns.Codec.Encode(self:GetText())
		output:SetText(lines and table.concat(lines, "\n") or "|cff888888Type something to hear it mooed.|r")
	end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	output:SetText("|cff888888Type something to hear it mooed.|r")

	optionsFrame = f
end

function UI.ShowOptions()
	UI.Refresh()
	optionsFrame:Show()
end

function UI.ToggleOptions()
	if optionsFrame:IsShown() then
		optionsFrame:Hide()
	else
		UI.ShowOptions()
	end
end

---------------------------------------------------------------------------
-- Confirmation dialog
---------------------------------------------------------------------------

local function createConfirm()
	local d = dialogFrame("MooSpeakConfirm", 340, 230)

	local icon = d:CreateTexture(nil, "ARTWORK")
	icon:SetSize(48, 48)
	icon:SetTexture(Core.ICON)
	icon:SetPoint("TOP", 0, -32)

	local title = label(d, "", "GameFontNormalLarge")
	title:SetPoint("TOP", icon, "BOTTOM", 0, -8)
	title:SetJustifyH("CENTER")
	d.title = title

	local body = label(d, "", "GameFontHighlight")
	body:SetPoint("TOP", title, "BOTTOM", 0, -8)
	body:SetWidth(300)
	body:SetJustifyH("CENTER")
	body:SetWordWrap(true)
	d.body = body

	local function finish(which)
		local o = d.current
		d.current = nil
		d:Hide()
		if o and o[which] then o[which]() end
	end

	local accept = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
	accept:SetSize(130, 24)
	accept:SetPoint("BOTTOMLEFT", 20, 14)
	accept:SetScript("OnClick", function() finish("onAccept") end)
	d.acceptButton = accept

	local decline = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
	decline:SetSize(130, 24)
	decline:SetPoint("BOTTOMRIGHT", -20, 14)
	decline:SetScript("OnClick", function() finish("onDecline") end)
	d.declineButton = decline

	-- Closing with Escape or the X counts as declining.
	d:SetScript("OnHide", function()
		if d.current then finish("onDecline") end
	end)

	confirmFrame = d
end

--- Shows the confirmation dialog.
--- opts: title, text, accept, decline, onAccept, onDecline.
function UI.ShowConfirm(opts)
	local d = confirmFrame
	d.current = opts
	d.title:SetText(opts.title)
	d.body:SetText(opts.text)
	d.acceptButton:SetText(opts.accept)
	d.declineButton:SetText(opts.decline)
	d:SetHeight(150 + (d.body.GetStringHeight and d.body:GetStringHeight() or 60))
	d:Show()
end

---------------------------------------------------------------------------
-- Refresh and startup
---------------------------------------------------------------------------

function UI.Refresh()
	local enabled = Core.IsEnabled()
	minimapButton.icon:SetDesaturated(not enabled)
	minimapButton:SetShown(not MooSpeakDB.minimap.hide)

	local f = optionsFrame
	f.enableCheck:SetChecked(enabled)
	f.minimapCheck:SetChecked(not MooSpeakDB.minimap.hide)
	f.honoraryCheck:SetChecked(MooSpeakDB.honoraryTauren)
	-- A real Tauren has no use for honorary status.
	local tauren = Core.IsTauren()
	f.honoraryCheck:SetShown(not tauren)
	f.honoraryCheck.label:SetShown(not tauren)
	f.honoraryCheck.note:SetShown(not tauren)
end

function UI.Init()
	createMinimapButton()
	createOptions()
	createConfirm()
	Core.OnChange(UI.Refresh)
	UI.Refresh()
end

-- Retail/Forever addon compartment (the puzzle-piece menu by the minimap).
function MooSpeak_OnAddonCompartmentClick(_, button)
	if button == "RightButton" then
		UI.ToggleOptions()
	else
		Core.Toggle()
	end
end
