-- Inject the production UI; mock only native UI components and the store boundary.
local function loadChecklist(ui, require)
-- INJECT checklist
end

local function same(actual, expected, why)
	assert(actual == expected, `{why}: expected {tostring(expected)}, got {tostring(actual)}`)
end

local function read(value)
	if type(value) == "function" then return value() end
	if type(value) == "table" and type(value.get) == "function" then return value:get() end
	return value
end

-- Native state values cross the host boundary: tables are dense lists or
-- string-keyed objects. An ID-keyed sparse numeric map is rejected there.
local function validate_state(value)
	if type(value) ~= "table" then return end
	local length = #value
	local count = 0
	for key, item in value do
		count += 1
		assert((type(key) == "string" and length == 0)
			or (type(key) == "number" and key % 1 == 0 and key >= 1 and key <= length),
			"state tables are lists or have string keys, not integer keys")
		validate_state(item)
	end
	assert(length == 0 or count == length, "state lists must have consecutive integer keys")
end

do
	validate_state({ 10, 20, 30 })
	validate_state({ ["10"] = true, ["30"] = true })
	local ok = pcall(validate_state, { [10] = true, [30] = true })
	same(ok, false, "the host boundary rejects sparse numeric state keys")
	same(pcall(validate_state, { [1] = true, [3] = true }), false, "the host boundary rejects holes in a state list")
end

