-- Host-boundary tests. Python injects the unchanged production modules.
local function loadStore(ui)
-- INJECT notes_store
end

local function loadDb(ui)
-- INJECT db
end

local function loadPrompts(ui, require)
-- INJECT prompts
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
	local Db = loadDb(ui)
	local function imports(name)
		if name == "./db" then return Db end
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
		ui = ui, zeron = zeron, Store = Store, Notes = loadNotes(ui, imports), Db = Db, Prompts = loadPrompts(ui, imports),
		states = states, placements = placements, current = current,
		composed = composed, compose_options = compose_options, toasts = toasts, opened = opened, kept = kept,
		requests = requests,
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

-- A dropdown option is one line even when the stored note is a full reply.
-- Its whole text remains searchable, and insertion keeps the original text.
do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	local content = "\r\n# 修复记录\r\n\r\n1. 第一项\r\n\treturn value\n2. 最后的关键词 🕸\r\n"
	local saved = row(23, content)
	saved.session_title = "来源会话\n第二行"
	h.take("exec").resolve({ changes = 0 })
	h.take("query").resolve({ saved })
	local toolbar = notes.toolbar(h.zeron.live("session"), h.zeron.live("route"))
	local picker = find(toolbar, "dropdown")
	local option = picker.props.items()[1]
	same(option.label, "# 修复记录 1. 第一项 return value 2. 最后的关键词 🕸", "multiline note becomes a single-line preview")
	same(option.hint, "来源会话 第二行", "source label stays on one line")
	assert(string.find(option.label, "最后的关键词", 1, true), "search reaches the end of the note")
	picker.props.on_choose("23")
	same(h.composed[1], content, "insertion retains original line breaks and indentation")
	same(h.compose_options[1].replace, false, "insertion preserves the existing draft")
	print("PASS multiline note preview")
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

