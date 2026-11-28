-- Pick Pocket Forever
--
-- Two chores of a rogue pickpocket farm, done for you:
--
--   Destroy   junkboxes are destroyed as they land in your bags.
--   Sell      everything else you pickpocket is sold when you open a vendor.
--
-- Destroying: the game only lets an addon destroy an item while it is handling
-- a key press or a mouse click of yours. So this cannot fire the instant a
-- junkbox is looted; it destroys one junkbox on each key you press or each click
-- on the world. While farming you press keys all the time, so in practice a
-- junkbox is gone within a moment of arriving.
--
-- Selling: needs no key press. When a merchant window opens, every item on the
-- sell list is sold. The list starts with a handful of named items and grows on
-- its own: anything you loot with Pick Pocket is added to it (grey, white and
-- green items that a vendor will buy). /ppf keep [item] takes an item off the
-- lists for good.
--
-- Nothing is ever destroyed or sold unless it is on one of the two lists.
--
-- This file does the work. Options.lua is the minimap button and the window.

local ADDON, ns = ...

ns.TITLE = "Pick Pocket Forever"
ns.ICON = 133644               -- the Pick Pocket spell icon (Interface\Icons\INV_Misc_Bag_11)

local DEFAULT_DESTROY = { [16882] = true, [16883] = true, [16884] = true, [16885] = true }
local KNOWN_NAMES = {
	[16882] = "Battered Junkbox", [16883] = "Worn Junkbox",
	[16884] = "Sturdy Junkbox", [16885] = "Heavy Junkbox",
}
local HEAVY_JUNKBOX = 16885

-- Sold from the start, matched by name the first time each is seen in a bag.
local SELL_BY_NAME = {
	"Deep Fried Plantains", "Homemade Cherry Pie", "Alterac Swiss", "Fine Aged Cheddar",
	"Moon Harvest Pumpkin", "Soft Banana Bread", "Star Ruby", "Hickory Pipe", "Rogue's Diary",
}

local MAX_DESTROY_QUALITY = 1  -- destroy list: poor (grey) and common (white) only
local MAX_SELL_QUALITY = 2     -- sell list: up to uncommon (green)
local QUEST_CLASS = 12
local REPORT_DELAY = 1.5       -- seconds of quiet before a batch of destroys is reported
local RETRY_AFTER = 2          -- seconds before a slot we acted on is looked at again
local REFUSALS_BEFORE_WARNING = 3
local REFUSAL_PAUSE = 10       -- seconds to back off once the game keeps saying no
local PICK_POCKET = 921
local PICK_WINDOW = 1.5        -- seconds after Pick Pocket in which loot counts as pickpocketed
local LOOT_FIRST_WINDOW = 0.3  -- ...or this long before it, if the loot window won the race
local SELL_EVERY = 0.2         -- seconds between selling passes
local SELL_PER_PASS = 6        -- stacks sold per pass, so the server is not flooded
local SELL_MAX_PASSES = 40
local SELL_WAIT = 0.05         -- seconds between looks for the vendor window
local SELL_WAIT_TRIES = 40     -- ...and how many looks before giving up (2 seconds)

