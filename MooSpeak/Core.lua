--[[
MooSpeak glue: hooks the chat edit box to send moos, and adds chat
filters that show "MooSpeak: ..." to anyone running the addon.

Sending uses the edit box hook Blizzard provides for addons
("ChatFrame.OnEditBoxPreSendText"), which fires after slash commands are
parsed and before the text is read and sent. The same shared chat code
ships in WoW Forever, Retail, Mists Classic, TBC Anniversary and
Classic Era.
]]

local addonName, ns = ...
local Codec = ns.Codec

local Core = {}
ns.Core = Core

local PREFIX = "MooSpeak: "
local TAG = "|cffc8a165MooSpeak:|r "

-- Chat types whose outgoing text gets mooed.
local ENCODE_CHAT_TYPES = {
	SAY = true, YELL = true, PARTY = true, RAID = true, RAID_WARNING = true,
	INSTANCE_CHAT = true, GUILD = true, OFFICER = true, WHISPER = true,
	CHANNEL = true,
}

-- Incoming chat events that get translated for addon users.
local FILTER_EVENTS = {
	"CHAT_MSG_SAY", "CHAT_MSG_YELL",
	"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
	"CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
	"CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
	"CHAT_MSG_CHANNEL",
}

local function say(msg)
	DEFAULT_CHAT_FRAME:AddMessage(TAG .. msg)
end

local function inLockdown()
	return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown() == true
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local pending   -- lines waiting for Blizzard to send the first one
local sendingExtra = false

function Core.OnPreSendText(_, editBox)
	pending = nil
	if not (MooSpeakDB and MooSpeakDB.enabled) then return end

	local chatType = editBox:GetChatType()
	if not ENCODE_CHAT_TYPES[chatType] then return end

	local text = editBox:GetText()
	if Codec.IsMoo(text) then return end

	local lines = Codec.Encode(text)
	if not lines then return end

	if #lines > 1 and inLockdown() then
		-- Addons cannot send the extra lines during chat lockdown
		-- (combat in instances), so send this one as typed.
		say("message too long to moo during combat lockdown; sent as typed.")
		return
	end

	pending = { original = text, lines = lines, chatType = chatType, editBox = editBox }
	editBox:SetText(lines[1])
end

-- Runs after Blizzard's C_ChatInfo.SendChatMessage call for the first line.
function Core.AfterSend(_, chatType, languageID, target)
	local p = pending
	if sendingExtra or not p or chatType ~= p.chatType then return end
	pending = nil

	local substitute = ChatFrameUtil and ChatFrameUtil.SubstituteChatMessageBeforeSend
	sendingExtra = true
	for i = 2, #p.lines do
		local line = p.lines[i]
		if substitute then line = substitute(line) end
		C_ChatInfo.SendChatMessage(line, chatType, languageID, target)
	end
	sendingExtra = false

	-- Blizzard records the edit box text in history right after sending;
	-- put the original back so up-arrow recalls what was typed.
	p.editBox:SetText(p.original)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Filters run once per chat window, so cache recent decodes.
local cache, cacheSize = {}, 0
local NOT_MOO = false

local function translate(msg)
	local hit = cache[msg]
	if hit == nil then
		hit = Codec.Decode(msg) or NOT_MOO
		if cacheSize >= 200 then
			cache, cacheSize = {}, 0
		end
		cache[msg] = hit
		cacheSize = cacheSize + 1
	end
	return hit or nil
end

function Core.ChatFilter(_, _, msg, ...)
	if type(msg) ~= "string" then return false end
	local decoded = translate(msg)
	if not decoded then return false end
	return false, PREFIX .. decoded, ...
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- State: enabling, the Tauren check, change notifications
---------------------------------------------------------------------------

Core.ICON = "Interface\\Icons\\Spell_Nature_Polymorph_Cow"
Core.say = say

local listeners = {}

