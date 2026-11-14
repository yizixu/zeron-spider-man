--!strict
local M = {}

export type SessionItem = {
	id: string,
	title: string,
	status: string,
	branch: string?,
	updated: number,
}

export type WindowInfo = {
	label: string,
	used: number,
	remaining: number,
	resets_at: number?,
}

export type AccountUsage = {
	provider: string,
	account: string,
	active: boolean,
	plan: string?,
	error: string?,
	limited_until: number?,
	windows: { WindowInfo },
	min_remaining: number?,
}

export type SignalEvent = {
	kind: string, -- "attention" | "error" | "done" | "quota"
	title: string,
	body: string,
	session: string?,
	at: number,
}

local USAGE_LIST: State<{ AccountUsage }> = ui.state("spider_radar_usage", {} :: { AccountUsage })
local MIN_ACTIVE_QUOTA: State<number?> = ui.state("spider_radar_min_quota", nil :: number?)
local EVENTS: State<{ SignalEvent }> = ui.state("spider_radar_events", {} :: { SignalEvent })
local REFRESHING: State<boolean> = ui.state("spider_radar_refreshing", false)
local HIDDEN_REV: State<number> = ui.state("spider_radar_hidden_rev", 0)
local EVENTS_REV: State<number> = ui.state("spider_radar_events_rev", 0)
local USAGE_REV: State<number> = ui.state("spider_radar_usage_rev", 0)

local zeron_ref: any = nil
local notify_setting: any = nil
local warn_pct_setting: any = nil
local hidden_store: any = nil
local seeded_store: any = nil
local wired = false
local wired_zeron: any = nil
local setting_wired_zeron: any = nil
local stop_fns: { () -> () } = {}
local threshold_stop: (() -> ())? = nil
local fetch_seq = 0
local refresh_seq = 0

-- Providers that commonly remain in cached usage even when disabled/uninstalled
-- or when they emit no quota windows; only applied on initial auto-filter seed.
local INITIAL_INACTIVE_PROVIDERS: { [string]: boolean } = {
	["claude-code"] = true,
	["devin"] = true,
	["grok"] = true,
	["opencode"] = true,
	["pi"] = true,
	["antigravity"] = true,
	["cursor"] = true,
	["hermes"] = true,
}

local function current_hidden_map(): { [string]: boolean }
	if not hidden_store then
		return {}
	end
	local raw = hidden_store:peek()
	if type(raw) == "table" then
		return raw
	end
	return {}
end

local function shared_disabled_map(): { [string]: boolean }
	local disabled: { [string]: boolean } = {}
	pcall(function()
		local agents_state = ui.shared("agents", nil :: any)
		local now = if agents_state then agents_state:peek() else nil
		if type(now) == "table" and type(now.list) == "table" then
			for _, ag in now.list do
				if type(ag) == "table" and type(ag.id) == "string" and ag.enabled == false then
					disabled[ag.id] = true
				end
			end
		end
	end)
	return disabled
end

local function recompute_min_quota(list: { AccountUsage })
	local hidden = current_hidden_map()
	local min_active: number? = nil
	for _, acct in list do
		if not hidden[acct.provider] and acct.active and acct.min_remaining ~= nil and (not acct.error or acct.error == "") then
			if min_active == nil or acct.min_remaining < min_active then
				min_active = acct.min_remaining
			end
		end
	end
	MIN_ACTIVE_QUOTA:set(min_active)
end