local function host()
	local function state(value)
		validate_state(value)
		local s = { value = value }
		function s:get() return self.value end
		s.peek = s.get
		function s:set(nextValue) validate_state(nextValue); self.value = nextValue end
		return s
	end
	local function node(tag)
		return function(props) props.tag = tag; return props end
	end
	local effects = {}
	local ui = {
		use_state = state,
		state = function(_key, value) return state(value) end,
		computed = function(fn) return { get = fn, peek = fn } end,
		effect = function(fn) table.insert(effects, fn); fn() end,
		column = node("column"), row = node("row"), div = node("div"), text = node("text"), scroll = node("scroll"),
		show = function(test, child) return { tag = "show", test = test, child = child } end,
		presence = function(test, build) return { tag = "presence", test = test, build = build, cached = nil } end,
		each = function(source, build, options) return { tag = "each", source = source, build = build, options = options, cache = {} } end,
	}
	local function item(id, title, body, done)
		return { id = id, title = title, body = body, done = done or false, message = "reply" }
	end
	local rows = {
		A = { item(10, "Alpha", "Alpha body"), item(20, "Beta", "Beta body", true), item(30, "Gamma", "Gamma body") },
		B = { item(40, "Other", "Other session body") },
	}
	local operations, composed, toasts, loads, ready, revisions = {}, {}, {}, {}, {}, {}
	local shown = true
	local function queue(kind, sid, ids, value, done, fail)
		table.insert(operations, { kind = kind, session = sid, ids = table.clone(ids), value = value, resolve = done, reject = fail })
	end
	local store = {
		load = function(sid) loads[sid] = (loads[sid] or 0) + 1; ready[sid] = true end,
		items = function(sid) return rows[sid] or {} end,
		ready = function(sid) return ready[sid] == true end,
		error = function() return nil end,
		rev = function(sid) return revisions[sid] or 0 end,
		set_done = function(sid, id, value, done, fail) queue("set_done", sid, { id }, value, done, fail) end,
		remove = function(sid, id, done, fail) queue("remove", sid, { id }, nil, done, fail) end,
		set_many_done = function(sid, ids, value, done, fail) queue("set_many_done", sid, ids, value, done, fail) end,
		remove_many = function(sid, ids, done, fail) queue("remove_many", sid, ids, nil, done, fail) end,
	}
	local draw
	local function say(key, args)
		if not args then return key end
		if args.title then return `{key}:{args.title}` end
		if args.n then return `{key}:{args.n}` end
		if args.done then return `{key}:{args.done}/{args.total}` end
		return key
	end
	local zeron = {
		window = function() return { shown = shown, active = true } end,
		s = say, t = function(key, args) return function() return say(key, args) end end,
		tab = function(kind, build) same(kind, "checklist", "native tab kind"); draw = build end,
		place = function(_placement) end,
		compose = function(body, options) table.insert(composed, { body = body, options = options }) end,
		toast = function(text) table.insert(toasts, text) end,
	}
	local modules = {
		["@ds/button"] = node("button"), ["@ds/checkbox"] = node("checkbox"), ["@ds/icon"] = node("icon"),
		["@ds/dialog"] = { Dialog = node("dialog") }, ["@ds/icon_button"] = { IconButton = node("iconbutton") },
		["./toolbar_button"] = node("toolbar-button"), ["./checklist_parse"] = {}, ["./checklist_store"] = { new = function() return store end },
	}
	local api = loadChecklist(ui, function(name) return assert(modules[name], name) end).new(zeron)
	api.register()

	-- Realize only visible children, keeping keyed rows and presence state alive.
	local function children(root)
		if type(root) ~= "table" or read(root.hidden) == true or read(root.invisible) == true then return {} end
		if root.tag == "show" then return if read(root.test) then { root.child } else {} end
		if root.tag == "presence" then
			local key = root.test()
			if not root.cached or root.key ~= key then root.cached, root.key = root.build(key), key end
			return { root.cached }
		end
		if root.tag == "each" then
			local out, seen = {}, {}
			for i, row in read(root.source) do
				local key = if root.options and root.options.key then root.options.key(row) else tostring(i)
				local entry = root.cache[key]
				if not entry then
					entry = { state = state(row) }
					entry.node = root.build(row, i, entry.state)
					root.cache[key] = entry
				else
					entry.state:set(row)
				end
				seen[key] = true
				table.insert(out, entry.node)
			end
			for key in root.cache do if not seen[key] then root.cache[key] = nil end end
			return out
		end
		local out = {}
		for _, child in ipairs(root) do table.insert(out, child) end
		return out
	end
	local function text(root)
		local value = read(root)
		if type(value) == "string" then return value end
		if type(value) ~= "table" then return "" end
		local out = ""
		for _, child in children(value) do out ..= text(child) end
		return out
	end
	local function find(root, tag, label)
		if type(root) ~= "table" then return nil end
		if read(root.hidden) == true or read(root.invisible) == true then return nil end
		if root.tag == tag and (not label or text(root.label) == label or text(root.name) == label or text(root) == label) then return root end
		for _, child in children(root) do
			local found = find(child, tag, label)
			if found then return found end
		end
		return nil
	end
	local function checkbox(root, title)
		local function seek(node)
			if type(node) ~= "table" then return nil end
			if node.tag == "checkbox" and string.find(text(node.name) .. text(node.label), title, 1, true) then return node end
			for _, child in children(node) do local found = seek(child); if found then return found end end
			return nil
		end
		return assert(seek(root), `missing checkbox for {title}`)
	end
	return {
		rows = rows, operations = operations, composed = composed, toasts = toasts, loads = loads,
		toolbar = api.toolbar,
		set_shown = function(value) shown = value end,
		fail_load = function(sid) ready[sid] = false; revisions[sid] = (revisions[sid] or 0) + 1 end,
		build = function(sid) return draw({ data = { session = sid } }) end,
		find = find, checkbox = checkbox, text = text,
		button = function(root, key)
			return assert(find(root, "button", key), `missing visible button {key}`)
		end,
		take = function(kind)
			local operation = table.remove(operations, 1)
			assert(operation, `missing queued {kind}`)
			same(operation.kind, kind, "store operation")
			return operation
		end,
		flush = function() for _, effect in effects do effect() end end,
	}
end