-- Both delete entry points require confirmation, survive failures and refresh
-- the picker/count only after the persisted delete succeeds.
for _, entry in { "toolbar", "hub" } do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	h.take("exec").resolve({ changes = 0 })
	h.take("query").resolve({ row(21, "delete this"), row(22, "keep this") })
	local view, button
	if entry == "toolbar" then
		view = notes.toolbar(h.zeron.live("session"), h.zeron.live("route"))
		local picker = find(view, "dropdown")
		button = picker.props.trailing_item(picker.props.items()[1])
	else
		view = notes.build()
		h.drainReads({ row(21, "delete this"), row(22, "keep this") })
		button = find(view, "button", "notes.delete")
	end
	local dialog = find(view, "dialog", "notes.delete_title")
	button.on_click()
	same(dialog.open:peek(), true, "opens delete confirmation")
	same(#h.requests, 0, "opening confirmation does not delete")
	same(#h.composed, 0, "delete action does not insert note")
	dialog.open:set(false)
	same(notes.count(), 2, "cancel keeps notes")
	button.on_click()
	dialog.confirm.on_click()
	local removal = h.take("exec")
	same(removal.params[1], 21, "delete targets chosen note")
	dialog.confirm.on_click()
	same(#h.requests, 0, "duplicate confirmation is ignored")
	removal.reject("offline")
	same(notes.count(), 2, "failed delete keeps notes")
	same(dialog.open:peek(), true, "failure leaves confirmation open for retry")
	same(h.toasts[#h.toasts], "notes.delete_failed", "failure is reported")
	same(button.disabled(), false, "failure releases delete guard")
	dialog.confirm.on_click()
	h.take("exec").resolve({ changes = 1 })
	h.take("query").resolve({ row(22, "keep this") })
	same(dialog.open:peek(), false, "success closes confirmation")
	same(notes.count(), 1, "successful delete refreshes count")
	same(h.toasts[#h.toasts], "notes.deleted", "success is reported")
	local toolbar = notes.toolbar(h.zeron.live("session"), h.zeron.live("route"))
	local picker = find(toolbar, "dropdown")
	same(#picker.props.items(), 1, "picker refreshes after delete")
	same(picker.props.items()[1].value, "22", "other notes remain")
	picker.props.on_choose("21")
	same(#h.composed, 0, "deleted note cannot be inserted")
	print(`PASS {entry} deletion confirmation and retry`)
end

-- Deleting an edited note blocks saving during the write and preserves text
-- typed while the delete is in flight as a fresh draft.
do
	local h = host()
	local notes = h.Notes.new(h.zeron)
	h.take("exec").resolve({ changes = 0 })
	h.take("query").resolve({ row(21, "saved text") })
	h.states.spider_notes_draft_id:set(21)
	h.states.spider_notes_draft_body:set("current edit")
	local toolbar = notes.toolbar(h.zeron.live("session"), h.zeron.live("route"))
	local picker = find(toolbar, "dropdown")
	picker.props.trailing_item(picker.props.items()[1]).on_click()
	local dialog = find(toolbar, "dialog", "notes.delete_title")
	dialog.confirm.on_click()
	local removal = h.take("exec")
	local area = find(toolbar, "textarea")
	area.value:set("newer unsaved text")
	area.on_submit()
	same(#h.requests, 0, "save blocked during delete")
	removal.resolve({ changes = 1 })
	h.take("query").resolve({})
	same(notes.count(), 0, "last note removed")
	same(#picker.props.items(), 0, "picker has no stale last item")
	same(area.value:peek(), "newer unsaved text", "new edits preserved")
	same(h.states.spider_notes_draft_id:peek(), 0, "new edits become fresh draft")
	print("PASS delete draft concurrency")
end

local function prompt_host()
	local h = host()
	h.zeron.store("spider_seeded_v1", true)
	h.Db.init(h.zeron)
	h.take("exec").resolve({ changes = 0 })
	local rows = {}
	for id = 1, 12 do
		table.insert(rows, { id = id, kind = "prompt", title = `Prompt {id}`, content = `Body {id}`, created_at = 1 })
	end
	table.insert(rows, { id = 99, kind = "snippet", title = "Saved message", content = "not a prompt", created_at = 1 })
	h.take("query").resolve(rows)
	local view = h.Prompts.toolbar(h.zeron, h.zeron.live("session"))
	return h, view, find(view, "dropdown"), rows
end

do
	local h, view, picker = prompt_host()
	same(#picker.props.items(), 12, "all prompts listed beyond former eight-item limit")
	picker.props.on_choose("12")
	same(h.composed[1], "Body 12", "prompt body inserted")
	same(h.compose_options[1].session, "source", "current session targeted")
	same(h.compose_options[1].replace, false, "existing draft preserved")
	h.current.session = nil
	picker.props.on_choose("1")
	same(h.compose_options[2].session, "", "home draft targeted")
	picker.props.on_choose("99")
	same(#h.composed, 2, "saved messages excluded")
	print("PASS prompt picker")
end

do
	local h, view, picker, rows = prompt_host()
	picker.props.actions[1].on_click()
	local editor = find(view, "dialog", "prompts.new")
	local title, area = find(editor, "textfield"), find(editor, "textarea")
	same(editor.open:peek(), true, "new prompt opens editor")
	area.on_submit()
	same(#h.requests, 0, "empty prompt rejected")
	title.value:set("New title")
	area.value:set("New content")
	find(editor, "button", "notes.close").on_click()
	picker.props.actions[1].on_click()
	same(area.value:peek(), "New content", "closing preserves draft")
	area.on_submit()
	local write = h.take("exec")
	same(write.params[1], "prompt", "new entry is a prompt")
	area.on_submit()
	same(#h.requests, 0, "duplicate saves ignored")
	write.reject("offline")
	same(editor.open:peek(), true, "failed save keeps editor open")
	same(area.value:peek(), "New content", "failed save preserves content")
	area.on_submit()
	h.take("exec").resolve({ changes = 1 })
	table.insert(rows, { id = 13, kind = "prompt", title = "New title", content = "New content", created_at = 1 })
	h.take("query").resolve(rows)
	same(editor.open:peek(), false, "saved prompt closes editor")
	same(#picker.props.items(), 13, "saved prompt refreshes picker")
	same(area.value:peek(), "", "saved draft cleared")
	print("PASS prompt creation and retry")
end

do
	local h, view, picker, rows = prompt_host()
	local button = find(picker.props.trailing_item(picker.props.items()[1]), "button", "hub.delete_btn")
	local dialog = find(view, "dialog", "prompts.delete_title")
	button.on_click()
	same(dialog.open:peek(), true, "prompt deletion requires confirmation")
	same(#h.requests, 0, "opening confirmation does not delete")
	same(#h.composed, 0, "delete does not insert")
	dialog.open:set(false)
	same(#picker.props.items(), 12, "cancel keeps prompts")
	button.on_click()
	dialog.confirm.on_click()
	local removal = h.take("exec")
	same(removal.params[1], 1, "correct prompt deleted")
	dialog.confirm.on_click()
	same(#h.requests, 0, "duplicate deletes ignored")
	removal.reject("offline")
	same(dialog.open:peek(), true, "failed delete can retry")
	same(button.disabled(), false, "failed delete releases busy state")
	dialog.confirm.on_click()
	h.take("exec").resolve({ changes = 1 })
	table.remove(rows, 1)
	h.take("query").resolve(rows)
	same(#picker.props.items(), 11, "deleted prompt removed from picker")
	same(dialog.open:peek(), false, "successful delete closes confirmation")
	picker.props.on_choose("1")
	same(#h.composed, 0, "deleted prompt cannot insert")
	print("PASS prompt deletion and retry")
end

do
	local h, view, picker, rows = prompt_host()
	local creation = find(view, "dialog", "prompts.new")
	find(creation, "textfield").value:set("unsaved new prompt")
	find(creation, "textarea").value:set("unsaved new content")
	local controls = picker.props.trailing_item(picker.props.items()[2])
	local edit = find(controls, "button", "hub.edit_btn")
	local remove = find(controls, "button", "hub.delete_btn")
	edit.on_click()
	local editor = find(view, "dialog", "prompts.edit")
	local title, area = find(editor, "textfield"), find(editor, "textarea")
	same(editor.open:peek(), true, "edit opens dialog")
	same(title.value:peek(), "Prompt 2", "edit prefills title")
	same(area.value:peek(), "Body 2", "edit prefills content")
	same(#h.composed, 0, "edit does not insert")
	find(editor, "button", "hub.cancel_btn").on_click()
	same(#h.requests, 0, "cancel does not write")
	edit.on_click()
	area.value:set(" ")
	area.on_submit()
	same(#h.requests, 0, "blank edit rejected")
	title.value:set("Updated title")
	area.value:set("Updated body")
	area.on_submit()
	local write = h.take("exec")
	assert(string.find(write.sql, "UPDATE spider_snippets", 1, true), "edit updates existing row")
	same(write.params[3], 2, "edit targets selected id")
	same(remove.disabled(), true, "delete blocked while saving edit")
	area.on_submit()
	same(#h.requests, 0, "duplicate edit save ignored")
	write.reject("offline")
	same(editor.open:peek(), true, "failed edit remains open")
	same(area.value:peek(), "Updated body", "failed edit keeps text")
	same(edit.disabled(), false, "failed edit releases busy state")
	area.on_submit()
	h.take("exec").resolve({ changes = 1 })
	rows[2].title, rows[2].content = "Updated title", "Updated body"
	h.take("query").resolve(rows)
	same(editor.open:peek(), false, "successful edit closes dialog")
	same(#picker.props.items(), 12, "editing never adds duplicate prompt")
	same(picker.props.items()[2].label, "Updated title", "picker updates title")
	picker.props.on_choose("2")
	same(h.composed[1], "Updated body", "picker inserts updated content")
	same(find(creation, "textfield").value:peek(), "unsaved new prompt", "edit preserves separate new draft")
	same(find(creation, "textarea").value:peek(), "unsaved new content", "edit preserves new draft content")
	print("PASS quick prompt editing and retry")
end

print("PASS 15 runtime scenarios")
