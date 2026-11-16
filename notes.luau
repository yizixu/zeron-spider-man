--!strict
local Button = require("@ds/button")
local Dialog = require("@ds/dialog").Dialog
local Icon = require("@ds/icon")
local IconButton = require("@ds/icon_button").IconButton
local Dropdown = require("@ds/dropdown")
local TextArea = require("@ds/text_area")
local TextField = require("@ds/text_field")
local ToolbarButton = require("./toolbar_button")
local WebGauge = require("./web_gauge")
local NotesStore = require("./notes_store")

local M = {}

local function trim(text: string): string
	return string.gsub(text, "^%s*(.-)%s*$", "%1")
end

function M.new(zeron: any): any
	local store = NotesStore.new(zeron)
	local kept_draft = zeron.store("notes_draft", { body = "", source = {}, id = 0 })
	local restored = kept_draft:peek()
	local body = ui.state("spider_notes_draft_body", restored.body)
	local source = ui.state("spider_notes_draft_source", restored.source)
	local edit_id = ui.state("spider_notes_draft_id", restored.id)
	local busy = ui.state("spider_notes_busy", false)
	local deleting = ui.state("spider_notes_deleting", false)
	local error_text = ui.state("spider_notes_form_error", "")
	local pending = ui.state("spider_notes_pending", nil :: any)
	local api = {}
	busy:set(false)
	deleting:set(false)
	store.init()
	ui.effect(function()
		kept_draft:set({ body = body:get(), source = source:get(), id = edit_id:get() })
	end)

	local function source_of(session: any, message: any?): any
		if not session or type(session.id) ~= "string" then
			return {}
		end
		local project = zeron.projects()[session.project or ""]
		return {
			session = session.id,
			title = session.title or "",
			project = if project then project.name else nil,
			message = if message then message.id else nil,
		}
	end

	local function clear_draft()
		body:set("")
		source:set({})
		edit_id:set(0)
		error_text:set("")
	end

	local function save(on_done: (() -> ())?)
		if busy:peek() or deleting:peek() then return end
		if trim(body:peek()) == "" then
			error_text:set(zeron.s("notes.required"))
			return
		end
		local text, id, origin = body:peek(), edit_id:peek(), source:peek()
		busy:set(true)
		error_text:set("")
		store.save(if id > 0 then id else nil, text, origin, function(saved_id: number)
			busy:set(false)
			-- A user can keep typing while a write is in flight. Keep those edits.
			if body:peek() == text and edit_id:peek() == id then
				clear_draft()
				if on_done then on_done() end
			else
				edit_id:set(saved_id)
			end
			zeron.toast(zeron.s("notes.saved"))
		end, function(key: string)
			busy:set(false)
			if key == "notes.missing" then edit_id:set(0) end
			error_text:set(zeron.s(key))
		end)
	end

	local function delete_dialog(confirm_open: State<boolean>, delete_id: State<number>): Node
		return Dialog {
			open = confirm_open, title = zeron.t("notes.delete_title"), body = zeron.t("notes.delete_body"), tone = "danger",
			confirm = {
				label = zeron.t("notes.delete"), keep_open = true, busy = function() return deleting:get() end,
				on_click = function()
					local id = delete_id:peek()
					if busy:peek() or deleting:peek() then return end
					local draft_before = body:peek()
					deleting:set(true)
					store.remove(id, function()
						deleting:set(false)
						confirm_open:set(false)
						if edit_id:peek() == id then
							if body:peek() == draft_before then
								clear_draft()
							else
								edit_id:set(0)
							end
						end
						zeron.toast(zeron.s("notes.deleted"))
					end, function(key: string)
						deleting:set(false)
						zeron.toast(zeron.s(key))
					end)
				end,
			},
		}
	end

	local function editor(on_done: (() -> ())?): Node
		local discard_open = ui.use_state(false)
		return ui.column {
			w_full = true, gap = "$space.3",
			ui.show(function() return source:get().session ~= nil end, ui.text {
				function(): string
					local s = source:get()
					return if s.session then zeron.s("notes.linked", { title = s.title or s.session }) else ""
				end,
				literal = true, truncate = true, text_size = "$font.size.xs", color = "$text.secondary",
			}),
			TextArea {
				value = body, name = zeron.s("notes.body_label"),
				placeholder = zeron.s("notes.placeholder"), rows = 4, max_rows = 10, w_full = true,
				on_submit = function() save(on_done) end,
			},
			ui.show(function() return error_text:get() ~= "" end,
				ui.text { function() return error_text:get() end, literal = true, wrap = true, color = "$zeron.tone.danger.ink", text_size = "$font.size.sm" }),
			ui.show(function() return store.error() ~= nil end, ui.row {
				flex_wrap = true, gap = "$space.2", items = "center",
				ui.text { zeron.t("notes.load_failed"), wrap = true, color = "$zeron.tone.danger.ink", text_size = "$font.size.sm" },
				Button { tone = "secondary", size = "xs", on_click = store.init, ui.text { zeron.t("notes.retry") } },
			}),
			ui.text { zeron.t("notes.draft_hint"), color = "$text.secondary", text_size = "$font.size.xs", wrap = true },
			ui.row {
				w_full = true, gap = "$space.2", items = "center",
				Button {
					tone = "ghost", size = "sm", shrink = 0,
					disabled = function() return busy:get() or (body:get() == "" and edit_id:get() == 0) end,
					on_click = function() discard_open:set(true) end,
					ui.text { zeron.t("notes.discard") },
				},
				ui.div { grow = 1 },
				if on_done then Button {
					tone = "secondary", size = "sm", shrink = 0,
					on_click = on_done,
					ui.text { zeron.t("notes.close") },
				} else nil,
				Button {
					tone = "accent", size = "sm", shrink = 0, busy = busy,
					disabled = function() return deleting:get() or trim(body:get()) == "" or not store.ready() end,
					on_click = function() save(on_done) end,
					ui.text { zeron.t("notes.save") },
				},
			},
			Dialog {
				open = discard_open, title = zeron.t("notes.discard_title"),
				body = zeron.t("notes.discard_body"), tone = "danger",
				confirm = {
					label = zeron.t("notes.discard"),
					busy = function() return busy:get() end,
					on_click = clear_draft,
				},
			},
		}
	end

	function api.count(): number return #store.items() end
	function api.has_pending(): boolean return pending:get() ~= nil end

	function api.toolbar(session_live: () -> any, route_live: () -> any): Node
		local open = ui.use_state(false)
		local selected_id = ui.use_state("")
		local hovered_id = ui.use_state("")
		local confirm_open = ui.use_state(false)
		local delete_id = ui.use_state(0)
		local function open_editor()
			if trim(body:peek()) == "" and edit_id:peek() == 0 then
				source:set(source_of(session_live(), nil))
			end
			open:set(true)
		end
		local function note_items(): { any }
			local out = {}
			for _, note in store.items() do
				-- Dropdown rows have a fixed single-line height. Keep every word
				-- searchable while leaving the saved text intact for insertion.
				local label = trim((string.gsub(note.content, "%s+", " ")))
				local hint = trim((string.gsub(note.session_title or note.project or "", "%s+", " ")))
				table.insert(out, {
					value = tostring(note.id),
					label = label,
					hint = if hint ~= "" then hint else nil,
					icon = "pen",
				})
			end
			return out
		end
		return ui.row {
			gap = "$space.1", items = "center", shrink = 0, h = 22,
			ui.show(function() return pending:get() == nil end, Dropdown {
				value = selected_id,
				items = note_items,
				search = zeron.t("notes.search"),
				label = zeron.t("notes.title"),
				width = 360,
				placement = { side = "top", align = "end", offset = 6 },
				on_open = function() hovered_id:set("") end,
				wrap_item = function(item: any, row: Node): Node
					return ui.row {
						w_full = true,
						on_hover = function(inside: boolean)
							if inside then
								hovered_id:set(item.value)
							elseif hovered_id:peek() == item.value then
								hovered_id:set("")
							end
						end,
						row,
					}
				end,
				trailing_item = function(item: any): Node
					return IconButton {
						invisible = function() return hovered_id:get() ~= item.value end,
						icon = "trash-bin-minimalistic", size = "sm", tone = "danger",
						label = zeron.t("notes.delete"),
						disabled = function() return busy:get() or deleting:get() end,
						on_click = function()
							delete_id:set(tonumber(item.value) :: number)
							confirm_open:set(true)
						end,
					}
				end,
				actions = {
					{
						label = zeron.t("notes.new"),
						icon = "plus",
						on_click = open_editor,
					},
				},
				empty = function(_query: string)
					return {
						title = zeron.t("notes.empty_list"),
						hint = zeron.t("notes.new_hint"),
					}
				end,
				on_choose = function(id: string)
					local chosen: any = nil
					for _, note in store.items() do
						if tostring(note.id) == id then
							chosen = note
							break
						end
					end
					if not chosen then return end
					local session = session_live()
					local session_id = if session and type(session.id) == "string" then session.id else ""
					ui.after(0, function()
						zeron.compose(chosen.content, { session = session_id, replace = false })
						zeron.toast(zeron.s("notes.inserted"))
					end)
				end,
				trigger = function(menu: any): Node
					return ToolbarButton {
						lit = function() return menu.open:get() end,
						label = zeron.t("notes.title"), tooltip = zeron.s("notes.title"),
						on_click = menu.toggle,
						Icon { name = "pen", size = 13 },
						ui.text {
							function(): string
								return tostring(api.count())
							end,
							literal = true, tabular = true,
						},
					}
				end,
			}),
			ui.show(function() return pending:get() ~= nil end, ToolbarButton {
				lit = function() return true end,
				on_click = function()
					local p = pending:peek()
					if not p then return end
					local s, r = session_live(), route_live()
					if (p.session and (not s or s.id ~= p.session)) or (not p.session and (not r or r.name ~= "home")) then
						zeron.toast(zeron.s("notes.target_changed"))
						return
					end
					zeron.compose(p.content)
					pending:set(nil)
					zeron.toast(zeron.s("notes.inserted"))
				end,
				ui.text { zeron.t("notes.insert") },
			}),
			ui.show(function() return pending:get() ~= nil end, IconButton {
				icon = "close", size = "sm", label = zeron.t("notes.cancel"),
				on_click = function() pending:set(nil) end,
			}),
			Dialog {
				open = open, title = zeron.t("notes.title"), size = "md",
				cancel = false,
				build = function() return editor(function() open:set(false) end) end,
			},
			delete_dialog(confirm_open, delete_id),
		}
	end

	function api.register()
		zeron.place {
			at = ".message-actions",
			after = function(): Node
				local msg = zeron.context("message")
				local session = zeron.context("session")
				if not msg or type(msg.text) ~= "string" or trim(msg.text) == "" then return ui.div {} end
				local saving = ui.use_state(false)
				return Button {
					tone = "ghost", size = "xs", busy = saving, label = zeron.t("notes.capture"),
					on_click = function()
						saving:set(true)
						store.save(nil, msg.text, source_of(session, msg), function()
							saving:set(false)
							zeron.toast(zeron.s("notes.captured"))
						end, function(key: string)
							saving:set(false)
							zeron.toast(zeron.s(key))
						end)
					end,
					Icon { name = "pen", size = 12 }, ui.text { zeron.t("notes.capture") },
				}
			end,
		}
	end

	function api.build(): Node
		local search = ui.use_state("")
		local expanded = ui.use_state(0)
		local confirm_open = ui.use_state(false)
		local delete_id = ui.use_state(0)
		store.init()
		return ui.column {
			w_full = true, gap = "$space.4",
			ui.column {
				w_full = true, relative = true, p = "$space.4", gap = "$space.3",
				rounded = "$radius.xl", bg = "$surface.raised", border = 1, border_color = "$border",
				ui.div { absolute = true, right = 0, top = 0, pointer_events = "none", WebGauge.CornerWeb { size = 64, alpha = 0.3 } },
				ui.text { zeron.t("notes.title"), text_size = "$font.size.lg", weight = "$font.weight.semibold", color = "$text.primary" },
				editor(nil),
			},
			TextField { value = search, label = zeron.s("notes.search_label"), placeholder = zeron.s("notes.search"), icon = "search", clearable = true, w_full = true },
			ui.presence(function(): string
				return `{store.rev()}:{tostring(store.ready())}:{store.error() or ""}:{search:get()}:{expanded:get()}`
			end, function(): Node
				if store.error() then
					return ui.column {
						gap = "$space.2", ui.text { zeron.s(store.error()), color = "$zeron.tone.danger.ink", wrap = true },
						Button { tone = "secondary", size = "sm", on_click = store.init, ui.text { zeron.t("notes.retry") } },
					}
				end
				if not store.ready() then return ui.text { zeron.t("notes.loading"), color = "$text.secondary" } end
				local cards: { any } = { w_full = true, gap = "$space.3" }
				local q = string.lower(trim(search:get()))
				for _, note in store.items() do
					local haystack = string.lower(note.content .. " " .. (note.session_title or "") .. " " .. (note.project or ""))
					if q ~= "" and not string.find(haystack, q, 1, true) then continue end
					local session_exists = note.session and zeron.sessions()[note.session] ~= nil
					table.insert(cards, ui.column {
						w_full = true, min_w = 0, p = "$space.3", gap = "$space.3", rounded = "$radius.lg",
						bg = "$surface.raised", border = 1, border_color = "$border.subtle",
						ui.row {
							w_full = true, items = "center", flex_wrap = true, gap = "$space.2",
							Icon { name = "pen", size = 14, color = "$accent" },
							ui.text { os.date("%m-%d %H:%M", note.updated_at), text_size = "$font.size.xs", color = "$text.secondary" },
							ui.text { note.project or "", literal = true, wrap = true, text_size = "$font.size.xs", color = "$text.secondary" },
						},
						ui.div {
							w_full = true, max_h = if expanded:get() == note.id then nil else 96, overflow = "hidden",
							ui.text { note.content, literal = true, wrap = true, text_size = "$font.size.sm", color = "$text.primary" },
						},
						if note.session then ui.text { zeron.s("notes.linked", { title = note.session_title or note.session }), literal = true, wrap = true, color = "$text.secondary", text_size = "$font.size.xs" } else nil,
						ui.row {
							w_full = true, flex_wrap = true, gap = "$space.2",
							Button { tone = "ghost", size = "xs", on_click = function() expanded:set(if expanded:peek() == note.id then 0 else note.id) end, ui.text { zeron.s(if expanded:get() == note.id then "notes.collapse" else "notes.expand") } },
							if session_exists then Button { tone = "ghost", size = "xs", on_click = function() zeron.open { session = note.session } end, ui.text { zeron.t("notes.origin") } } else nil,
							Button {
								tone = "secondary", size = "xs",
								on_click = function()
									if #note.content > 20000 then zeron.toast(zeron.s("notes.too_long")); return end
									local target = if session_exists then note.session else nil
									pending:set({ session = target, content = note.content })
									zeron.open(if target then { session = target } else "home")
									zeron.toast(zeron.s("notes.carry_hint"))
								end,
								ui.text { zeron.s(if session_exists then "notes.carry" else "notes.new_chat") },
							},
							Button {
								tone = "ghost", size = "xs", disabled = function() return busy:get() or deleting:get() end,
								on_click = function()
									if trim(body:peek()) ~= "" then zeron.toast(zeron.s("notes.finish_draft")); return end
									body:set(note.content)
									edit_id:set(note.id)
									source:set({ session = note.session, title = note.session_title, project = note.project, message = note.message })
									zeron.toast(zeron.s("notes.edit_hint"))
								end,
								ui.text { zeron.t("notes.edit") },
							},
							Button { tone = "ghost", size = "xs", disabled = function() return busy:get() or deleting:get() end, on_click = function() delete_id:set(note.id); confirm_open:set(true) end, ui.text { zeron.t("notes.delete") } },
						},
					})
				end
				if #cards == 0 then
					table.insert(cards, ui.text { zeron.s(if q == "" then "notes.empty_list" else "notes.no_results"), color = "$text.secondary", wrap = true, text_size = "$font.size.sm" })
				end
				return ui.column(cards)
			end, { w_full = true }),
			delete_dialog(confirm_open, delete_id),
		}
	end
	return api
end

return M
