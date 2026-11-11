-- Core (WoW glue) tests against a small mock of the client's chat API.
-- The mock follows Blizzard's shared chat code (ChatFrameEditBox.lua):
-- SendText fires "ChatFrame.OnEditBoxPreSendText", then reads the edit
-- box text, then calls C_ChatInfo.SendChatMessage, then AddHistory.

local H = dofile("tests/harness.lua")

local env -- per-test mock state

local function newEditBox(text, chatType, target)
	local box = { text = text, chatType = chatType, target = target, languageID = 7, history = {} }
	function box:GetText() return self.text end
	function box:SetText(t) self.text = t end
	function box:GetChatType() return self.chatType end
	function box:GetTellTarget() return self.target end
	function box:GetChannelTarget() return self.target end
	-- Mirrors ChatFrameEditBoxBaseMixin:SendText.
	function box:SendText()
		EventRegistry:TriggerEvent("ChatFrame.OnEditBoxPreSendText", self)
		local t = self:GetText()
		if t:find("%S") then
			local target = (self.chatType == "WHISPER" or self.chatType == "CHANNEL") and self.target or nil
			C_ChatInfo.SendChatMessage(t, self.chatType, self.languageID, target)
			self.history[#self.history + 1] = self:GetText()
		end
		self.text = ""
	end
	return box
end

-- A permissive stand-in for any WoW frame or region: known methods keep
-- state, anything else is a no-op.
local widgetMethods = {
	RegisterEvent = function(self, e) self.events[e] = true end,
	UnregisterEvent = function(self, e) self.events[e] = nil end,
	SetScript = function(self, s, fn)
		self.scripts[s] = fn
		if s == "OnEvent" then self.onEvent = fn end
	end,
	HookScript = function(self, s, fn) self.scripts[s] = fn end,
	GetScript = function(self, s) return self.scripts[s] end,
	Show = function(self) self.shown = true end,
	Hide = function(self) self.shown = false end,
	IsShown = function(self) return self.shown end,
	SetShown = function(self, v) self.shown = not not v end,
	SetChecked = function(self, v) self.checked = not not v end,
	GetChecked = function(self) return self.checked end,
	SetText = function(self, t) self.text = t end,
	GetText = function(self) return self.text or "" end,
	SetDesaturated = function(self, v) self.desaturated = v end,
	GetCenter = function() return 0, 0 end,
	GetEffectiveScale = function() return 1 end,
	GetWidth = function() return 140 end,
	GetHeight = function() return 140 end,
}

local function newWidget()
	local w = { events = {}, scripts = {}, shown = true }
	w.CreateTexture = function() return newWidget() end
	w.CreateFontString = function() return newWidget() end
	return setmetatable(w, {
		__index = function(_, k)
			return widgetMethods[k] or function() end
		end,
	})
end

local function click(widget, button)
	widget.scripts.OnClick(widget, button or "LeftButton")
end

local function setup(opts)
	opts = opts or {}
	env = { sent = {}, printed = {}, filters = {}, callbacks = {}, frames = {} }

	EventRegistry = {
		RegisterCallback = function(_, event, func, owner)
			env.callbacks[event] = { func = func, owner = owner }
		end,
		TriggerEvent = function(_, event, ...)
			local cb = env.callbacks[event]
			if cb then cb.func(cb.owner, ...) end
		end,
	}
	C_ChatInfo = {
		SendChatMessage = function(msg, chatType, languageID, target)
			env.sent[#env.sent + 1] = { msg = msg, chatType = chatType, languageID = languageID, target = target }
		end,
		InChatMessagingLockdown = function() return opts.lockdown or false end,
	}
	ChatFrameUtil = {
		AddMessageEventFilter = function(event, fn) env.filters[event] = fn end,
	}
	ChatFrame_AddMessageEventFilter = nil
	hooksecurefunc = function(tbl, name, hook)
		local orig = tbl[name]
		tbl[name] = function(...)
			local r = { orig(...) }
			hook(...)
			return unpack(r)
		end
	end
	CreateFrame = function(_, name)
		local f = newWidget()
		if name then _G[name] = f end
		env.frames[#env.frames + 1] = f
		return f
	end
	UIParent = newWidget()
	Minimap = newWidget()
	GameTooltip = newWidget()
	UISpecialFrames = {}
	GetCursorPosition = function() return 0, 0 end
	UnitRace = function() return opts.raceName or "Tauren", opts.race or "Tauren" end
	SlashCmdList = {}
	DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) env.printed[#env.printed + 1] = m end }
	MooSpeakDB = opts.db

	local ns = {}
	H.loadAddonFile("MooSpeak/Codec.lua", ns)
	H.loadAddonFile("MooSpeak/Core.lua", ns)
	H.loadAddonFile("MooSpeak/UI.lua", ns)
	for _, f in ipairs(env.frames) do
		if f.events.ADDON_LOADED then f.onEvent(f, "ADDON_LOADED", "MooSpeak") end
	end
	env.ns = ns
	return ns
end

local function slash(msg) SlashCmdList.MOOSPEAK(msg) end

local function sentMessages()
	local t = {}
	for i, s in ipairs(env.sent) do t[i] = s.msg end
	return t
end

H.test("starts disabled and creates saved settings", function()
	setup()
	H.eq(MooSpeakDB.enabled, false)
end)

H.test("keeps the saved enabled state", function()
	setup({ db = { enabled = true } })
	H.eq(MooSpeakDB.enabled, true)
end)

H.test("slash command toggles, and accepts on/off", function()
	setup()
	slash("")
	H.eq(MooSpeakDB.enabled, true)
	slash("")
	H.eq(MooSpeakDB.enabled, false)
	slash("on")
	H.eq(MooSpeakDB.enabled, true)
	slash("off")
	H.eq(MooSpeakDB.enabled, false)
end)

H.test("does not touch chat while disabled", function()
	setup()
	local box = newEditBox("hello there", "SAY")
	box:SendText()
	H.eq(sentMessages()[1], "hello there")
end)

H.test("sends moos when enabled", function()
	local ns = setup({ db = { enabled = true } })
	local box = newEditBox("hello there, friend!", "SAY")
	box:SendText()
	H.eq(#env.sent, 1)
	H.eq(env.sent[1].chatType, "SAY")
	H.eq(ns.Codec.Decode(env.sent[1].msg), "hello there, friend!")
	H.falsy(env.sent[1].msg:find("hello"), "original text leaked")
end)

H.test("chat history keeps the original text", function()
	setup({ db = { enabled = true } })
	local box = newEditBox("remember me", "SAY")
	box:SendText()
	H.eq(box.history[1], "remember me")
end)

H.test("long messages send every line, in order, to the same target", function()
	local ns = setup({ db = { enabled = true } })
	local text = string.rep("whisper this long secret to my friend please, ", 4)
	local box = newEditBox(text, "WHISPER", "Moomoo")
	box:SendText()
	local expected = ns.Codec.Encode(text)
	H.truthy(#expected > 1, "test text should need several lines")
	H.eq(#env.sent, #expected)
	for i, line in ipairs(expected) do
		H.eq(env.sent[i].msg, line, "line " .. i)
		H.eq(env.sent[i].chatType, "WHISPER")
		H.eq(env.sent[i].target, "Moomoo")
		H.eq(env.sent[i].languageID, 7)
	end
end)

H.test("leaves emotes and unsupported chat types alone", function()
	setup({ db = { enabled = true } })
	newEditBox("dances wildly", "EMOTE"):SendText()
	newEditBox("hello", "BN_WHISPER"):SendText()
	H.eq(sentMessages()[1], "dances wildly")
	H.eq(sentMessages()[2], "hello")
end)

H.test("does not re-encode text that is already moo", function()
	local ns = setup({ db = { enabled = true } })
	local moo = ns.Codec.Encode("already encoded")[1]
	newEditBox(moo, "SAY"):SendText()
	H.eq(sentMessages()[1], moo)
end)

H.test("our own extra sends are not treated as new messages", function()
	setup({ db = { enabled = true } })
	local text = string.rep("a fairly long message that will need splitting, ", 4)
	newEditBox(text, "PARTY"):SendText()
	newEditBox("short one", "PARTY"):SendText()
	local last = env.sent[#env.sent].msg
	H.eq(env.ns.Codec.Decode(last), "short one")
end)

H.test("in chat lockdown a one-line message is still mooed", function()
	local ns = setup({ db = { enabled = true }, lockdown = true })
	newEditBox("inc left", "RAID"):SendText()
	H.eq(ns.Codec.Decode(sentMessages()[1]), "inc left")
end)

H.test("in chat lockdown a multi-line message is sent as typed, with a notice", function()
	setup({ db = { enabled = true }, lockdown = true })
	local text = string.rep("this callout is far too long to moo during combat, ", 4)
	newEditBox(text, "RAID"):SendText()
	H.eq(#env.sent, 1)
	H.eq(sentMessages()[1], text)
	H.truthy(#env.printed > 0, "expected a notice")
end)

H.test("registers display filters for the main chat events", function()
	setup()
	for _, e in ipairs({ "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_RAID",
		"CHAT_MSG_GUILD", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_CHANNEL",
		"CHAT_MSG_INSTANCE_CHAT" }) do
		H.truthy(env.filters[e], "no filter for " .. e)
	end
end)

H.test("display filter translates moo lines and keeps other arguments", function()
	local ns = setup() -- translation works even while sending is disabled
	local moo = ns.Codec.Encode("meet at the mailbox")[1]
	local r = { env.filters.CHAT_MSG_SAY({}, "CHAT_MSG_SAY", moo, "Bob-Realm", "Orcish", "", "Bob") }
	H.eq(r[1], false)
	H.eq(r[2], "MooSpeak: meet at the mailbox")
	H.eq(r[3], "Bob-Realm")
	H.eq(r[4], "Orcish")
	H.eq(r[6], "Bob")
end)

H.test("display filter leaves normal chat alone", function()
	setup()
	local r = { env.filters.CHAT_MSG_SAY({}, "CHAT_MSG_SAY", "moo moo", "Bob") }
	H.eq(r[1], false)
	H.eq(r[2], nil)
end)

H.test("falls back to the older global filter API", function()
	-- Older clients only have ChatFrame_AddMessageEventFilter.
	local captured = {}
	setup()
	ChatFrameUtil = nil
	ChatFrame_AddMessageEventFilter = function(e, fn) captured[e] = fn end
	local ns = {}
	H.loadAddonFile("MooSpeak/Codec.lua", ns)
	H.loadAddonFile("MooSpeak/Core.lua", ns)
	local f = env.frames[#env.frames]
	f.onEvent(f, "ADDON_LOADED", "MooSpeak")
	H.truthy(captured.CHAT_MSG_SAY, "fallback filter not registered")
end)

-- Tauren check -------------------------------------------------------------

local NON_TAUREN = { race = "Gnome", raceName = "Gnome" }

local function confirmDialog() return _G.MooSpeakConfirm end

H.test("a Tauren turns mooing on without any questions", function()
	setup()
	slash("on")
	H.eq(MooSpeakDB.enabled, true)
	H.falsy(confirmDialog().shown, "confirm dialog should stay hidden")
end)

H.test("Highmountain Tauren count as Tauren", function()
	setup({ race = "HighmountainTauren", raceName = "Highmountain Tauren" })
	slash("on")
	H.eq(MooSpeakDB.enabled, true)
end)

H.test("a non-Tauren is asked to confirm and stays off until they do", function()
	setup(NON_TAUREN)
	slash("on")
	H.eq(MooSpeakDB.enabled, false)
	H.truthy(confirmDialog().shown, "confirm dialog should be shown")
end)

H.test("confirming makes you an honorary Tauren and turns mooing on", function()
	setup(NON_TAUREN)
	slash("on")
	click(confirmDialog().acceptButton)
	H.eq(MooSpeakDB.enabled, true)
	H.eq(MooSpeakDB.honoraryTauren, true)
	H.falsy(confirmDialog().shown, "dialog should close")
end)

H.test("declining keeps mooing off with an in-character message", function()
	setup(NON_TAUREN)
	slash("on")
	local before = #env.printed
	click(confirmDialog().declineButton)
	H.eq(MooSpeakDB.enabled, false)
	H.falsy(MooSpeakDB.honoraryTauren)
	H.truthy(#env.printed > before, "expected a roleplay message")
end)

H.test("an honorary Tauren is not asked again", function()
	setup({ race = "Gnome", raceName = "Gnome", db = { honoraryTauren = true } })
	slash("on")
	H.eq(MooSpeakDB.enabled, true)
	H.falsy(confirmDialog().shown)
end)

H.test("turning mooing off never asks", function()
	setup({ race = "Gnome", raceName = "Gnome", db = { enabled = true } })
	slash("off")
	H.eq(MooSpeakDB.enabled, false)
	H.falsy(confirmDialog().shown)
end)

-- Minimap button and options ----------------------------------------------

local function minimapButton() return _G.MooSpeakMinimapButton end
local function options() return _G.MooSpeakOptions end

H.test("minimap left-click toggles mooing", function()
	setup()
	click(minimapButton(), "LeftButton")
	H.eq(MooSpeakDB.enabled, true)
	click(minimapButton(), "LeftButton")
	H.eq(MooSpeakDB.enabled, false)
end)

H.test("minimap left-click as a non-Tauren asks for confirmation", function()
	setup(NON_TAUREN)
	click(minimapButton(), "LeftButton")
	H.eq(MooSpeakDB.enabled, false)
	H.truthy(confirmDialog().shown)
end)

H.test("minimap right-click opens and closes the options", function()
	setup()
	H.falsy(options().shown, "options should start hidden")
	click(minimapButton(), "RightButton")
	H.truthy(options().shown)
	click(minimapButton(), "RightButton")
	H.falsy(options().shown)
end)

H.test("minimap icon is greyed out while mooing is off", function()
	setup()
	H.eq(minimapButton().icon.desaturated, true)
	slash("on")
	H.eq(minimapButton().icon.desaturated, false)
end)

H.test("options checkbox toggles mooing through the same Tauren check", function()
	setup(NON_TAUREN)
	options().enableCheck:SetChecked(true) -- the client flips it before OnClick
	click(options().enableCheck)
	H.eq(MooSpeakDB.enabled, false)
	H.truthy(confirmDialog().shown)
	H.eq(options().enableCheck.checked, false, "checkbox must not show on before confirming")
end)

H.test("options can hide the minimap button", function()
	setup()
	options().minimapCheck:SetChecked(false)
	click(options().minimapCheck)
	H.eq(MooSpeakDB.minimap.hide, true)
	H.falsy(minimapButton().shown)
end)

H.test("options can revoke honorary Tauren status", function()
	setup({ race = "Gnome", raceName = "Gnome", db = { honoraryTauren = true, enabled = true } })
	options().honoraryCheck:SetChecked(false)
	click(options().honoraryCheck)
	H.eq(MooSpeakDB.honoraryTauren, false)
	H.eq(MooSpeakDB.enabled, false, "revoking should stop the mooing")
end)

H.test("slash options opens the options window", function()
	setup()
	slash("options")
	H.truthy(options().shown)
end)

H.test("preview command prints moos without sending", function()
	setup()
	slash("preview hello there")
	H.eq(#env.sent, 0)
	H.truthy(#env.printed >= 2, "expected preview output")
end)

return H
