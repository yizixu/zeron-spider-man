--!strict
local Button = require("@ds/button")
local Dialog = require("@ds/dialog").Dialog
local Dropdown = require("@ds/dropdown")
local Icon = require("@ds/icon")
local IconButton = require("@ds/icon_button").IconButton
local TextArea = require("@ds/text_area")
local TextField = require("@ds/text_field")
local ToolbarButton = require("./toolbar_button")
local db = require("./db")

local M = {}

local function trim(text: string): string
	return string.gsub(text, "^%s*(.-)%s*$", "%1")
end

function M.toolbar(zeron: any, session_live: () -> any): Node
	local selected_id = ui.use_state("")
	local hovered_id = ui.use_state("")
	local editor_open = ui.use_state(false)
	local title = ui.use_state("")
	local content = ui.use_state("")
	local saving = ui.use_state(false)
	local error_text = ui.use_state("")
	local confirm_open = ui.use_state(false)
	local delete_id = ui.use_state(0)
	local deleting = ui.use_state(false)
	local edit_open = ui.use_state(false)
	local edit_id = ui.use_state(0)
	local edit_title = ui.use_state("")
	local edit_content = ui.use_state("")
	local edit_saving = ui.use_state(false)
	local edit_error = ui.use_state("")

	local function save_edit()
		if edit_saving:peek() or deleting:peek() or not db.ready() then return end
		local id, name, body = edit_id:peek(), edit_title:peek(), edit_content:peek()
		if trim(name) == "" or trim(body) == "" then
			edit_error:set(zeron.s("prompts.required"))
			return
		end
		edit_saving:set(true)
		edit_error:set("")
		db.update(id, name, body, function()
			edit_saving:set(false)
			if edit_title:peek() == name and edit_content:peek() == body then
				edit_open:set(false)
			end
			zeron.toast(zeron.s("hub.updated_toast"))
		end, function(_err: any)
			edit_saving:set(false)
			edit_error:set(zeron.s("db.save_failed"))
		end)
	end

	local function save()
		if saving:peek() or not db.ready() then return end
		local name, body = title:peek(), content:peek()
		if trim(name) == "" or trim(body) == "" then
			error_text:set(zeron.s("prompts.required"))
			return
		end
		saving:set(true)
		error_text:set("")
		db.add("prompt", name, body, nil, function()
			saving:set(false)
			if title:peek() == name and content:peek() == body then
				title:set("")
				content:set("")
				editor_open:set(false)
			end
			zeron.toast(zeron.s("prompts.saved"))
		end, function(_err: any)
			saving:set(false)
			error_text:set(zeron.s("db.save_failed"))
		end)
	end

	return ui.row {
		gap = "$space.1", items = "center", shrink = 0, h = 22,
		Dropdown {
			value = selected_id,
			items = function(): { any }
				local out = {}
				for _, item in db.prompts() do
					table.insert(out, { value = tostring(item.id), label = item.title, icon = "fast-tier" })
				end
				return out
			end,
			search = zeron.t("prompts.search"), label = zeron.t("composer.tagline"),
			width = 360, placement = { side = "top", align = "end", offset = 6 },
			loading = function() return not db.ready() end,
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
				return ui.row {
					items = "center", gap = "$space.1", shrink = 0,
					invisible = function() return hovered_id:get() ~= item.value end,
					IconButton {
						icon = "pen", size = "sm", label = zeron.t("hub.edit_btn"),
						disabled = function() return edit_saving:get() or deleting:get() end,
						on_click = function()
							for _, prompt in db.prompts() do
								if tostring(prompt.id) ~= item.value then continue end
								edit_id:set(prompt.id)
								edit_title:set(prompt.title)
								edit_content:set(prompt.content)
								edit_error:set("")
								edit_open:set(true)
								return
							end
						end,
					},
					IconButton {
						icon = "trash-bin-minimalistic", size = "sm", tone = "danger",
						label = zeron.t("hub.delete_btn"), disabled = function() return deleting:get() or edit_saving:get() end,
						on_click = function()
							delete_id:set(tonumber(item.value) :: number)
							confirm_open:set(true)
						end,
					},
				}
			end,
			actions = { {
				label = zeron.t("prompts.new"), icon = "plus",
				on_click = function() editor_open:set(true) end,
			} },
			empty = function(query: string)
				return {
					title = zeron.t(if query == "" then "prompts.empty" else "prompts.no_results"),
					hint = zeron.t("prompts.new_hint"),
				}
			end,
			on_choose = function(id: string)
				for _, item in db.prompts() do
					if tostring(item.id) ~= id then continue end
					local session = session_live()
					local session_id = if session and type(session.id) == "string" then session.id else ""
					ui.after(0, function()
						zeron.compose(item.content, { session = session_id, replace = false })
						zeron.toast(zeron.s("composer.inserted"))
					end)
					return
				end
			end,
			trigger = function(menu: any): Node
				return ToolbarButton {
					lit = function() return menu.open:get() end,
					label = zeron.t("composer.tagline"), on_click = menu.toggle,
					Icon { name = "fast-tier", size = 13 },
					ui.text { function() return `{zeron.s("composer.tagline")} ({#db.prompts()})` end, literal = true },
				}
			end,
		},
		Dialog {
			open = editor_open, title = zeron.t("prompts.new"), size = "md", cancel = false,
			build = function(): Node
				return ui.column {
					w_full = true, gap = "$space.3",
					TextField { value = title, label = zeron.s("prompts.title"), placeholder = zeron.s("hub.new_title_ph"), w_full = true },
					TextArea { value = content, name = zeron.s("prompts.content"), placeholder = zeron.s("hub.new_content_ph"), rows = 4, max_rows = 10, w_full = true, on_submit = save },
					ui.show(function() return error_text:get() ~= "" end,
						ui.text { function() return error_text:get() end, literal = true, wrap = true, color = "$zeron.tone.danger.ink", text_size = "$font.size.sm" }),
					ui.row {
						w_full = true, justify = "end", gap = "$space.2",
						Button { tone = "secondary", size = "sm", on_click = function() editor_open:set(false) end, ui.text { zeron.t("notes.close") } },
						Button {
							tone = "accent", size = "sm", busy = saving,
							disabled = function() return not db.ready() or trim(title:get()) == "" or trim(content:get()) == "" end,
							on_click = save, ui.text { zeron.t("notes.save") },
						},
					},
				}
			end,
		},
		Dialog {
			open = edit_open, title = zeron.t("prompts.edit"), size = "md", cancel = false,
			build = function(): Node
				return ui.column {
					w_full = true, gap = "$space.3",
					TextField { value = edit_title, label = zeron.s("prompts.title"), w_full = true },
					TextArea { value = edit_content, name = zeron.s("prompts.content"), rows = 4, max_rows = 10, w_full = true, on_submit = save_edit },
					ui.show(function() return edit_error:get() ~= "" end,
						ui.text { function() return edit_error:get() end, literal = true, wrap = true, color = "$zeron.tone.danger.ink", text_size = "$font.size.sm" }),
					ui.row {
						w_full = true, justify = "end", gap = "$space.2",
						Button { tone = "secondary", size = "sm", on_click = function() edit_open:set(false) end, ui.text { zeron.t("hub.cancel_btn") } },
						Button {
							tone = "accent", size = "sm", busy = edit_saving,
							disabled = function() return deleting:get() or not db.ready() or trim(edit_title:get()) == "" or trim(edit_content:get()) == "" end,
							on_click = save_edit, ui.text { zeron.t("hub.save_edit_btn") },
						},
					},
				}
			end,
		},
		Dialog {
			open = confirm_open, title = zeron.t("prompts.delete_title"), body = zeron.t("prompts.delete_body"), tone = "danger",
			confirm = {
				label = zeron.t("hub.delete_btn"), keep_open = true, busy = function() return deleting:get() end,
				on_click = function()
					if deleting:peek() or edit_saving:peek() then return end
					deleting:set(true)
					db.remove(delete_id:peek(), function()
						deleting:set(false)
						confirm_open:set(false)
						zeron.toast(zeron.s("prompts.deleted"))
					end, function(_err: any)
						deleting:set(false)
						zeron.toast(zeron.s("db.delete_failed"))
					end)
				end,
			},
		},
	}
end

return M
