-- Pick Pocket Forever: the minimap button and the options window it opens.
--
-- The button goes through LibDataBroker and LibDBIcon, like most addons' do, so
-- it can be dragged round the minimap and is picked up by button collectors.

local ADDON, ns = ...

local BUTTON_NAME = "PickPocketForever"
local PANEL_NAME = "PickPocketForeverPanel"
local PARCHMENT = "Interface\\ACHIEVEMENTFRAME\\UI-GuildAchievement-Parchment-Horizontal-Desaturated.png"
local WIDTH, HEIGHT, FOOT = 340, 262, 40
local MARGIN = 16
local ROW, HEADING_ROW, GROUP_GAP = 24, 20, 8

-- What the window shows, top to bottom. "field" is the saved setting a tick box
-- switches, through ns.Get and ns.Set.
local LAYOUT = {
	{ heading = "Automation" },
	{ field = "destroying", label = "Destroy junkboxes automatically",
		tip = "Junkboxes are destroyed as they land in your bags.\n\n"
			.. "The game only allows this while you press a key or click, so each one goes on your "
			.. "next key press.\n\nDestroyed items cannot be recovered." },
	{ field = "keepHeavy", label = "Keep Heavy Junkboxes",
		tip = "While this is on, Heavy Junkbox stays in your bags instead of being destroyed. "
			.. "Sturdy, Worn and Battered junkboxes are still destroyed.\n\n"
			.. "Turn this off to destroy Heavy Junkboxes like the rest." },
	{ field = "selling", label = "Sell pickpocketed items automatically",
		tip = "When you open a vendor, everything on the sell list is sold.\n\n"
			.. "The list grows by itself: grey, white and green items you loot with Pick Pocket are "
			.. "added to it. /ppf list shows it, and /ppf keep [item] takes an item off it." },
	{ heading = "Chat" },
	{ field = "chat", label = "Show output in chat window",
		tip = "Say in the chat window what was destroyed, what was sold and for how much, and "
			.. "what was added to the sell list." },
}

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

local panel
local boxes = {}      -- field -> its tick box

local function ShowTip(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(self.title)
	GameTooltip:AddLine(self.tip, 1, 1, 1, true)
	GameTooltip:Show()
end

local function HideTip()
	GameTooltip:Hide()
end

local function Bar(height, anchor, r, g, b, a)
	local bar = panel:CreateTexture(nil, "BORDER")
	bar:SetTexture(PARCHMENT)
	bar:SetSize(WIDTH, height)
	bar:SetPoint(anchor)
	bar:SetVertexColor(r, g, b, a)
end

local function TickBox(item, y)
	local box = CreateFrame("CheckButton", nil, panel, "ChatConfigCheckButtonTemplate")
	box:SetPoint("TOPLEFT", MARGIN, y)
	box.label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	box.label:SetPoint("LEFT", 20, 0)
	box.label:SetText(item.label)
	box:SetHitRectInsets(0, -box.label:GetStringWidth() + 4, 0, 0)   -- the words are clickable too
	box.title, box.tip = item.label, item.tip
	box:SetScript("OnEnter", ShowTip)
	box:SetScript("OnLeave", HideTip)
	box:SetScript("OnClick", function(self)
		ns.Set(item.field, self:GetChecked() and true or false)
	end)
	boxes[item.field] = box
end

local function CreatePanel()
	panel = CreateFrame("Frame", PANEL_NAME, UIParent)
	table.insert(UISpecialFrames, PANEL_NAME)        -- Esc closes it
	panel:Hide()
	panel:SetSize(WIDTH, HEIGHT)
	panel:SetPoint("CENTER")
	panel:SetFrameStrata("DIALOG")
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:SetMovable(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
	panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

	local back = panel:CreateTexture(nil, "BACKGROUND")
	back:SetAllPoints()
	back:SetColorTexture(0.05, 0.05, 0.05, 0.9)
	Bar(HEIGHT - FOOT, "TOP", 0.7, 0.7, 0.7, 0.7)
	Bar(FOOT, "BOTTOM", 0.5, 0.5, 0.5, 1.0)

	local icon = panel:CreateTexture(nil, "ARTWORK")
	icon:SetSize(32, 32)
	icon:SetPoint("TOPLEFT", MARGIN, -14)
	icon:SetTexture(ns.ICON)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -1)
	title:SetText(ns.TITLE)

	local version = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	version:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	version:SetText(GetMetadata and GetMetadata(ADDON, "Version") or "")

	local close = CreateFrame("Button", nil, panel)
	close:SetSize(30, 30)
	close:SetPoint("TOPRIGHT", 0, 0)
	close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
	close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
	close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
	close:SetScript("OnClick", function() panel:Hide() end)

	local y = -62
	for _, item in ipairs(LAYOUT) do
		if item.heading then
			if y < -62 then y = y - GROUP_GAP end
			local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
			heading:SetPoint("TOPLEFT", MARGIN, y)
			heading:SetText(item.heading)
			y = y - HEADING_ROW
		else
			TickBox(item, y)
			y = y - ROW
		end
	end

	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOMLEFT", MARGIN, 14)
	hint:SetText("/ppf help lists the other commands.")

	panel:SetScript("OnShow", ns.Refresh)
end

-- Make the tick boxes match the saved settings.
function ns.Refresh()
	if not panel then return end
	for field, box in pairs(boxes) do
		box:SetChecked(ns.Get(field) and true or false)
	end
end

function ns.TogglePanel()
	if not panel then CreatePanel() end
	if panel:IsShown() then panel:Hide() else panel:Show() end
end

-- Called once, at login, when the saved settings are in.
function ns.CreateMinimapButton()
	local broker = LibStub and LibStub("LibDataBroker-1.1", true)
	local buttons = LibStub and LibStub("LibDBIcon-1.0", true)
	if not (broker and buttons) or buttons:IsRegistered(BUTTON_NAME) then return end
	local launcher = broker:NewDataObject(BUTTON_NAME, {
		type = "launcher",
		text = ns.TITLE,
		icon = ns.ICON,
		OnClick = function() ns.TogglePanel() end,
		OnTooltipShow = function(tooltip)
			tooltip:AddLine(ns.TITLE)
			tooltip:AddLine("Click to open the options.", 1, 1, 1)
		end,
	})
	if launcher then buttons:Register(BUTTON_NAME, launcher, ns.Get("minimap")) end
end
