-- Production modules are injected verbatim. Only the reactive host is mocked.
local function loadRadar(ui)
-- INJECT radar
end

local function loadPet(ui, require)
-- INJECT pet
end

local function loadWallpaper(ui, zeron, motion, parallax)
-- INJECT wallpaper
end

local function same(actual, expected, why)
	assert(actual == expected, `{why}: expected {tostring(expected)}, got {tostring(actual)}`)
end

local function host(initiallyShown)
	local current, draining = nil, false
	local queued, effects, cleanup, timers, named, allStates = {}, {}, {}, {}, {}, {}
	local function flush()
		if draining or current then return end
		draining = true
		local runs = 0
		while #queued > 0 do
			local effect = table.remove(queued, 1)
			effect.queued = false
			for dependency in effect.dependencies do dependency.readers[effect] = nil end
			effect.dependencies = {}
			if effect.stop then effect.stop(); effect.stop = nil end
			current = effect
			effect.stop = effect.run()
			current = nil
			runs += 1
			assert(runs < 1000, "reactive cycle in production lifecycle")
		end
		draining = false
	end
	local function queue(effect)
		if not effect.queued then effect.queued = true; table.insert(queued, effect) end
	end
	local function state(value)
		local s = { value = value, readers = {}, writes = 0 }
		function s:get()
			if current then self.readers[current] = true; current.dependencies[self] = true end
			return self.value
		end
		function s:peek() return self.value end
		function s:set(nextValue)
			if self.value == nextValue then return end
			self.value = nextValue
			self.writes += 1
			for reader in self.readers do queue(reader) end
			flush()
		end
		function s:add(n) self:set(self:peek() + n) end
		table.insert(allStates, s)
		return s
	end
	local function effect(callback)
		local e = { run = callback, dependencies = {} }
		table.insert(effects, e)
		queue(e)
		flush()
	end
	local function node(tag)
		return function(props) props.tag = tag; return props end
	end
	local now = 10000
	local shown, active, reduced = state(initiallyShown ~= false), state(true), state(false)
	local sessions = state({ A = { id = "A", title = "Task A", status = "working", updated = 1 } })
	local route = state({ name = "session", session = "A" })
	local counters = { sessions = 0, layout = 0, ticks = 0, timers = 0, timerStops = 0, springs = 0, pointer = 0 }
	local ui = {
		state = function(key, value)
			if not named[key] then named[key] = state(value) end
			return named[key]
		end,
		use_state = state,
		shared = function(key, value)
			if not named[key] then named[key] = state(value) end
			return named[key]
		end,
		effect = effect,
		computed = function(callback)
			local result = state(nil)
			effect(function() result:set(callback()) end)
			return result
		end,
		on_cleanup = function(callback) table.insert(cleanup, callback) end,
		now = function() return now end,
		every = function(ms, callback)
			local timer = { ms = ms, callback = callback, alive = true }
			table.insert(timers, timer)
			counters.timers += 1
			return function()
				if timer.alive then timer.alive = false; counters.timerStops += 1 end
			end
		end,
		div = node("div"), row = node("row"), column = node("column"), text = node("text"),
		image = node("image"), canvas = node("canvas"), button = node("button"),
		show = function(when, content) return { tag = "show", when = when, content } end,
		presence = function(key, build, _props) return { key = key, build = build } end,
		spring = function(_source, _props) counters.springs += 1; return {} end,
		theme = { current = state("dark"), get = function() return 720 end },
	}
	local listeners, settingsListeners, requests, notifications, placements, stores = {}, {}, {}, {}, {}, {}
	local function request(kind)
		local pending = { kind = kind }
		function pending:after(success, failure) self.resolve, self.reject = success, failure end
		table.insert(requests, pending)
		return pending
	end
	local zeron = {
		window = function(peek)
			return { shown = if peek then shown:peek() else shown:get(), active = if peek then active:peek() else active:get() }
		end,
		store = function(key, value)
			if not stores[key] then stores[key] = state(value) end
			return stores[key]
		end,
		on_setting = function(callback) table.insert(settingsListeners, callback) end,
		on = function(event, callback, options)
			local listener = { event = event, callback = callback, options = options, alive = true }
			table.insert(listeners, listener)
			return function() listener.alive = false end
		end,
		usage = function() return request("usage") end,
		usage_refresh = function() return request("refresh") end,
		sessions = function() counters.sessions += 1; return sessions:get() end,
		s = function(key, _args) return key end,
		t = function(key) return function() return key end end,
		notify = function(value) table.insert(notifications, value) end,
		toast = function(value) table.insert(notifications, value) end,
		reason = function(value) return value end,
		read = function() return "dark" end,
		place = function(value) table.insert(placements, value) end,
		live = function(name)
			if name == "pointer" then return function() counters.pointer += 1; return { x = 0.5, y = 0.5 } end end
			assert(name == "route")
			return function() return route:get() end
		end,
		slot = function(name, props) props.slot = name; return props end,
		open = function(value) route:set({ name = "session", session = value.session }) end,
	}
	local layout = {
		win_w = state(1280), stage_y = state(700), sidebar_r = state(250), panel_l = state(0), prose_cx = state(765), prose_w = state(660),
		max_by = function() return 650 end,
		ref = function() return {} end,
		sample = function() counters.layout += 1; return 1280, 650, false end,
	}
	local radar = loadRadar(ui)
	local function imports(name)
		if name == "./radar" then return radar end
		if name == "./layout" then return layout end
		if name == "./db" then return { prompts = function() return {} end } end
		if name == "@ds/motion" then return { reduced = function() return reduced:get() end } end
		if name == "@ds/glass" then return { Panel = node("panel") } end
		if name == "@ds/icon_button" then return { IconButton = node("button") } end
		if name == "@ds/visual_ink" or name == "@ds/material" then return {} end
		if name == "@ds/icon" then return node("icon") end
		if name == "@ds/button" then return node("button") end
		error(`unexpected import: {name}`)
	end
	local notify, warn, showPet = state(true), state(15), state(true)
	local h = {
		ui = ui, zeron = zeron, radar = radar, shown = shown, active = active, reduced = reduced,
		sessions = sessions, route = route, showPet = showPet, counters = counters, requests = requests,
		notifications = notifications, named = named, allStates = allStates,
		init = function() radar.init(zeron, notify, warn) end,
		mountPet = function()
			loadPet(ui, imports).register(zeron, showPet)
			return placements[#placements].after()
		end,
		mountWallpaper = function()
			loadWallpaper(ui, zeron, { reduced = function() return reduced:get() end }, state("normal"))
			return placements[#placements].replace()
		end,
		listeners = function(event)
			local n = 0
			for _, listener in listeners do if listener.alive and (event == nil or listener.event == event) then n += 1 end end
			return n
		end,
		timers = function()
			local n = 0
			for _, timer in timers do if timer.alive then n += 1 end end
			return n
		end,
		emit = function(event, value)
			for _, listener in table.clone(listeners) do if listener.alive and listener.event == event then listener.callback(value) end end
		end,
		tick = function(ms)
			now += ms
			for _, timer in table.clone(timers) do
				if timer.alive then
					counters.ticks += 1
					if timer.callback() == false then timer.alive = false end
				end
			end
		end,
	}
	return h
end

local function usage(remaining)
	return { { provider = "codex", account = "local", active = true, windows = { { label = "week", remaining = remaining } } } }
end

local function actor(root)
	for _, child in root do
		if type(child) == "table" and child.tag == "button" and child.w == 72 and not child.hidden() then return child end
	end
	error("expected a visible spider")
end

-- Hidden-at-start performs no quota requests and registers no event listeners.
do
	local h = host(false)
	h.init()
	same(#h.requests, 0, "hidden startup does not fetch usage")
	same(h.listeners(), 0, "hidden startup has no radar listeners")
	h.radar.fetch_usage(); h.radar.refresh_usage()
	same(#h.requests, 0, "explicit hidden refresh is inert")
	h.shown:set(true)
	same(#h.requests, 1, "restore fetches once")
	same(h.listeners(), 7, "restore registers each radar event once")
	h.active:set(false)
	same(#h.requests, 1, "focus loss alone does not refresh")
	same(h.listeners(), 7, "visible background window stays subscribed")
end

-- A minimized window invalidates in-flight data without processing hidden events.
do
	local h = host(true)
	h.init()
	h.requests[1].resolve(usage(72))
	same(h.radar.min_quota(), 72, "initial quota visible")
	h.radar.fetch_usage()
	local oldFetch = h.requests[#h.requests]
	h.radar.refresh_usage()
	local oldRefresh = h.requests[#h.requests]
	same(h.radar.refreshing(), true, "refresh started")
	h.shown:set(false)
	same(h.listeners(), 0, "hidden detaches all radar events")
	same(h.radar.refreshing(), false, "suspend releases busy state")
	local reads = h.counters.sessions
	for _ = 1, 5 do h.radar.summary() end
	same(h.counters.sessions, reads, "hidden summary does not scan sessions")
	local requestCount, revision = #h.requests, h.radar.usage_rev()
	oldFetch.resolve(usage(4)); oldRefresh.resolve()
	same(h.radar.usage_rev(), revision, "late hidden response cannot update quota")
	same(h.radar.min_quota(), 72, "late response preserves cached display")
	h.emit("usage.changed", {})
	h.emit("turn.finished", { chat = "A" })
	same(#h.requests, requestCount, "hidden events do not fetch")
	same(#h.notifications, 0, "hidden events do not notify")
	h.shown:set(true)
	same(#h.requests, requestCount + 1, "restore refreshes latest quota once")
	h.requests[#h.requests].resolve(usage(63))
	same(h.radar.min_quota(), 63, "restore accepts latest quota")
	oldFetch.reject("offline")
	same(h.radar.min_quota(), 63, "old failure cannot erase fresh quota")
	for _ = 1, 4 do h.shown:set(false); h.shown:set(true) end
	same(h.listeners(), 7, "repeated restore does not duplicate radar listeners")
end

-- Hidden spiders have no active timers, layout polls, or event subscriptions.
do
	local h = host(true)
	h.init()
	local root = h.mountPet()
	same(h.timers(), 1, "visible pet starts one animation timer")
	same(h.listeners("turn.finished"), 2, "radar and pet each listen once")
	h.tick(20)
	local spider = actor(root)
	local x, y = spider.x(), spider.y()
	h.shown:set(false)
	same(h.timers(), 0, "minimize cancels animation timer")
	same(h.listeners(), 0, "minimize cancels pet and radar listeners")
	local ticks, polls, reads = h.counters.ticks, h.counters.layout, h.counters.sessions
	h.tick(60000)
	h.sessions:set({ A = { id = "A", title = "Task A", status = "done", updated = 2 } })
	same(h.counters.ticks, ticks, "no timer wakes while minimized")
	same(h.counters.layout, polls, "no hidden layout sampling")
	same(h.counters.sessions, reads, "hidden session changes cause no scans")
	same(spider.x(), x, "hidden spider x unchanged")
	same(spider.y(), y, "hidden spider y unchanged")
	h.active:set(false)
	h.shown:set(true)
	same(h.timers(), 1, "visible inactive window resumes animation")
	same(h.listeners("turn.finished"), 2, "resume restores one pet listener")
	spider = actor(root)
	spider.on_click()
	local swingPose
	for _, s in h.allStates do
		local v = s:peek()
		if type(v) == "table" and v.sang and v.hop == 6 and v.st == 0 then swingPose = s end
	end
	assert(swingPose, "task finished while hidden restores its completed spider")
	h.tick(20)
	local before = table.clone(swingPose:peek())
	h.shown:set(false)
	h.tick(120000)
	for key, value in before do same(swingPose:peek()[key], value, `paused swing preserves {key}`) end
	h.shown:set(true)
	h.tick(20)
	same(swingPose:peek().st, before.st + 0.02, "resume advances one frame rather than hidden duration")
	for _ = 1, 4 do h.shown:set(false); h.shown:set(true) end
	same(h.timers(), 1, "repeated restore leaves one animation timer")
	h.showPet:set(false)
	same(h.timers(), 0, "disabled pet remains stopped")
end

-- A plugin first loaded minimized stays asleep; reduced motion still wins on restore.
do
	local h = host(false)
	h.init()
	h.mountPet()
	same(h.timers(), 0, "hidden pet startup creates no timer")
	same(h.listeners(), 0, "hidden pet startup creates no subscriptions")
	same(h.counters.sessions, 0, "hidden startup does not scan sessions")
	h.reduced:set(true)
	h.shown:set(true)
	same(h.timers(), 0, "reduced motion remains timer-free on restore")
	h.reduced:set(false)
	same(h.timers(), 1, "enabling motion starts one timer")
	local started = h.counters.timers
	h.active:set(false)
	same(h.counters.timers, started, "focus loss does not restart timer")
	h.shown:set(false)
	same(h.timers(), 0, "hidden even with focus state unchanged stops timer")
end

-- First visibility establishes a baseline, without replaying historical finishes.
do
	local h = host(false)
	h.sessions:set({
		old = { id = "old", title = "Old finish", status = "done", updated = 1 },
		failed = { id = "failed", title = "Old failure", status = "failed", updated = 1 },
	})
	h.route:set({ name = "home" })
	h.init()
	local root = h.mountPet()
	h.shown:set(true)
	local function visible_count()
		local count = 0
		for _, child in root do
			if type(child) == "table" and child.tag == "button" and child.w == 72 and not child.hidden() then count += 1 end
		end
		return count
	end
	same(visible_count(), 0, "first restore does not replay historical completions")
	h.shown:set(false)
	h.sessions:set({
		old = { id = "old", title = "Old finish", status = "done", updated = 1 },
		failed = { id = "failed", title = "Old failure", status = "failed", updated = 1 },
		new = { id = "new", title = "New finish", status = "done", updated = 2 },
	})
	h.shown:set(true)
	same(visible_count(), 1, "later restore recovers a new finish while retaining the baseline")
end

-- Execute the real wallpaper placement: its hidden branch never builds springs.
do
	local h = host(false)
	local view = h.mountWallpaper()
	same(view.key(), "hidden", "hidden wallpaper switches presence branch")
	local empty = view.build(view.key())
	same(empty.id, nil, "hidden wallpaper does not retain animated scene")
	same(h.counters.springs, 0, "hidden wallpaper constructs no springs")
	same(h.counters.pointer, 0, "hidden wallpaper reads no pointer")
	h.shown:set(true)
	same(view.build(view.key()).id, "spider-man-scene", "restore rebuilds wallpaper")
	same(h.counters.springs, 4, "visible parallax constructs two axes per layer")
	h.shown:set(false)
	view.build(view.key())
	same(h.counters.springs, 4, "minimize does not construct replacement animations")
end

print("PASS visibility lifecycle scenarios")
