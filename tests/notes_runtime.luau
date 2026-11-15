-- Host-boundary tests. Python injects the unchanged production modules.
local function loadStore(ui)
-- INJECT notes_store
end

local function loadToolbar(require)
-- INJECT toolbar_button
end

local function loadNotes(ui, require)
	-- Luau CLI does not offer the host's date formatter; presentation only.
	local os = { time = os.time, date = function() return "11-15 12:00" end }
-- INJECT notes
end

local function same(actual, expected, description)
	assert(actual == expected, `{description}: expected {tostring(expected)}, got {tostring(actual)}`)
end

local function host()
	local states, effects, requests, placements, kept = {}, {}, {}, {}, {}
	local function state(initial)
		local s = { value = initial }
		function s:get() return self.value end
		function s:peek() return self.value end
		function s:set(value) self.value = value end
		return s
	end
	local function node(tag)
		return function(props)
			props.tag = tag
			return props
		end
	end
	local ui = {
		state = function(key, initial)
			if states[key] == nil then states[key] = state(initial) end
			return states[key]
		end,
		use_state = state,
		effect = function(callback) table.insert(effects, callback); callback() end,
		after = function(_delay, callback) callback() end,
		presence = function(key, build, props)
			return { tag = "presence", build(key()) }
		end,
		show = function(when, content) return { tag = "show", content } end,
		row = node("row"), column = node("column"), div = node("div"), text = node("text"),
	}
	local current = { session = { id = "source", title = "Source chat", project = "project" }, route = { name = "session" } }
	local composed, compose_options, toasts, opened = {}, {}, {}, {}
	local throw_next = false
	local function request(kind, sql, params)
		if throw_next then throw_next = false; error("host unavailable") end
		local pending = { kind = kind, sql = sql, params = params }
		function pending:after(success, failure)
			self.resolve, self.reject = success, failure
		end
		table.insert(requests, pending)
		return pending
	end
	local zeron = {
		db = {
			exec = function(sql, params) return request("exec", sql, params) end,
			query = function(sql, params) return request("query", sql, params) end,
		},
		store = function(key, default)
			if kept[key] == nil then kept[key] = state(default) end
			return kept[key]
		end,
		projects = function() return { project = { name = "Project" } } end,
		sessions = function() return { source = current.session } end,
		place = function(placement) table.insert(placements, placement) end,
		live = function(name) return function() return current[name] end end,
		context = function(name) return current[name] end,
		s = function(key) return key end,
		t = function(key) return function() return key end end,
		toast = function(text) table.insert(toasts, text) end,
		open = function(route) table.insert(opened, route) end,
		compose = function(text, options) table.insert(composed, text); table.insert(compose_options, options) end,
	}
	local function take(kind)
		local r = table.remove(requests, 1)
		assert(r and r.kind == kind, `expected queued {kind}, got {if r then r.kind else "none"}`)
		return r
	end
	local function ready()
		take("exec").resolve({ changes = 0, last_id = 0 })
		take("query").resolve({})
	end
	local Store = loadStore(ui)
	local function imports(name)
		if name == "./notes_store" then return Store end
		if name == "./toolbar_button" then return loadToolbar(imports) end
		if name == "@ds/dialog" then
			return { Dialog = function(props)
				if props.build then table.insert(props, props.build()) end
				props.tag = "dialog"
				return props
			end }
		end
		if name == "@ds/dropdown" then
			return function(props)
				local open = state(false)
				local menu = {
					open = open,
					toggle = function() open:set(not open:get()) end,
				}
				return { tag = "dropdown", trigger = props.trigger(menu), props = props }
			end
		end
		if name == "./web_gauge" then return { CornerWeb = node("web") } end
		if name == "@ds/button" then return node("button") end
		if name == "@ds/text_area" then return node("textarea") end
		if name == "@ds/text_field" then return node("textfield") end
		if name == "@ds/icon" then return node("icon") end
		if name == "@ds/icon_button" then return { IconButton = node("button") } end
		error(`unexpected import: {name}`)
	end
	return {
		ui = ui, zeron = zeron, Store = Store, Notes = loadNotes(ui, imports),
		states = states, placements = placements, current = current,
		composed = composed, compose_options = compose_options, toasts = toasts, opened = opened, kept = kept,
		take = take, ready = ready,
		drainReads = function(rows)
			while requests[1] and requests[1].kind == "query" do
				take("query").resolve(rows or {})
			end
		end,
		throw = function() throw_next = true end,
		flush = function() for _, effect in effects do effect() end end,
	}
end

local function text(node)
	if type(node) == "function" then return node() end
	if type(node) == "string" then return node end
	if type(node) ~= "table" then return "" end
	local out = ""
	for _, child in ipairs(node) do out ..= text(child) end
	return out
end

local function find(root, tag, label)
	if type(root) ~= "table" then return nil end
	if root.tag == tag and (not label or text(root) == label or text(root.label) == label or text(root.title) == label) then return root end
	for _, child in ipairs(root) do
		local found = find(child, tag, label)
		if found then return found end
	end
	return nil
end

local function row(id, content)
	return { id = id, content = content, session = "source", session_title = "Source chat", project = "Project", message = "message", created_at = 1, updated_at = 2 }
end