local function push_event(kind: string, title: string, body: string, session: string?)
	local prev = EVENTS:peek()
	local next_list: { SignalEvent } = {
		{ kind = kind, title = title, body = body, session = session, at = os.time() },
	}
	for i = 1, math.min(#prev, 14) do
		table.insert(next_list, prev[i])
	end
	EVENTS:set(next_list)
	EVENTS_REV:set(EVENTS_REV:peek() + 1)
end

local function session_title(chat_id: string?): string
	if not chat_id or not zeron_ref then
		return "Session"
	end
	local all = zeron_ref.sessions() or {}
	local s = all[chat_id]
	if s and type(s.title) == "string" and s.title ~= "" then
		return s.title
	end
	return chat_id
end

local function parse_usage(rows: any)
	if type(rows) ~= "table" then
		return
	end
	local shared_off = shared_disabled_map()
	local parsed: { AccountUsage } = {}
	for _, r in rows do
		if type(r) == "table" then
			local prov = tostring(r.provider or "agent")
			local engine_disabled = r.enabled == false or r.disabled == true or r.available == false or shared_off[prov] == true
			if not engine_disabled then
				local wins: { WindowInfo } = {}
				local acct_min: number? = nil
				for _, w in r.windows or {} do
					if type(w) == "table" then
						local rem = tonumber(w.remaining)
						local used = tonumber(w.used)
						if rem == nil and used ~= nil then
							rem = math.max(0, 100 - used)
						elseif used == nil and rem ~= nil then
							used = math.max(0, 100 - rem)
						end
						if rem ~= nil then
							table.insert(wins, {
								label = tostring(w.label or "window"),
								used = used or 0,
								remaining = rem,
								resets_at = tonumber(w.resets_at),
							})
							if acct_min == nil or rem < acct_min then
								acct_min = rem
							end
						end
					end
				end
				table.insert(parsed, {
					provider = prov,
					account = tostring(r.account or ""),
					active = r.active == true,
					plan = if type(r.plan) == "string" then r.plan else nil,
					error = if type(r.error) == "string" then r.error else nil,
					limited_until = tonumber(r.limited_until),
					windows = wins,
					min_remaining = acct_min,
				})
			end
		end
	end
	table.sort(parsed, function(a: AccountUsage, b: AccountUsage): boolean
		if a.active ~= b.active then
			return a.active
		end
		return a.provider < b.provider
	end)

	if seeded_store and hidden_store and not seeded_store:peek() and #parsed > 0 then
		seeded_store:set(true)
		local init_hidden: { [string]: boolean } = {}
		local any_visible = false
		for _, acct in parsed do
			local has_err = acct.error ~= nil and acct.error ~= ""
			if #acct.windows == 0 or has_err or INITIAL_INACTIVE_PROVIDERS[acct.provider] then
				init_hidden[acct.provider] = true
			else
				any_visible = true
			end
		end
		if any_visible then
			hidden_store:set(init_hidden)
		else
			-- Keep at least accounts with valid windows visible if nothing else matched
			local fallback_hidden: { [string]: boolean } = {}
			for _, acct in parsed do
				if #acct.windows == 0 or (acct.error ~= nil and acct.error ~= "") then
					fallback_hidden[acct.provider] = true
				end
			end
			hidden_store:set(fallback_hidden)
		end
		HIDDEN_REV:set(HIDDEN_REV:peek() + 1)
	end

	USAGE_LIST:set(parsed)
	recompute_min_quota(parsed)
	USAGE_REV:set(USAGE_REV:peek() + 1)
end

function M.fetch_usage()
	if not zeron_ref then
		return
	end
	fetch_seq += 1
	local seq = fetch_seq
	local z = zeron_ref
	local ok, promise = pcall(function()
		return z.usage()
	end)
	if not ok or not promise then
		return
	end
	promise:after(function(rows: any)
		if seq ~= fetch_seq or zeron_ref ~= z then
			return
		end
		parse_usage(rows)
	end, function(_err: any)
		if seq ~= fetch_seq or zeron_ref ~= z then
			return
		end
		-- Clear stale cached quota when permission is revoked, service is offline, or read fails.
		USAGE_LIST:set({})
		MIN_ACTIVE_QUOTA:set(nil)
		USAGE_REV:set(USAGE_REV:peek() + 1)
	end)
end

function M.refresh_usage()
	if not zeron_ref or REFRESHING:peek() then
		return
	end
	refresh_seq += 1
	local rseq = refresh_seq
	local z = zeron_ref
	REFRESHING:set(true)
	local ok, promise = pcall(function()
		return z.usage_refresh()
	end)
	if not ok or not promise then
		REFRESHING:set(false)
		return
	end
	promise:after(function()
		if rseq ~= refresh_seq or zeron_ref ~= z then
			return
		end
		REFRESHING:set(false)
		M.fetch_usage()
	end, function(err: any)
		if rseq ~= refresh_seq or zeron_ref ~= z then
			return
		end
		REFRESHING:set(false)
		local reason = z.reason(err)
		if reason == "paced" then
			z.toast(z.s("hub.refresh_paced"))
		else
			z.toast(z.s("hub.refresh_failed"))
		end
	end)
end

function M.refreshing(): boolean
	return REFRESHING:get()
end

function M.usage_accounts(): { AccountUsage }
	return USAGE_LIST:get()
end

function M.hidden_rev(): number
	return HIDDEN_REV:get()
end

function M.events_rev(): number
	return EVENTS_REV:get()
end

function M.usage_rev(): number
	return USAGE_REV:get()
end

function M.is_hidden(provider: string): boolean
	local _rev = HIDDEN_REV:get()
	return current_hidden_map()[provider] == true
end

function M.visible_accounts(): { AccountUsage }
	local _rev = HIDDEN_REV:get()
	local hidden = current_hidden_map()
	local out: { AccountUsage } = {}
	for _, acct in USAGE_LIST:get() do
		if not hidden[acct.provider] then
			table.insert(out, acct)
		end
	end
	return out
end

function M.toggle_provider(provider: string)
	if not hidden_store then
		return
	end
	local next_map = table.clone(current_hidden_map())
	if next_map[provider] then
		next_map[provider] = nil
	else
		next_map[provider] = true
	end
	hidden_store:set(next_map)
	HIDDEN_REV:set(HIDDEN_REV:peek() + 1)
	recompute_min_quota(USAGE_LIST:peek())
end

function M.show_all_providers()
	if not hidden_store then
		return
	end
	hidden_store:set({})
	HIDDEN_REV:set(HIDDEN_REV:peek() + 1)
	recompute_min_quota(USAGE_LIST:peek())
end

function M.hide_inactive_providers()
	if not hidden_store then
		return
	end
	local next_map: { [string]: boolean } = {}
	for _, acct in USAGE_LIST:peek() do
		if #acct.windows == 0 or (acct.error ~= nil and acct.error ~= "") then
			next_map[acct.provider] = true
		end
	end
	hidden_store:set(next_map)
	HIDDEN_REV:set(HIDDEN_REV:peek() + 1)
	recompute_min_quota(USAGE_LIST:peek())
end

function M.min_quota(): number?
	return MIN_ACTIVE_QUOTA:get()
end

function M.events(): { SignalEvent }
	return EVENTS:get()
end

function M.warn_threshold(): number
	if warn_pct_setting then
		return tonumber(warn_pct_setting:get()) or 15
	end
	return 15
end

function M.summary(): {
	working: { SessionItem },
	attention: { SessionItem },
	failed: { SessionItem },
	min_quota: number?,
	low_quota: boolean,
}
	local working: { SessionItem } = {}
	local attention: { SessionItem } = {}
	local failed: { SessionItem } = {}
	if zeron_ref then
		local all = zeron_ref.sessions() or {}
		for sid, s in all do
			local st = tostring(s.status or "")
			if st == "working" or st == "connecting" or st == "waiting" then
				table.insert(working, {
					id = tostring(s.id or sid),
					title = if type(s.title) == "string" and s.title ~= "" then s.title else tostring(sid),
					status = st,
					branch = if type(s.branch) == "string" and s.branch ~= "" then s.branch else nil,
					updated = tonumber(s.updated) or 0,
				})
			elseif st == "input" or st == "approval" or st == "plan" then
				table.insert(attention, {
					id = tostring(s.id or sid),
					title = if type(s.title) == "string" and s.title ~= "" then s.title else tostring(sid),
					status = st,
					branch = if type(s.branch) == "string" and s.branch ~= "" then s.branch else nil,
					updated = tonumber(s.updated) or 0,
				})
			elseif st == "failed" or st == "limited" then
				table.insert(failed, {
					id = tostring(s.id or sid),
					title = if type(s.title) == "string" and s.title ~= "" then s.title else tostring(sid),
					status = st,
					branch = if type(s.branch) == "string" and s.branch ~= "" then s.branch else nil,
					updated = tonumber(s.updated) or 0,
				})
			end
		end
	end
	local by_recent = function(a: SessionItem, b: SessionItem): boolean
		return a.updated > b.updated
	end
	table.sort(working, by_recent)
	table.sort(attention, by_recent)
	table.sort(failed, by_recent)

	local mq = MIN_ACTIVE_QUOTA:get()
	local low = mq ~= nil and mq <= M.warn_threshold()
	return {
		working = working,
		attention = attention,
		failed = failed,
		min_quota = mq,
		low_quota = low,
	}
end

local function maybe_notify(title: string, body: string, session: string?)
	if not zeron_ref or not notify_setting or notify_setting:peek() ~= true then
		return
	end
	pcall(function()
		zeron_ref.notify {
			title = title,
			body = body,
			session = session,
		}
	end)
end

local function stop_threshold_listener()
	if threshold_stop then
		pcall(threshold_stop)
		threshold_stop = nil
	end
end

local function bind_threshold_listener(below_pct: number?)
	stop_threshold_listener()
	if not zeron_ref then
		return
	end
	local z = zeron_ref
	local target = below_pct or M.warn_threshold()
	pcall(function()
		threshold_stop = z.on("usage.threshold", function(e: any)
			local prov = tostring((e and e.provider) or "agent")
			if current_hidden_map()[prov] then
				return
			end
			local pct = math.floor((tonumber(e and e.remaining) or 0) + 0.5)
			local win = tostring((e and e.window) or "window")
			local title = z.s("notify.quota_title", { pct = pct })
			local body = z.s("notify.quota_body", { provider = prov, window = win, pct = pct })
			push_event("quota", title, body, nil)
			maybe_notify(title, body, nil)
		end, { below = target })
	end)
end

function M.ensure_wired()
	if not wired and zeron_ref then
		M.init(zeron_ref, notify_setting, warn_pct_setting)
	end
end

function M.cleanup()
	fetch_seq += 1
	refresh_seq += 1
	REFRESHING:set(false)
	stop_threshold_listener()
	for _, stop in stop_fns do
		pcall(stop)
	end
	stop_fns = {}
	wired = false
	wired_zeron = nil
end

function M.init(zeron: any, notify_opt: any, warn_pct_opt: any)
	if wired and wired_zeron ~= zeron then
		M.cleanup()
	end
	zeron_ref = zeron
	notify_setting = notify_opt
	warn_pct_setting = warn_pct_opt
	hidden_store = zeron.store("spider_hidden_providers_v1", {})
	seeded_store = zeron.store("spider_hidden_seeded_v2", false)

	if setting_wired_zeron ~= zeron then
		setting_wired_zeron = zeron
		zeron.on_setting(function(id: string, value: any)
			if id == "quota_warn_pct" and wired and wired_zeron == zeron then
				bind_threshold_listener(tonumber(value) or M.warn_threshold())
			end
		end)
	end

	M.fetch_usage()
	if wired then
		return
	end
	wired = true
	wired_zeron = zeron

	local function add_listener(stop: (() -> ())?)
		if type(stop) == "function" then
			table.insert(stop_fns, stop)
		end
	end

	pcall(function()
		add_listener(zeron.on("usage.changed", function()
			M.fetch_usage()
		end))
		add_listener(zeron.on("usage.reset", function()
			M.fetch_usage()
		end))
		add_listener(zeron.on("limit.hit", function(e: any)
			M.fetch_usage()
			local prov = tostring((e and e.provider) or "agent")
			if current_hidden_map()[prov] then
				return
			end
			local win = tostring((e and e.window) or "window")
			local title = zeron.s("notify.quota_title", { pct = 0 })
			local body = zeron.s("notify.quota_body", { provider = prov, window = win, pct = 0 })
			push_event("quota", title, body, e and e.chat)
			maybe_notify(title, body, e and e.chat)
		end))
		bind_threshold_listener(nil)

		add_listener(zeron.on("chat.awaiting_input", function(e: any)
			local cid = e and e.chat
			local stitle = session_title(cid)
			local title = zeron.s("notify.awaiting_title")
			local body = zeron.s("notify.awaiting_body", { title = stitle })
			push_event("attention", title, body, cid)
			maybe_notify(title, body, cid)
		end))

		add_listener(zeron.on("turn.errored", function(e: any)
			local cid = e and e.chat
			local stitle = session_title(cid)
			local title = zeron.s("notify.errored_title")
			local body = zeron.s("notify.errored_body", { title = stitle })
			push_event("error", title, body, cid)
			maybe_notify(title, body, cid)
		end))

		add_listener(zeron.on("turn.finished", function(e: any)
			local cid = e and e.chat
			local stitle = session_title(cid)
			local title = zeron.s("notify.finished_title")
			local body = zeron.s("notify.finished_body", { title = stitle })
			push_event("done", title, body, cid)
			local win = zeron.window(true)
			if not (win and win.active) then
				maybe_notify(title, body, cid)
			end
		end))
	end)
end

return M