-- The icon count loads without opening a panel and follows only its session.
do
	local h = host()
	local panel = nil
	local function current_panel() return panel end
	local toolbar = h.toolbar(current_panel)
	same(h.text(toolbar), "", "new-chat toolbar has no checklist entry")
	same(next(h.loads), nil, "new chat performs no checklist read")
	panel = { session = "A" }
	h.set_shown(false)
	h.flush()
	same(h.loads.A, nil, "hidden window does not load toolbar counts")
	h.set_shown(true)
	h.flush()
	same(h.loads.A, 1, "first visible conversation loads its count before panel opens")
	same(h.text(toolbar), "3", "total count includes the already completed item")
	same(read(toolbar.child.label), "checklist.open", "icon entry retains its accessible localized name")
	same(toolbar.child.tooltip, "checklist.open", "icon entry retains its tooltip")
	local rebuilt = h.toolbar(current_panel)
	h.flush()
	same(h.text(rebuilt), "3", "rebuilt toolbar uses the same session count")
	same(h.loads.A, 1, "rebuilding the toolbar does not requery cached count")
	panel = { session = "B" }
	h.flush()
	same(h.loads.B, 1, "new conversation loads its own count")
	same(h.text(toolbar), "1", "conversation switch never shows another count")
	panel = { session = "A" }
	h.flush()
	same(h.text(toolbar), "3", "returning conversation uses its cache")
	same(h.loads.A, 1, "switching back does not reload the same count")
	table.remove(h.rows.A, 1)
	h.flush()
	same(h.text(toolbar), "2", "count updates after items are removed")
	same(h.loads.A, 1, "count updates do not initiate reads")
	h.fail_load("A")
	h.flush()
	same(h.loads.A, 1, "failed count reads do not loop while the same conversation is shown")
	panel = { session = "B" }
	h.flush()
	panel = { session = "A" }
	h.flush()
	same(h.loads.A, 2, "returning to the conversation can retry a failed read")
	h.fail_load("A")
	h.flush()
	h.set_shown(false)
	h.flush()
	h.set_shown(true)
	h.flush()
	same(h.loads.A, 3, "restoring visibility can retry a failed read once")
	panel = nil
	h.flush()
	same(h.text(toolbar), "", "new chat hides a previous conversation count")
end