-- A rejected initial request is recoverable, including a synchronous host throw.
do
	local h = host()
	local store = h.Store.new(h.zeron)
	h.throw()
	store.init()
	same(store.ready(), false, "failed init readiness")
	same(store.error(), "notes.load_failed", "sync init error")
	store.init()
	h.ready()
	same(store.ready(), true, "retry readiness")
	local failed
	store.save(nil, "draft", nil, nil, function(key) failed = key end)
	h.take("exec").reject("offline")
	same(failed, "notes.save_failed", "async save error callback")
	print("PASS failure and retry")
end

-- Only the newest reload can publish; starting a write invalidates older reads.
do
	local h = host()
	local store = h.Store.new(h.zeron)
	store.init(); h.ready()
	store.reload(); local older = h.take("query")
	store.reload(); local newer = h.take("query")
	newer.resolve({ row(2, "new") }); older.resolve({ row(1, "old") })
	same(store.items()[1].content, "new", "out of order query")
	store.reload(); local before_write = h.take("query")
	local inserted
	store.save(nil, "saved", nil, function(id) inserted = id end)
	before_write.resolve({})
	same(store.items()[1].content, "new", "write invalidates pending read")
	h.take("exec").resolve({ changes = 1, last_id = 7 })
	h.take("query").resolve({ row(7, "saved") })
	same(inserted, 7, "insert returns its own result id")
	print("PASS stale reads")
end

-- An edit contains only content/time/id, so the original source cannot change.
do
	local h = host()
	local store = h.Store.new(h.zeron)
	store.init(); h.ready()
	store.save(9, " updated ", { session = "wrong" })
	local write = h.take("exec")
	same(#write.params, 3, "edit parameter count")
	same(write.params[1], "updated", "content trim")
	same(write.params[3], 9, "edited note id")
	print("PASS edit source contract")
end

-- Saving while typing must preserve the newer draft and target the inserted ID.
do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	h.ready()
	local view = notes.build()
	h.drainReads()
	local area = find(view, "textarea")
	area.value:set("first revision")
	area.on_submit()
	assert(h.states.spider_notes_busy:peek(), `save should be in flight: {tostring(h.states.spider_notes_form_error:peek())}`)
	area.value:set("second revision")
	h.take("exec").resolve({ changes = 1, last_id = 12 })
	h.take("query").resolve({ row(12, "first revision") })
	same(area.value:peek(), "second revision", "new text kept after save")
	same(h.states.spider_notes_draft_id:peek(), 12, "new edits update inserted note")
	h.flush()
	same(h.kept.notes_draft:peek().body, "second revision", "new draft persisted")
	area.on_submit()
	h.take("exec").reject("offline")
	same(area.value:peek(), "second revision", "failed save keeps draft")
	same(h.states.spider_notes_busy:peek(), false, "failed save clears busy")
	print("PASS draft preservation")
end

-- Clear draft exits editing and never updates/deletes the already stored note.
do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	h.ready()
	h.states.spider_notes_draft_body:set("unsaved edits")
	h.states.spider_notes_draft_id:set(12)
	h.states.spider_notes_draft_source:set({ session = "source" })
	local view = notes.build()
	h.drainReads()
	local dialog = find(view, "dialog", "notes.discard_title")
	assert(dialog, "discard confirmation")
	dialog.confirm.on_click()
	same(h.states.spider_notes_draft_body:peek(), "", "discard body")
	same(h.states.spider_notes_draft_id:peek(), 0, "discard edit identity")
	same(h.states.spider_notes_draft_source:peek().session, nil, "discard source")
	print("PASS clear draft")
end

-- The toolbar picker inserts a selected note into the current draft without
-- navigating away or replacing existing text.
do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	h.take("exec").resolve({ changes = 0 })
	h.take("query").resolve({ row(21, "use this note") })
	local toolbar = notes.toolbar(h.zeron.live("session"), h.zeron.live("route"))
	local picker = find(toolbar, "dropdown")
	assert(picker and picker.props and picker.props.on_choose, "notes picker")
	picker.props.on_choose("21")
	same(h.composed[1], "use this note", "picker inserts note")
	same(h.compose_options[1].session, "source", "picker targets current session")
	same(h.compose_options[1].replace, false, "picker appends note")
	print("PASS direct note picker")
end

-- Navigation only stages a transfer. Wrong-session insertion never writes.
do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	h.take("exec").resolve({ changes = 0 })
	h.take("query").resolve({ row(17, "carry this") })
	notes.register()
	local view = notes.build()
	h.drainReads({ row(17, "carry this") })
	local carry = find(view, "button", "notes.carry")
	assert(carry, "carry button")
	carry.on_click()
	same(#h.composed, 0, "navigation does not insert")
	same(h.opened[1].session, "source", "source navigation")
	local toolbar = notes.toolbar(h.zeron.live("session"), h.zeron.live("route"))
	local insert = find(toolbar, "button", "notes.insert")
	h.current.session = { id = "different" }
	insert.on_click()
	same(#h.composed, 0, "wrong target prevented")
	h.current.session = { id = "source" }
	insert.on_click()
	same(h.composed[1], "carry this", "correct target receives content")
	insert.on_click()
	same(#h.composed, 1, "transfer consumed once")
	print("PASS target session guard")
end

print("PASS 6 runtime scenarios")