--- Registers fn() to run whenever settings change (UI refresh).
function Core.OnChange(fn)
	listeners[#listeners + 1] = fn
end

local function changed()
	for _, fn in ipairs(listeners) do fn() end
end

function Core.IsEnabled()
	return MooSpeakDB.enabled == true
end

--- True for Tauren and Highmountain Tauren. If the race can't be read,
--- give the benefit of the doubt.
function Core.IsTauren()
	local _, race = UnitRace("player")
	if type(race) ~= "string" or (issecretvalue and issecretvalue(race)) then
		return true
	end
	return race == "Tauren" or race == "HighmountainTauren"
end

local function playerRaceName()
	local name = UnitRace("player")
	if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then
		return "stranger"
	end
	return name
end

function Core.SetEnabled(on)
	MooSpeakDB.enabled = on and true or false
	if on then
		say("ON - your chat is now mooed. Moo!")
	else
		say("OFF - your chat is sent as typed.")
	end
	changed()
end

function Core.SetHonoraryTauren(on)
	MooSpeakDB.honoraryTauren = on and true or false
	if not on and not Core.IsTauren() and Core.IsEnabled() then
		say("the Earth Mother takes back your hooves. Your moo fades away.")
		Core.SetEnabled(false)
	else
		changed()
	end
end

--- Turns mooing on or off. Non-Tauren who aren't honorary Tauren yet
--- must confirm first; nobody is stopped, they just get told off.
function Core.RequestEnable(on)
	if not on then
		Core.SetEnabled(false)
		return
	end
	if Core.IsTauren() or MooSpeakDB.honoraryTauren then
		Core.SetEnabled(true)
		return
	end
	changed() -- keep any checkbox showing "off" until confirmed
	if not ns.UI then
		say("you're not a Tauren! Use /moospeak options to plead your case.")
		return
	end
	ns.UI.ShowConfirm({
		title = "You're not a Tauren!",
		text = "The Earth Mother squints at you.\n\n" ..
			"Those are not hooves, " .. playerRaceName() .. ". " ..
			"Only the Tauren may speak in moos.\n\n" ..
			"Swear you are a cow at heart?",
		accept = "Moo anyway",
		decline = "I'm no cow",
		onAccept = function()
			say("the Earth Mother sighs and grants you honorary hooves.")
			MooSpeakDB.honoraryTauren = true
			Core.SetEnabled(true)
		end,
		onDecline = function()
			say("you open your mouth to moo, but only a confused bleat comes out.")
			changed()
		end,
	})
end

function Core.Toggle()
	Core.RequestEnable(not Core.IsEnabled())
end

local function slashHandler(msg)
	msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()

	if cmd == "" then
		Core.Toggle()
	elseif cmd == "on" then
		Core.RequestEnable(true)
	elseif cmd == "off" then
		Core.RequestEnable(false)
	elseif cmd == "options" or cmd == "config" then
		if ns.UI then ns.UI.ShowOptions() end
	elseif cmd == "status" then
		say(MooSpeakDB.enabled and "ON" or "OFF")
	elseif cmd == "preview" and rest ~= "" then
		local lines = Codec.Encode(rest)
		if not lines then
			say("nothing to moo in that.")
			return
		end
		for _, line in ipairs(lines) do
			say(line)
		end
		say(#lines .. " line(s), " .. #rest .. " characters typed.")
	else
		say("/moospeak - toggle mooing")
		say("/moospeak on | off | status | options")
		say("/moospeak preview <text> - show the moos without sending")
	end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

local function registerFilters()
	local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if not add then
		say("could not find the chat filter API; translations disabled.")
		return
	end
	for _, event in ipairs(FILTER_EVENTS) do
		add(event, Core.ChatFilter)
	end
end

local function onLoad()
	if type(MooSpeakDB) ~= "table" then MooSpeakDB = {} end
	if MooSpeakDB.enabled == nil then MooSpeakDB.enabled = false end
	if MooSpeakDB.honoraryTauren == nil then MooSpeakDB.honoraryTauren = false end
	if type(MooSpeakDB.minimap) ~= "table" then MooSpeakDB.minimap = {} end
	if MooSpeakDB.minimap.angle == nil then MooSpeakDB.minimap.angle = 225 end
	if MooSpeakDB.minimap.hide == nil then MooSpeakDB.minimap.hide = false end

	if EventRegistry and EventRegistry.RegisterCallback then
		EventRegistry:RegisterCallback("ChatFrame.OnEditBoxPreSendText", Core.OnPreSendText, Core)
		hooksecurefunc(C_ChatInfo, "SendChatMessage", Core.AfterSend)
	else
		say("this client has no chat send hook; sending moos is disabled.")
	end

	registerFilters()

	SLASH_MOOSPEAK1 = "/moospeak"
	SLASH_MOOSPEAK2 = "/mspeak"
	SlashCmdList.MOOSPEAK = slashHandler

	if ns.UI then ns.UI.Init() end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, _, name)
	if name == addonName then
		self:UnregisterEvent("ADDON_LOADED")
		onLoad()
	end
end)