local function ids(operation, expected)
	same(#operation.ids, #expected, "selected item count")
	for i, id in expected do same(operation.ids[i], id, `selected id {i}`) end
end

-- Ordinary checkboxes still save completion. Selection only chooses rows.
do
	local h = host()
	local view = h.build("A")
	same(read(h.checkbox(view, "Alpha").value), false, "unfinished item initially unchecked")
	same(read(h.checkbox(view, "Beta").value), true, "completed item initially checked")
	h.checkbox(view, "Alpha").on_change(true)
	local single = h.take("set_done")
	ids(single, { 10 }); same(single.session, "A", "single completion session")
	h.rows.A[1].done = true
	single.resolve()
	h.button(view, "checklist.select").on_click()
	same(read(h.checkbox(view, "Alpha").value), false, "selecting does not preselect completed items")
	same(read(h.checkbox(view, "Beta").value), false, "done and selected states are independent")
	h.checkbox(view, "Alpha").on_change(true)
	same(#h.operations, 0, "choosing an item never writes completion")
	h.button(view, "checklist.cancel_select").on_click()
	same(read(h.checkbox(view, "Alpha").value), true, "leaving selection retains persisted completion")
	same(read(h.checkbox(view, "Beta").value), true, "other completed item stays complete")
end

-- Selection order never changes draft order; append once to the source draft.
do
	local h = host()
	local view = h.build("A")
	h.button(view, "checklist.select").on_click()
	h.checkbox(view, "Gamma").on_change(true)
	h.checkbox(view, "Alpha").on_change(true)
	local all = assert(h.find(view, "checkbox", "checklist.select_all"), "all checkbox")
	same(read(all.mixed), true, "some selected shows mixed")
	h.button(view, "checklist.insert_selected").on_click()
	same(#h.composed, 1, "one compose request for all selected issues")
	same(h.composed[1].body, "checklist.batch_prompt\n\nAlpha body\n\n---\n\nGamma body", "selected issues retain list order")
	same(h.composed[1].options.session, "A", "bulk insertion explicitly targets this conversation")
	same(h.composed[1].options.replace, false, "bulk insertion preserves existing draft")
	same(#h.operations, 0, "inserting selection does not change completion")
	same(h.find(view, "checkbox", "checklist.select_all"), nil, "successful insertion exits selection mode")
	h.button(view, "checklist.select").on_click()
	same(read(h.checkbox(view, "Alpha").value), false, "successful insertion clears the previous selection")
	all = assert(h.find(view, "checkbox", "checklist.select_all"), "all checkbox after reentering selection")
	all.on_change(true)
	same(read(all.value), true, "select all checks the control")
	same(read(all.mixed), false, "all selected is not mixed")
	same(read(h.checkbox(view, "Beta").value), true, "select all includes already completed issues")
	all.on_change(false)
	same(read(h.checkbox(view, "Alpha").value), false, "deselect all clears selection")
	same(read(h.button(view, "checklist.insert_selected").disabled), true, "empty selection cannot be inserted")
end

-- Failed completion keeps selection for retry; success exits selection and
-- returns checkboxes to the persisted completion state.
do
	local h = host()
	local view = h.build("A")
	h.button(view, "checklist.select").on_click()
	h.checkbox(view, "Gamma").on_change(true)
	h.checkbox(view, "Alpha").on_change(true)
	h.button(view, "checklist.complete_selected").on_click()
	local failed = h.take("set_many_done")
	ids(failed, { 10, 30 }); same(failed.session, "A", "bulk completion session"); same(failed.value, true, "bulk completion marks done")
	h.checkbox(view, "Beta").on_change(true)
	same(read(h.checkbox(view, "Beta").value), false, "saving locks selection changes")
	failed.reject("checklist.save_failed")
	same(read(h.checkbox(view, "Alpha").value), true, "failed save keeps Alpha selected")
	same(read(h.checkbox(view, "Gamma").value), true, "failed save keeps Gamma selected")
	h.button(view, "checklist.complete_selected").on_click()
	local retried = h.take("set_many_done")
	ids(retried, { 10, 30 })
	h.rows.A[1].done, h.rows.A[3].done = true, true
	retried.resolve()
	same(h.find(view, "checkbox", "checklist.select_all"), nil, "successful completion exits selection mode")
	same(read(h.checkbox(view, "Alpha").value), true, "completed target is shown complete")
	same(read(h.checkbox(view, "Gamma").value), true, "second completed target is shown complete")
	same(h.rows.B[1].done, false, "other conversation remains untouched")
	h.button(view, "checklist.select").on_click()
	same(read(h.checkbox(view, "Alpha").value), false, "reentering selection has no previous target selected")
	same(read(h.checkbox(view, "Gamma").value), false, "successful completion clears all previous selection")
end

-- Confirmation freezes target IDs and ignores attempts to interact behind it.
-- Deletion failure keeps the original selection for a retry.
do
	local h = host()
	local view = h.build("A")
	h.button(view, "checklist.select").on_click()
	h.checkbox(view, "Alpha").on_change(true)
	h.checkbox(view, "Gamma").on_change(true)
	h.button(view, "checklist.remove_selected").on_click()
	local dialog = assert(h.find(view, "dialog"), "delete confirmation")
	same(read(dialog.open), true, "bulk deletion requires confirmation")
	same(#h.operations, 0, "opening confirmation does not delete")
	h.checkbox(view, "Gamma").on_change(false)
	h.checkbox(view, "Beta").on_change(true)
	same(read(h.checkbox(view, "Gamma").value), true, "modal blocks deselecting a deletion target")
	same(read(h.checkbox(view, "Beta").value), false, "modal blocks adding another target")
	dialog.open:set(false)
	same(read(h.checkbox(view, "Alpha").value), true, "canceling confirmation retains the selection")
	same(#h.operations, 0, "canceling confirmation performs no delete")
	h.button(view, "checklist.remove_selected").on_click()
	dialog.confirm.on_click()
	local failed = h.take("remove_many")
	ids(failed, { 10, 30 }); same(failed.session, "A", "delete remains scoped to original snapshot")
	failed.reject("checklist.delete_failed")
	same(read(h.checkbox(view, "Alpha").value), true, "failed deletion retains selection")
	same(read(h.checkbox(view, "Gamma").value), true, "failed deletion retains its second target")
	dialog.confirm.on_click()
	local retried = h.take("remove_many")
	ids(retried, { 10, 30 })
	h.rows.A = { h.rows.A[2] }
	retried.resolve()
	same(read(dialog.open), false, "successful deletion closes confirmation")
	same(h.find(view, "checkbox", "checklist.select_all"), nil, "successful deletion exits selection mode")
	same(read(h.checkbox(view, "Beta").value), true, "surviving completed row shows its ordinary completion state")
	same(#h.rows.B, 1, "other session rows are retained")
	h.button(view, "checklist.select").on_click()
	same(read(h.checkbox(view, "Beta").value), false, "reentering after deletion starts with no selection")
end

-- Removing every row automatically returns to the empty ordinary checklist.
do
	local h = host()
	local view = h.build("A")
	h.button(view, "checklist.select").on_click()
	assert(h.find(view, "checkbox", "checklist.select_all")).on_change(true)
	h.button(view, "checklist.remove_selected").on_click()
	local dialog = assert(h.find(view, "dialog"))
	dialog.confirm.on_click()
	local operation = h.take("remove_many")
	ids(operation, { 10, 20, 30 })
	h.rows.A = {}
	operation.resolve()
	same(h.find(view, "checkbox", "checklist.select_all"), nil, "removing all rows exits selection without a manual cancel")
	same(read(h.button(view, "checklist.select").disabled), true, "empty normal checklist cannot enter selection")
end

-- Stale selected IDs are ignored, and a tab has an independent selection.
do
	local h = host()
	local first, other = h.build("A"), h.build("B")
	h.button(first, "checklist.select").on_click()
	h.checkbox(first, "Alpha").on_change(true)
	h.checkbox(first, "Gamma").on_change(true)
	h.rows.A = { h.rows.A[2], h.rows.A[3] }
	h.flush()
	h.button(first, "checklist.insert_selected").on_click()
	same(h.composed[1].body, "checklist.prompt\n\nGamma body", "deleted selected rows cannot be inserted")
	h.button(other, "checklist.select").on_click()
	same(read(h.checkbox(other, "Other").value), false, "other tab selection starts empty")
	h.checkbox(other, "Other").on_change(true)
	h.button(other, "checklist.insert_selected").on_click()
	same(h.composed[2].options.session, "B", "other tab insertion targets its own session")
	same(h.composed[2].body, "checklist.prompt\n\nOther session body", "other tab selection is independent")
end

-- The host limit includes the prompt and separator, with the exact limit allowed.
do
	local h = host()
	local overhead = #"checklist.batch_prompt\n\n\n\n---\n\n"
	h.rows.A[1].body = string.rep("a", 10000)
	h.rows.A[3].body = string.rep("b", 20000 - overhead - 10000)
	local view = h.build("A")
	h.button(view, "checklist.select").on_click()
	h.checkbox(view, "Alpha").on_change(true)
	h.checkbox(view, "Gamma").on_change(true)
	h.button(view, "checklist.insert_selected").on_click()
	same(#h.composed, 1, "exactly 20,000 bytes can be inserted")
	same(#h.composed[1].body, 20000, "prompt and separator count toward the byte limit")
end

-- Oversized merged content is rejected intact rather than partly inserted.
do
	local h = host()
	h.rows.A[1].body = string.rep("蛛", 4000)
	h.rows.A[3].body = string.rep("网", 4000)
	local view = h.build("A")
	h.button(view, "checklist.select").on_click()
	h.checkbox(view, "Alpha").on_change(true)
	h.checkbox(view, "Gamma").on_change(true)
	h.button(view, "checklist.insert_selected").on_click()
	same(#h.composed, 0, "oversized combined UTF-8 text never reaches truncating host")
	same(h.toasts[#h.toasts], "checklist.insert_too_long", "oversized selection gets a visible error")
	same(read(h.checkbox(view, "Alpha").value), true, "rejected insertion retains selection")
end

print("PASS checklist multiselect UI contracts")