local Container = _G.C_Container
local NumSlots = (Container and Container.GetContainerNumSlots) or _G.GetContainerNumSlots
local RawSlotInfo = (Container and Container.GetContainerItemInfo) or _G.GetContainerItemInfo
local PickupSlot = (Container and Container.PickupContainerItem) or _G.PickupContainerItem
local UseSlot = (Container and Container.UseContainerItem) or _G.UseContainerItem
local ItemInfo = (_G.C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local LAST_BAG = _G.NUM_BAG_SLOTS or 4

local SELL_NAMES = {}
for _, name in ipairs(SELL_BY_NAME) do SELL_NAMES[name:lower()] = true end

-- The saved settings:
--   destroying  destroy junkboxes            selling  sell at vendors
--   learn       add pickpocketed items to the sell list
--   chat        report in the chat window    minimap  where the minimap button is
--   destroy, sell, keep                      the three item lists
--   total, sold, earned                      running counts
local db
-- Should this item be destroyed on sight? Junkboxes on the destroy list go,
-- except Heavy Junkbox when they are being kept.
local function ShouldDestroy(id)
	return db.destroy[id] and not (db.keepHeavy and id == HEAVY_JUNKBOX)
end
local waiting = 0          -- destroy-list items in the bags at the last look
local pending = {}         -- slot key -> time before which to leave that slot alone
local attempts = {}        -- slot key -> item id we asked the game to destroy there
local batch = {}           -- item id -> destroyed since the last chat report
local reportQueued = false
local session = 0
local refusals = 0
local pausedUntil = 0
local warned = false
local hooked = false

local pickAt               -- when Pick Pocket last landed, until its loot is accounted for
local lootIDs = {}         -- item ids in the loot window that last opened
local lootAt = 0           -- ...and when it opened
local unknown = {}         -- pickpocketed items the game has not loaded yet

local merchantOpen = false
local sellRun = 0          -- bumped to cancel a selling run in progress
local sellPasses = 0
local sellWaits = 0        -- times this run has waited for the vendor window to appear
local windowSeen = false   -- the vendor window has been up during this run
local sent = {}            -- slot key -> { id, count, price } handed to the vendor this visit

-- An answer to something you asked for: always shown.
local function Print(msg)
	print("|cffffd200" .. ns.TITLE .. "|r: " .. msg)
end

-- A report of something the addon did by itself: shown unless chat output is off.
local function Say(msg)
	if db.chat then Print(msg) end
end

-- Some values are hidden from addons on this client; never look inside one.
local function Secret(v)
	return issecretvalue and issecretvalue(v) or false
end

local function ItemName(id)
	local name, link = ItemInfo(id)
	return link or name or KNOWN_NAMES[id] or ("item " .. id)
end

local function Money(copper)
	local gold, silver = math.floor(copper / 10000), math.floor(copper % 10000 / 100)
	local parts = {}
	if gold > 0 then parts[#parts + 1] = gold .. "g" end
	if silver > 0 then parts[#parts + 1] = silver .. "s" end
	if copper % 100 > 0 or #parts == 0 then parts[#parts + 1] = (copper % 100) .. "c" end
	return table.concat(parts, " ")
end

-- The container call returns a table on newer clients and a tuple on older ones.
-- Returns item id, locked, stack size, and whether vendors refuse it.
local function SlotItem(bag, slot)
	local first, count, locked, _, _, _, _, _, noValue, itemID = RawSlotInfo(bag, slot)
	if type(first) == "table" then
		return first.itemID, first.isLocked, first.stackCount or 1, first.hasNoValue
	end
	if first == nil then return nil end
	return itemID, locked, count or 1, noValue
end

local function EachSlot(visit)
	for bag = 0, LAST_BAG do
		for slot = 1, NumSlots(bag) or 0 do
			local id, locked, count, noValue = SlotItem(bag, slot)
			if id and visit(bag, slot, id, locked, count, noValue) then return end
		end
	end
end

--------------------------------------------------------------------------
-- Destroying
--------------------------------------------------------------------------

local function Recount()
	waiting = 0
	EachSlot(function(_, _, id)
		if ShouldDestroy(id) then waiting = waiting + 1 end
	end)
end

local function Report()
	reportQueued = false
	for id, count in pairs(batch) do
		Say(("destroyed %d x %s  (%d this session)"):format(count, ItemName(id), session))
	end
	wipe(batch)
end

local function Destroyed(id)
	session = session + 1
	db.total = (db.total or 0) + 1
	batch[id] = (batch[id] or 0) + 1
	if not reportQueued then
		reportQueued = true
		C_Timer.After(REPORT_DELAY, Report)
	end
end

-- Runs inside a key press or mouse click. Destroys at most one item per press.
local function OnInput()
	if waiting == 0 or not db.destroying then return end
	local now = GetTime()
	if now < pausedUntil then return end
	-- Never take over a cursor that is already doing something: an item being
	-- dragged, or a spell such as Pick Lock waiting for its target.
	if GetCursorInfo() or SpellIsTargeting() or UnitIsDeadOrGhost("player") then return end

	local bag, slot, id
	EachSlot(function(b, s, i, locked)
		if not ShouldDestroy(i) or locked then return false end
		local hold = pending[b * 1000 + s]
		if hold and hold > now then return false end
		bag, slot, id = b, s, i
		return true
	end)
	if not bag then return end
	local key = bag * 1000 + slot
	pending[key] = now + RETRY_AFTER

	-- Coming back to a slot we already acted on, and the same item is still
	-- there: the last attempt did not take.
	if attempts[key] == id then
		refusals = refusals + 1
		if refusals >= REFUSALS_BEFORE_WARNING then
			refusals = 0
			pausedUntil = now + REFUSAL_PAUSE
			if not warned then
				warned = true
				Print("the game is not letting this addon destroy items. Nothing was lost. "
					.. "It will keep trying quietly; /ppf destroying off stops it.")
			end
			return
		end
	end

	PickupSlot(bag, slot)
	local kind, cursorID = GetCursorInfo()
	if kind ~= "item" or cursorID ~= id then
		-- Not what we expected to be holding. Put it back and leave it alone.
		if kind then ClearCursor() end
		return
	end
	attempts[key] = id
	DeleteCursorItem()
	-- If the game said no, the item is still in hand: put it back.
	if GetCursorInfo() then ClearCursor() end
end

-- The bags changed. Any slot we acted on that no longer holds that item is a
-- confirmed kill; that is the only thing counted as destroyed.
local function ConfirmDestroyed()
	for key, id in pairs(attempts) do
		if SlotItem(math.floor(key / 1000), key % 1000) ~= id then
			attempts[key] = nil
			refusals = 0
			Destroyed(id)
		end
	end
end

-- A hidden frame that sees every key press and passes it straight on. The pass-on
-- is set and confirmed BEFORE the frame is allowed to hear the keyboard, so it can
-- never end up swallowing your keys.
local catcher = CreateFrame("Frame", "PickPocketForeverInput", UIParent)

local function HookInput()
	if hooked or InCombatLockdown() then return end
	catcher:SetPropagateKeyboardInput(true)
	if catcher.GetPropagateKeyboardInput and not catcher:GetPropagateKeyboardInput() then return end
	catcher:SetScript("OnKeyDown", OnInput)
	catcher:EnableKeyboard(true)
	WorldFrame:HookScript("OnMouseDown", OnInput)
	hooked = true
end

--------------------------------------------------------------------------
-- Selling
--------------------------------------------------------------------------

-- Is this item on the sell list? Named starters join the list by id the first
-- time they are seen, so /ppf list and /ppf keep treat them like the rest.
local function ShouldSell(id)
	if db.sell[id] then return true end
	if db.keep[id] or db.destroy[id] then return false end
	local name = ItemInfo(id)
	if name and SELL_NAMES[name:lower()] then
		db.sell[id] = true
		return true
	end
	return false
end

local function VendorPrice(id)
	local _, _, _, _, _, _, _, _, _, _, price = ItemInfo(id)
	return price or 0
end

local function WindowUp()
	return MerchantFrame and MerchantFrame:IsShown()
end

-- Count what really left the bags, and say so.
local function SellSummary()
	local stacks, items, copper, unsold = 0, 0, 0, 0
	for key, rec in pairs(sent) do
		if SlotItem(math.floor(key / 1000), key % 1000) ~= rec.id then
			stacks = stacks + 1
			items = items + rec.count
			copper = copper + rec.count * rec.price
		else
			unsold = unsold + 1
		end
	end
	wipe(sent)
	db.sold = (db.sold or 0) + items
	db.earned = (db.earned or 0) + copper
	if stacks > 0 then
		Say(("sold %d item%s for %s."):format(items, items == 1 and "" or "s", Money(copper)))
	end
	if unsold > 0 then
		Say(("%d stack%s did not sell and %s still in your bags.")
			:format(unsold, unsold == 1 and "" or "s", unsold == 1 and "is" or "are"))
	end
end

local function StopSelling()
	sellRun = sellRun + 1
	-- Give the last sales a moment to leave the bags before counting them.
	C_Timer.After(0.5, SellSummary)
end

local function SellPass(run)
	if run ~= sellRun then return end
	if not merchantOpen or InCombatLockdown() or not db.selling then
		StopSelling()
		return
	end
	if not WindowUp() then
		-- The game announces a vendor a moment before its window is on screen.
		-- Using an item before then would eat or equip it instead of selling it,
		-- so wait for the window. If it was up and has gone, or never comes, stop.
		sellWaits = sellWaits + 1
		if windowSeen or sellWaits > SELL_WAIT_TRIES then
			if not windowSeen then
				Say("the vendor window never appeared, so nothing was sold.")
			end
			StopSelling()
		else
			C_Timer.After(SELL_WAIT, function() SellPass(run) end)
		end
		return
	end
	windowSeen = true
	local used, left = 0, 0
	EachSlot(function(bag, slot, id, locked, count, noValue)
		if noValue or not ShouldSell(id) then return false end
		local price = VendorPrice(id)
		if price <= 0 then return false end
		left = left + 1
		if locked then return false end        -- already on its way to the vendor
		local key = bag * 1000 + slot
		sent[key] = sent[key] or { id = id, count = count, price = price }
		UseSlot(bag, slot)
		used = used + 1
		return used >= SELL_PER_PASS
	end)
	sellPasses = sellPasses + 1
	if left == 0 or sellPasses >= SELL_MAX_PASSES then
		StopSelling()
	else
		C_Timer.After(SELL_EVERY, function() SellPass(run) end)
	end
end

local function StartSelling()
	if not db.selling then return end
	sellRun = sellRun + 1
	sellPasses, sellWaits, windowSeen = 0, 0, false
	wipe(sent)
	SellPass(sellRun)
end

--------------------------------------------------------------------------
-- Learning what Pick Pocket gives
--------------------------------------------------------------------------

local function SpellName(id)
	if _G.C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
	if _G.GetSpellInfo then
		local name = GetSpellInfo(id)
		if type(name) == "table" then return name.name end
		return name
	end
end

local function IsPickPocket(spellID)
	if not spellID or Secret(spellID) then return false end
	if spellID == PICK_POCKET then return true end
	local name, wanted = SpellName(spellID), SpellName(PICK_POCKET)
	return name ~= nil and not Secret(name) and name == wanted
end

-- The sell list only grows while selling is switched on.
local function Learning()
	return db.selling and db.learn
end

local function Learn(id)
	if db.sell[id] or db.keep[id] or db.destroy[id] then return end
	local name, _, quality, _, _, _, _, _, _, _, price, classID = ItemInfo(id)
	if not name then
		unknown[id] = true      -- not loaded yet; GET_ITEM_INFO_RECEIVED brings it back here
		return
	end
	unknown[id] = nil
	if quality > MAX_SELL_QUALITY or classID == QUEST_CLASS or not price or price <= 0 then return end
	db.sell[id] = true
	Say(("pickpocketed %s - it will be sold at vendors from now on. /ppf keep %d to keep it.")
		:format(ItemName(id), id))
end

-- Loot that comes off a corpse is not pickpocketed, whatever the timing says.
local function FromCorpse(slot)
	if not GetLootSourceInfo then return false end
	local source = GetLootSourceInfo(slot)
	local target = UnitGUID("target")
	if not source or not target or Secret(source) or Secret(target) then return false end
	return source == target and UnitIsDead("target")
end

-- Note what is in the loot window that just opened.
local function ReadLoot()
	wipe(lootIDs)
	lootAt = GetTime()
	for slot = 1, GetNumLootItems() or 0 do
		local link = GetLootSlotLink(slot)
		if link and not Secret(link) and type(link) == "string" and not FromCorpse(slot) then
			local id = tonumber(link:match("item:(%d+)"))
			if id then lootIDs[#lootIDs + 1] = id end
		end
	end
end

-- Pick Pocket and its loot window arrive as two separate events, in either
-- order. Loot counts as pickpocketed when the two are close together: the window
-- may open up to PICK_WINDOW after the cast, or a hair before it. Each cast
-- accounts for one loot window only.
local function LearnFromLoot()
	if not (pickAt and Learning()) or #lootIDs == 0 then return end
	local gap = lootAt - pickAt
	if gap > PICK_WINDOW or gap < -LOOT_FIRST_WINDOW then return end
	pickAt = nil
	for _, id in ipairs(lootIDs) do Learn(id) end
end

--------------------------------------------------------------------------
-- Settings, shared with the options window
--------------------------------------------------------------------------

function ns.Get(field)
	return db and db[field]
end

-- Switch one of destroying / selling / learn / chat on or off.
function ns.Set(field, on)
	db[field] = on and true or false
	if field == "destroying" or field == "keepHeavy" then
		Recount()
	elseif field == "selling" and db.selling and merchantOpen then
		StartSelling()
	end
	if ns.Refresh then ns.Refresh() end      -- keep the window's ticks in step
end

--------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------

local function ParseItem(text)
	local id = text:match("item:(%d+)") or text:match("^%s*(%d+)%s*$")
	return id and tonumber(id)
end

local function Sorted(set)
	local ids = {}
	for id in pairs(set) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function PrintSet(title, set)
	local ids = Sorted(set)
	if #ids == 0 then return false end
	Print(title)
	for _, id in ipairs(ids) do
		print(("   %s  (%d)"):format(ItemName(id), id))
	end
	return true
end

local function ListItems()
	if not PrintSet("destroys:", db.destroy) then Print("destroys nothing.") end
	if not PrintSet("sells at vendors:", db.sell) then Print("sells nothing yet.") end
	-- Named starters that have not been seen in a bag yet have no id to show.
	local seen, unseen = {}, {}
	for id in pairs(db.sell) do
		local name = ItemInfo(id)
		if name then seen[name:lower()] = true end
	end
	for id in pairs(db.keep) do
		local name = ItemInfo(id)
		if name then seen[name:lower()] = true end
	end
	for _, name in ipairs(SELL_BY_NAME) do
		if not seen[name:lower()] then unseen[#unseen + 1] = name end
	end
	if #unseen > 0 then
		print("   also, once seen in your bags: " .. table.concat(unseen, ", "))
	end
	PrintSet("always keeps:", db.keep)
end

local function OnOff(flag)
	return flag and "|cff40ff40on|r" or "|cffff4040off|r"
end

local function Status()
	Print(("destroying junkboxes %s, selling pickpocketed items %s.")
		:format(OnOff(db.destroying), OnOff(db.selling)))
	print(("   junkboxes: %d in your bags now, %d destroyed this session, %d in total")
		:format(waiting, session, db.total or 0))
	print(("   vendors: %d items sold for %s so far; learning from Pick Pocket %s, chat reports %s")
		:format(db.sold or 0, Money(db.earned or 0), OnOff(db.learn), OnOff(db.chat)))
	if db.destroying and not hooked then
		print("   waiting for combat to end before it can start destroying.")
	end
	print("   /ppf                       open the options window")
	print("   /ppf on | off              both chores on or off")
	print("   /ppf destroying on | off   destroy junkboxes")
	print("   /ppf selling on | off      sell at vendors")
	print("   /ppf learn on | off        add what you pickpocket to the sell list")
	print("   /ppf heavy on | off        keep Heavy Junkboxes instead of destroying them")
	print("   /ppf chat on | off         reports in the chat window")
	print("   /ppf list                  what is destroyed, sold and kept")
	print("   /ppf sell [item]           sell this item at vendors")
	print("   /ppf destroy [item]        destroy this item on sight")
	print("   /ppf keep [item]           never sell or destroy this item")
	print("   /ppf reset                 lists back to how they started")
	print("   [item] is an item shift-clicked into the chat box, or its number.")
end

-- on/off with no word flips it.
local function Toggle(field, word, label)
	local on = not db[field]
	if word == "on" then on = true elseif word == "off" then on = false end
	ns.Set(field, on)
	Print(label .. " " .. OnOff(db[field]) .. ".")
end

-- Checks an item before it goes on a list. Returns true if it may.
local function MayList(id, verb, maxQuality)
	if not id then
		Print(("usage: /ppf %s [item]  -  shift-click the item into the chat box."):format(verb))
		return false
	end
	local name, _, quality, _, _, _, _, _, _, _, price, classID = ItemInfo(id)
	if not name then
		Print("the game has not loaded that item yet. Try again in a moment.")
	elseif classID == QUEST_CLASS then
		Print(ItemName(id) .. " is a quest item and cannot be listed.")
	elseif quality > maxQuality then
		Print(("only %s items can be on the %s list; %s is better than that.")
			:format(maxQuality == 1 and "grey and white" or "grey, white and green", verb, ItemName(id)))
	elseif verb == "sell" and (not price or price <= 0) then
		Print("vendors do not buy " .. ItemName(id) .. ".")
	else
		return true
	end
	return false
end

SLASH_PICKPOCKETFOREVER1 = "/ppf"
SLASH_PICKPOCKETFOREVER2 = "/pickpocketforever"
SLASH_PICKPOCKETFOREVER3 = "/junkbox"      -- what the addon answered to when it was Junkbox Toss
SlashCmdList.PICKPOCKETFOREVER = function(msg)
	local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()

	if cmd == "" then
		if ns.TogglePanel then ns.TogglePanel() else Status() end

	elseif cmd == "on" or cmd == "off" then
		ns.Set("destroying", cmd == "on")
		ns.Set("selling", cmd == "on")
		Print(cmd == "on" and "|cff40ff40on|r." or "|cffff4040off|r. Nothing will be destroyed or sold.")

	elseif cmd == "destroying" then
		Toggle("destroying", rest:lower(), "destroying junkboxes")

	elseif cmd == "selling" then
		Toggle("selling", rest:lower(), "selling at vendors")

	elseif cmd == "learn" then
		Toggle("learn", rest:lower(), "learning from Pick Pocket")

	elseif cmd == "heavy" or cmd == "keepheavy" then
		Toggle("keepHeavy", rest:lower(), "keeping Heavy Junkboxes")

	elseif cmd == "chat" then
		Toggle("chat", rest:lower(), "chat reports")

	elseif cmd == "quiet" then
		Toggle("chat", nil, "chat reports")

	elseif cmd == "list" then
		ListItems()

	elseif cmd == "destroy" or cmd == "add" then
		local id = ParseItem(rest)
		if MayList(id, "destroy", MAX_DESTROY_QUALITY) then
			db.destroy[id], db.sell[id], db.keep[id] = true, nil, nil
			Recount()
			Print("will destroy " .. ItemName(id) .. " on sight.")
		end

	elseif cmd == "sell" then
		local id = ParseItem(rest)
		if MayList(id, "sell", MAX_SELL_QUALITY) then
			db.sell[id], db.destroy[id], db.keep[id] = true, nil, nil
			Recount()
			Print("will sell " .. ItemName(id) .. " at vendors.")
			if merchantOpen then StartSelling() end
		end

	elseif cmd == "keep" or cmd == "remove" then
		local id = ParseItem(rest)
		if not id then
			Print("usage: /ppf keep [item]  -  shift-click the item into the chat box.")
		else
			db.keep[id], db.sell[id], db.destroy[id] = true, nil, nil
			Recount()
			Print("will always keep " .. ItemName(id) .. ".")
		end

	elseif cmd == "reset" then
		wipe(db.destroy)
		wipe(db.sell)
		wipe(db.keep)
		for id in pairs(DEFAULT_DESTROY) do db.destroy[id] = true end
		Recount()
		Print("lists reset: the four junkboxes are destroyed, and what you pickpocket is learned again.")

	else
		Status()
	end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local function Setup()
	PickPocketForeverDB = PickPocketForeverDB or {}
	db = PickPocketForeverDB
	-- Before 1.2.0 one "enabled" switch covered both chores, and chat reports
	-- were turned off with "quiet".
	if db.destroying == nil then db.destroying = db.enabled ~= false end
	if db.selling == nil then db.selling = true end
	if db.enabled == false then db.selling = false end
	db.enabled = nil
	if db.chat == nil then db.chat = not db.quiet end
	db.quiet = nil
	if db.learn == nil then db.learn = true end
	if db.keepHeavy == nil then db.keepHeavy = true end
	if type(db.minimap) ~= "table" then db.minimap = {} end
	if type(db.destroy) ~= "table" then
		-- 1.0.0 kept the destroy list under "items".
		db.destroy = type(db.items) == "table" and db.items or {}
		if db.items == nil then
			for id in pairs(DEFAULT_DESTROY) do db.destroy[id] = true end
		end
	end
	db.items = nil
	if type(db.sell) ~= "table" then db.sell = {} end
	if type(db.keep) ~= "table" then db.keep = {} end
	db.total = db.total or 0
	db.sold = db.sold or 0
	db.earned = db.earned or 0
end

local function Greeting()
	local doing = {}
	if db.destroying then doing[#doing + 1] = "junkboxes are destroyed as you play" end
	if db.selling then doing[#doing + 1] = "pickpocketed items are sold at vendors" end
	if #doing == 0 then return "destroying and selling are both off. /ppf for options." end
	return table.concat(doing, ", ") .. ". /ppf for options."
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_ENABLED",
	"MERCHANT_SHOW", "MERCHANT_CLOSED", "UNIT_SPELLCAST_SUCCEEDED", "LOOT_READY", "LOOT_OPENED",
	"GET_ITEM_INFO_RECEIVED" }) do
	events:RegisterEvent(event)
end

events:SetScript("OnEvent", function(_, event, arg1, _, arg3)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON then Setup() end
		return
	end
	if not db then return end

	if event == "PLAYER_LOGIN" then
		HookInput()
		Recount()
		if ns.CreateMinimapButton then ns.CreateMinimapButton() end
		Say(Greeting())

	elseif event == "BAG_UPDATE_DELAYED" then
		ConfirmDestroyed()
		Recount()

	elseif event == "PLAYER_REGEN_ENABLED" then
		HookInput()

	elseif event == "MERCHANT_SHOW" then
		merchantOpen = true
		StartSelling()

	elseif event == "MERCHANT_CLOSED" then
		if merchantOpen then
			merchantOpen = false
			StopSelling()
		end

	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if arg1 == "player" and IsPickPocket(arg3) then
			pickAt = GetTime()
			LearnFromLoot()     -- in case the loot window opened first
		end

	elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
		ReadLoot()
		LearnFromLoot()

	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if arg1 and unknown[arg1] and Learning() then Learn(arg1) end
	end
end)
