--!strict
local Button = require("@ds/button")
local Checkbox = require("@ds/checkbox")
local Dialog = require("@ds/dialog").Dialog
local Icon = require("@ds/icon")
local IconButton = require("@ds/icon_button").IconButton
local ToolbarButton = require("./toolbar_button")
local Parse = require("./checklist_parse")
local Store = require("./checklist_store")

type Item = { id: number, message: string, title: string, body: string, done: boolean }

local M = {}
local KIND = "checklist"

function M.new(zeron: any)
	local store = Store.new(zeron)
	local count_requested: { [string]: number } = {}
	local api = {}

	local function open(panel: any)
		panel.open_tab {
			kind = KIND, title = zeron.s("checklist.title"), icon = "checklist",
			data = { key = KIND, session = panel.session },
		}
	end

	local function build_tab(tab: any): Node
		local sid = tab.data and tab.data.session
		if type(sid) ~= "string" or sid == "" then return ui.div {} end
		store.load(sid)
		local expanded = ui.use_state(0)
		local selecting = ui.use_state(false)
		local selected = ui.use_state({} :: { [string]: boolean })
		local delete_ids = ui.use_state({} :: { number })
		local confirm = ui.use_state(false)
		local deleting = ui.use_state(false)
		local completing = ui.use_state(false)
		local saving = ui.use_state(false)
		local items = ui.computed(function(): { Item } return store.items(sid) end)

		local function show_error(key: string)
			zeron.toast(zeron.s(key))
		end

		local function locked(): boolean
			return deleting:get() or completing:get() or saving:get() or confirm:get()
		end

		local function selected_items(): { Item }
			local found = {}
			local chosen = selected:get()
			for _, item in items:get() do
				if chosen[tostring(item.id)] then table.insert(found, item) end
			end
			return found
		end

		local function ids_of(rows: { Item }): { number }
			local ids = {}
			for _, item in rows do table.insert(ids, item.id) end
			return ids
		end

		local function exit_selection()
			selected:set({})
			selecting:set(false)
		end

		local function insert(rows: { Item })
			if #rows == 0 or locked() then return end
			local bodies = {}
			for _, item in rows do table.insert(bodies, item.body) end
			local prompt = if #rows > 1 then "checklist.batch_prompt" else "checklist.prompt"
			local text = zeron.s(prompt) .. "\n\n" .. table.concat(bodies, "\n\n---\n\n")
			if #text > 20000 then
				show_error("checklist.insert_too_long")
				return
			end
			zeron.compose(text, { session = sid, replace = false })
			exit_selection()
			zeron.toast(zeron.s("checklist.inserted"))
		end

		local function complete_selected()
			if locked() then return end
			local ids = ids_of(selected_items())
			if #ids == 0 then return end
			completing:set(true)
			store.set_many_done(sid, ids, true, function()
				exit_selection()
				completing:set(false)
			end, function(key: string)
				completing:set(false)
				show_error(key)
			end)
		end

		return ui.column {
			id = "spider-checklist", w_full = true, h_full = true, min_w = 0, min_h = 0,
			ui.row {
				w_full = true, px = "$space.3", py = "$space.2", gap = "$space.2", items = "center", shrink = 0,
				Icon { name = "checklist", size = 15, color = "$accent" },
				ui.text { zeron.t("checklist.title"), weight = "$font.weight.semibold", color = "$text.primary", grow = 1 },
				ui.text {
					function(): string
						if not store.ready(sid) then return "" end
						local rows = items:get()
						local done = 0
						for _, item in rows do if item.done then done += 1 end end
						return zeron.s("checklist.progress", { done = done, total = #rows })
					end,
					color = "$text.secondary", text_size = "$font.size.sm", tabular = true, shrink = 0,
				},
				Button {
					tone = "ghost", size = "xs", shrink = 0,
					label = function() return zeron.s(if selecting:get() then "checklist.cancel_select" else "checklist.select") end,
					disabled = function() return locked() or (not selecting:get() and (not store.ready(sid) or #items:get() == 0)) end,
					on_click = function()
						if locked() then return end
						selected:set({})
						selecting:set(not selecting:peek())
					end,
					ui.text { function() return zeron.s(if selecting:get() then "checklist.cancel_select" else "checklist.select") end },
				},
			},
			ui.show(function() return selecting:get() end, ui.column {
				w_full = true, shrink = 0, px = "$space.3", py = "$space.2", gap = "$space.2",
				ui.row {
					w_full = true, items = "center", gap = "$space.2", justify = "between", flex_wrap = true,
					Checkbox {
						label = zeron.t("checklist.select_all"),
						value = function() return #items:get() > 0 and #selected_items() == #items:get() end,
						mixed = function() return #selected_items() > 0 and #selected_items() < #items:get() end,
						on_change = function(checked: boolean)
							if locked() then return end
							local chosen: { [string]: boolean } = {}
							if checked then for _, item in items:get() do chosen[tostring(item.id)] = true end end
							selected:set(chosen)
						end,
					},
					ui.text {
						function() return zeron.s("checklist.selection", { n = #selected_items() }) end,
						color = "$text.secondary", text_size = "$font.size.sm", tabular = true,
					},
				},
				ui.row {
					w_full = true, items = "center", gap = "$space.1", flex_wrap = true,
					Button {
						tone = "secondary", size = "xs", label = zeron.t("checklist.insert_selected"),
						disabled = function() return locked() or #selected_items() == 0 end,
						on_click = function() insert(selected_items()) end,
						ui.text { zeron.t("checklist.insert_selected") },
					},
					Button {
						tone = "secondary", size = "xs", label = zeron.t("checklist.complete_selected"), busy = completing,
						disabled = function() return locked() or #selected_items() == 0 end,
						on_click = complete_selected,
						ui.text { zeron.t("checklist.complete_selected") },
					},
					Button {
						tone = "ghost", size = "xs", label = zeron.t("checklist.remove_selected"),
						disabled = function() return locked() or #selected_items() == 0 end,
						on_click = function()
							if locked() then return end
							local ids = ids_of(selected_items())
							if #ids == 0 then return end
							delete_ids:set(ids)
							confirm:set(true)
						end,
						ui.text { zeron.t("checklist.remove_selected") },
					},
				},
			}),
			ui.div { h = 1, w_full = true, bg = "$border", shrink = 0 },
			ui.scroll {
				w_full = true, grow = 1, min_h = 0,
				ui.column {
					w_full = true, gap = "$space.2", p = "$space.3",
					ui.presence(function(): string
						local problem = store.error(sid)
						if problem then return problem end
						if not store.ready(sid) then return "checklist.loading" end
						return if #items:get() == 0 then "checklist.empty" else ""
					end, function(key: string): Node
						if key == "" then return ui.div {} end
						return ui.column {
							w_full = true, gap = "$space.2", py = "$space.2", items = "start",
							ui.text { zeron.t(key), wrap = true, color = "$text.secondary", text_size = "$font.size.sm" },
							if key == "checklist.load_failed" then Button {
								tone = "secondary", size = "sm", on_click = function() store.load(sid) end,
								ui.text { zeron.t("checklist.retry") },
							} else nil,
						}
					end, { w_full = true }),
					ui.each(items, function(item: Item, _index: number, row: State<Item>): Node
						local function is_open(): boolean return expanded:get() == item.id end
						return ui.column {
							w_full = true, min_w = 0, p = "$space.2", rounded = "$radius.md",
							bg = "$surface.raised", border = 1,
							border_color = function() return if selecting:get() and selected:get()[tostring(item.id)] then "$accent" else "$border.subtle" end,
							ui.row {
								w_full = true, min_w = 0, items = "center", gap = "$space.2",
								Checkbox {
									bare = true,
									name = function()
										return zeron.s(if selecting:get() then "checklist.select_item" else "checklist.complete_item", { title = item.title })
									end,
									value = function() return if selecting:get() then selected:get()[tostring(item.id)] == true else row:get().done end,
									on_change = function(done: boolean)
										if locked() then return end
										if selecting:peek() then
											local chosen = table.clone(selected:peek())
											chosen[tostring(item.id)] = if done then true else nil
											selected:set(chosen)
											return
										end
										saving:set(true)
										store.set_done(sid, item.id, done, function()
											saving:set(false)
										end, function(key: string)
											saving:set(false)
											show_error(key)
										end)
									end,
								},
								Button {
									tone = "ghost", size = "sm", grow = 1, min_w = 0, h = "auto", min_h = 28,
									justify = "between", px = "$space.1", py = "$space.1",
									label = item.title, expanded = is_open,
									on_click = function() expanded:set(if is_open() then 0 else item.id) end,
									ui.text {
										item.title, literal = true, wrap = true, grow = 1, min_w = 0,
										color = function() return if row:get().done then "$text.secondary" else "$text.primary" end,
									},
									ui.show(function() return selecting:get() and row:get().done end,
										Icon { name = "check-circle", size = 13, color = "$zeron.tone.success.ink" }),
									Icon { name = function() return if is_open() then "alt-arrow-up" else "alt-arrow-down" end, size = 12 },
								},
							},
							ui.presence(is_open, function(visible: boolean): Node
								if not visible then return ui.div {} end
								return ui.column {
									w_full = true, pt = "$space.2", gap = "$space.2",
									ui.text { item.body, literal = true, selectable = true, wrap = true, color = "$text.secondary", text_size = "$font.size.sm" },
									ui.row {
										w_full = true, items = "center", justify = "between", gap = "$space.1", flex_wrap = true,
										Button {
											tone = "secondary", size = "xs", disabled = locked, on_click = function() insert({ item }) end,
											ui.text { zeron.t("checklist.insert") },
										},
										IconButton {
											icon = "trash-bin-minimalistic", tone = "danger", size = "sm",
											label = zeron.t("checklist.remove"), tooltip = zeron.s("checklist.remove"),
											disabled = locked,
											on_click = function()
												if locked() then return end
												delete_ids:set({ item.id })
												confirm:set(true)
											end,
										},
									},
								}
							end, { w_full = true }),
						}
					end, { key = function(item: Item) return tostring(item.id) end, w_full = true, gap = "$space.2" }),
				},
			},
			Dialog {
				open = confirm, tone = "danger",
				title = function() return zeron.s(if #delete_ids:get() > 1 then "checklist.remove_many_title" else "checklist.remove_title", { n = #delete_ids:get() }) end,
				body = zeron.t("checklist.remove_body"),
				confirm = {
					label = zeron.t("checklist.remove"), keep_open = true, busy = function() return deleting:get() end,
					on_click = function()
						if deleting:peek() or completing:peek() or saving:peek() then return end
						local ids = table.clone(delete_ids:peek())
						if #ids == 0 then return end
						deleting:set(true)
						store.remove_many(sid, ids, function()
							exit_selection()
							deleting:set(false)
							confirm:set(false)
						end, function(key: string)
							deleting:set(false)
							show_error(key)
						end)
					end,
				},
			},
		}
	end

	function api.toolbar(panel_live: () -> any): Node
		-- Load on entering a visible conversation, not while rendering its count.
		-- A failed read changes the revision and can retry on the next entry.
		local count_session: string? = nil
		ui.effect(function()
			if not zeron.window().shown then count_session = nil; return end
			local panel = panel_live()
			local sid = if panel and type(panel.session) == "string" and panel.session ~= "" then panel.session else nil
			if sid == count_session then return end
			count_session = sid
			if not sid or store.ready(sid) then return end
			local revision = store.rev(sid)
			if count_requested[sid] == revision then return end
			count_requested[sid] = revision
			store.load(sid)
		end)
		return ui.show(function(): boolean
			local panel = panel_live()
			return panel ~= nil and type(panel.session) == "string" and panel.session ~= ""
		end, ToolbarButton {
			label = zeron.t("checklist.open"), tooltip = zeron.s("checklist.open"),
			on_click = function()
				local panel = panel_live()
				if panel and type(panel.session) == "string" and panel.session ~= "" then open(panel) end
			end,
			Icon { name = "checklist", size = 13 },
			ui.text {
				function(): string
					local panel = panel_live()
					return tostring(if panel and type(panel.session) == "string" then #store.items(panel.session) else 0)
				end,
				literal = true,
				tabular = true,
			},
		})
	end

	function api.register()
		zeron.tab(KIND, build_tab)
		zeron.place {
			at = ".message-actions",
			after = function(): Node
				local message = zeron.context("message")
				local panel = zeron.context("panel")
				if not message or message.role ~= "assistant" or type(message.id) ~= "string"
					or type(message.text) ~= "string" or message.text == ""
					or not panel or type(panel.session) ~= "string" or panel.session == "" then
					return ui.div {}
				end
				local saving = ui.use_state(false)
				return Button {
					tone = "ghost", size = "xs", busy = saving, label = zeron.t("checklist.capture"),
					on_click = function()
						if saving:peek() then return end
						local entries = Parse.parse(message.text)
						if #entries == 0 then
							zeron.toast(zeron.s("checklist.no_list"))
							return
						end
						saving:set(true)
						store.add(panel.session, message.id, entries, function(added: number)
							saving:set(false)
							open(panel)
							zeron.toast(zeron.s(if added > 0 then "checklist.added" else "checklist.already_added", { n = added }))
						end, function(key: string)
							saving:set(false)
							zeron.toast(zeron.s(key))
						end)
					end,
					Icon { name = "checklist", size = 12 },
					ui.text { zeron.t("checklist.capture") },
				}
			end,
		}
	end

	return api
end

return M
