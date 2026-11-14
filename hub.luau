--!strict
local Badge = require("@ds/badge")
local Button = require("@ds/button")
local EmptyState = require("@ds/empty_state")
local Icon = require("@ds/icon")
local Stat = require("@ds/stat")
local Tabs = require("@ds/tabs")
local TextArea = require("@ds/text_area")
local TextField = require("@ds/text_field")
local ink = require("@ds/visual_ink")

local db = require("./db")
local radar = require("./radar")
local WebGauge = require("./web_gauge")

local M = {}

local PROVIDER_LABELS: { [string]: string } = {
	["codex"] = "Codex",
	["claude-code"] = "Claude Code",
	["antigravity"] = "Antigravity",
	["devin"] = "Devin",
	["grok"] = "Grok",
	["opencode"] = "OpenCode",
	["pi"] = "Pi",
	["cursor"] = "Cursor",
	["hermes"] = "Hermes",
	["muse"] = "Muse Code",
}

local function pretty_provider(id: string): string
	return PROVIDER_LABELS[id] or id
end

local function pretty_window(label: string, zeron: any): string
	local low = string.lower(label)
	if low == "session" then
		return zeron.s("hub.win_session")
	elseif low == "week" then
		return zeron.s("hub.win_week")
	elseif low == "day" then
		return zeron.s("hub.win_day")
	end
	return label
end

local function format_reset(ms: number?, zeron: any): string
	if not ms then
		return ""
	end
	local now_ms = os.time() * 1000
	local raw_diff = math.floor((ms - now_ms) / 1000)
	if raw_diff <= 0 then
		return zeron.s("hub.quota_expired")
	end
	local when_str: string
	if raw_diff < 60 then
		when_str = `{raw_diff}s`
	elseif raw_diff < 3600 then
		when_str = `{math.floor(raw_diff / 60)}m`
	elseif raw_diff < 86400 then
		local h = math.floor(raw_diff / 3600)
		local m = math.floor((raw_diff % 3600) / 60)
		when_str = `{h}h {m}m`
	else
		local d = math.floor(raw_diff / 86400)
		local h = math.floor((raw_diff % 86400) / 3600)
		when_str = `{d}d {h}h`
	end
	return zeron.s("hub.quota_resets", { when = when_str })
end

local function format_ago(ts: number): string
	if ts <= 0 then
		return ""
	end
	local d = math.max(0, os.time() - ts)
	if d < 60 then
		return `{d}s`
	elseif d < 3600 then
		return `{math.floor(d / 60)}m`
	elseif d < 86400 then
		return `{math.floor(d / 3600)}h`
	end
	return `{math.floor(d / 86400)}d`
end

function M.register(zeron: any, active_tab: State<string>)
	zeron.page {
		id = "spider-hub",
		title = zeron.t("page.title"),
		icon = "shield-check",
		build = function(_page: any): Node
			local filter_kind = ui.use_state("all")
			local search = ui.use_state("")
			local new_kind = ui.use_state("prompt")
			local new_title = ui.use_state("")
			local new_content = ui.use_state("")
			local filter_drawer_open = ui.use_state(false)
			local expanded_cards = ui.use_state({} :: { [number]: boolean })
			local editing_id = ui.use_state(0)
			local edit_title = ui.use_state("")
			local edit_content = ui.use_state("")

			local function stat_card(value_fn: string | () -> string, label: string, tone_fn: string | () -> string, icon_name: string, bar_color: string): Node
				return ui.row {
					grow = 1,
					min_w = 140,
					p = "$space.3",
					gap = "$space.3",
					items = "center",
					rounded = "$radius.xl",
					bg = "$surface.raised",
					border = 1,
					border_color = "$border.subtle",
					ui.div {
						w = 3,
						h = 36,
						rounded = "$radius.full",
						bg = bar_color,
						shrink = 0,
					},
					ui.column {
						grow = 1,
						min_w = 0,
						gap = 2,
						Stat {
							value = value_fn,
							label = label,
							tone = tone_fn,
						},
					},
					ui.div {
						w = 28,
						h = 28,
						rounded = "$radius.lg",
						bg = "$hover",
						items = "center",
						justify = "center",
						shrink = 0,
						Icon { name = icon_name :: any, size = 15, color = "$text.secondary" },
					},
				}
			end

			local function session_row(item: radar.SessionItem, badge_tone: string, badge_label: string): Node
				local stripe = if badge_tone == "warning"
					then "$zeron.tone.warning.ink"
					elseif badge_tone == "danger" then "$zeron.tone.danger.ink"
					else "$accent"

				local left_children: { any } = {
					grow = 1,
					min_w = 0,
					items = "center",
					gap = "$space.2",
					ui.div {
						w = 3,
						h = 18,
						rounded = "$radius.full",
						bg = stripe,
						shrink = 0,
					},
					Badge.Badge {
						badge_label,
						tone = badge_tone :: any,
						size = "sm",
						shape = "pill",
						dot = true,
					},
					ui.text {
						item.title,
						literal = true,
						text_size = "$font.size.sm",
						weight = "$font.weight.medium",
						color = "$text.primary",
						truncate = true,
					},
				}
				if item.branch and item.branch ~= "" then
					table.insert(left_children, Badge.Tag { item.branch, size = "sm" })
				end

				return ui.row {
					w_full = true,
					px = "$space.3",
					py = "$space.2",
					rounded = "$radius.lg",
					bg = "$surface.raised",
					border = 1,
					border_color = "$border.subtle",
					items = "center",
					justify = "between",
					gap = "$space.3",
					cursor = "pointer",
					hover = { bg = "$hover", border_color = "$border" },
					active = { bg = "$pressed" },
					on_click = function()
						zeron.open { session = item.id }
					end,
					ui.row(left_children),
					ui.row {
						shrink = 0,
						items = "center",
						gap = "$space.2",
						ui.text {
							format_ago(item.updated),
							text_size = "$font.size.xs",
							color = "$text.tertiary",
							tabular = true,
						},
						Icon { name = "arrow-up-right", size = 14, color = "$text.tertiary" },
					},
				}
			end

			local function build_radar(): Node
				local sum = radar.summary()
				local warn_pct = radar.warn_threshold()
				local all_accounts = radar.usage_accounts()
				local visible_accounts = radar.visible_accounts()
				local events = radar.events()
				local hidden_count = math.max(0, #all_accounts - #visible_accounts)

				local all_rows: { Node } = {}
				for _, s in sum.attention do
					table.insert(all_rows, session_row(s, "warning", zeron.s("hub.status_attention")))
				end
				for _, s in sum.failed do
					table.insert(all_rows, session_row(s, "danger", zeron.s("hub.status_failed")))
				end
				for _, s in sum.working do
					table.insert(all_rows, session_row(s, "accent", zeron.s("hub.status_working")))
				end

				-- Deduplicated provider filter chips when drawer is open
				local seen_prov: { [string]: boolean } = {}
				local filter_chips: { Node } = {}
				for _, acct in all_accounts do
					if not seen_prov[acct.provider] then
						seen_prov[acct.provider] = true
						local pid = acct.provider
						local is_vis = not radar.is_hidden(pid)
						table.insert(
							filter_chips,
							Button {
								tone = if is_vis then "accent" else "secondary",
								size = "xs",
								shape = "pill",
								on_click = function()
									radar.toggle_provider(pid)
								end,
								Icon { name = if is_vis then "eye" else "eye-closed", size = 12 },
								ui.text { pretty_provider(pid), literal = true },
							}
						)
					end
				end

				local acct_cards: { Node } = {}
				for _, acct in visible_accounts do
					local win_tiles: { Node } = {}
					for _, w in acct.windows do
						local pct = math.max(0, math.min(100, math.floor(w.remaining + 0.5)))
						local used_pct = math.max(0, math.min(100, math.floor((w.used or (100 - pct)) + 0.5)))
						local tone = if pct <= warn_pct then "danger" elseif pct <= warn_pct * 2 then "warning" else "success"
						local reset_txt = format_reset(w.resets_at, zeron)
						local pct_ink = if tone == "danger"
							then "$zeron.tone.danger.ink"
							elseif tone == "warning" then "$zeron.tone.warning.ink"
							else "$zeron.tone.success.ink"

						local meta_col: { any } = {
							grow = 1,
							min_w = 0,
							gap = "$space.2",
							ui.row {
								w_full = true,
								items = "center",
								justify = "between",
								gap = "$space.2",
								ui.text {
									pretty_window(w.label, zeron),
									literal = true,
									text_size = "$font.size.xs",
									weight = "$font.weight.semibold",
									color = "$text.primary",
									truncate = true,
								},
								ui.text {
									zeron.s("hub.quota_remaining", { pct = pct }),
									literal = true,
									text_size = "$font.size.xs",
									weight = "$font.weight.semibold",
									color = pct_ink,
									tabular = true,
								},
							},
							WebGauge.SilkBar { pct = pct, warn_pct = warn_pct },
						}

						local bottom_row: { any } = {
							w_full = true,
							items = "center",
							justify = "between",
							gap = "$space.2",
							ui.text {
								zeron.s("hub.quota_used", { pct = used_pct }),
								literal = true,
								text_size = "$font.size.xs",
								color = "$text.tertiary",
								tabular = true,
							},
						}
						if reset_txt ~= "" then
							table.insert(
								bottom_row,
								ui.row {
									items = "center",
									gap = 4,
									Icon { name = "clock-circle", size = 11, color = "$text.tertiary" },
									ui.text {
										reset_txt,
										literal = true,
										text_size = "$font.size.xs",
										color = "$text.tertiary",
									},
								}
							)
						end
						table.insert(meta_col, ui.row(bottom_row))

						table.insert(
							win_tiles,
							ui.row {
								grow = 1,
								min_w = 270,
								p = "$space.3",
								gap = "$space.3",
								items = "center",
								rounded = "$radius.lg",
								bg = "$background",
								border = 1,
								border_color = "$border.subtle",
								WebGauge.OrbWeb { pct = pct, warn_pct = warn_pct, size = 88 },
								ui.column(meta_col),
							}
						)
					end

					local header_left: { any } = {
						items = "center",
						gap = "$space.2",
						ui.div {
							w = 8,
							h = 8,
							rounded = "$radius.full",
							bg = if acct.error and acct.error ~= "" then "$zeron.tone.danger.ink" else "$accent",
						},
						ui.text {
							pretty_provider(acct.provider),
							literal = true,
							text_size = "$font.size.md",
							weight = "$font.weight.semibold",
							color = "$text.primary",
						},
					}
					if acct.plan and acct.plan ~= "" then
						table.insert(header_left, Badge.Tag { acct.plan, size = "sm" })
					end
					if acct.active then
						table.insert(
							header_left,
							Badge.Badge { zeron.s("hub.quota_active"), tone = "success", size = "sm", shape = "pill", dot = true }
						)
					end

					local header_right: { any } = {
						items = "center",
						gap = "$space.2",
					}
					if acct.error and acct.error ~= "" then
						table.insert(
							header_right,
							ui.text {
								acct.error,
								literal = true,
								text_size = "$font.size.xs",
								color = "$zeron.tone.danger.ink",
								truncate = true,
							}
						)
					end
					local pid_to_hide = acct.provider
					table.insert(
						header_right,
						Button {
							tone = "ghost",
							size = "xs",
							icon = true,
							label = zeron.s("hub.hide_provider"),
							on_click = function()
								radar.toggle_provider(pid_to_hide)
							end,
							Icon { name = "eye-closed", size = 13 },
						}
					)

					local card_children: { any } = {
						w_full = true,
						p = "$space.3",
						gap = "$space.3",
						rounded = "$radius.xl",
						bg = "$surface.raised",
						border = 1,
						border_color = "$border.subtle",
						ui.row {
							w_full = true,
							items = "center",
							justify = "between",
							gap = "$space.2",
							ui.row(header_left),
							ui.row(header_right),
						},
					}
					if #win_tiles > 0 then
						table.insert(
							card_children,
							ui.row {
								w_full = true,
								flex_wrap = true,
								gap = "$space.3",
								table.unpack(win_tiles),
							}
						)
					else
						table.insert(
							card_children,
							ui.row {
								w_full = true,
								px = "$space.3",
								py = "$space.2",
								rounded = "$radius.lg",
								bg = "$background",
								items = "center",
								gap = "$space.2",
								Icon { name = "info-circle", size = 13, color = "$text.tertiary" },
								ui.text {
									zeron.s("hub.no_windows"),
									text_size = "$font.size.xs",
									color = "$text.tertiary",
								},
							}
						)
					end
					table.insert(acct_cards, ui.column(card_children))
				end

				local event_nodes: { Node } = {}
				for _, ev in events do
					local tone = if ev.kind == "attention"
						then "warning"
						elseif ev.kind == "error" or ev.kind == "quota" then "danger"
						else "success"
					table.insert(
						event_nodes,
						ui.row {
							w_full = true,
							px = "$space.3",
							py = "$space.2",
							rounded = "$radius.lg",
							bg = "$surface.raised",
							border = 1,
							border_color = "$border.subtle",
							items = "center",
							justify = "between",
							gap = "$space.3",
							cursor = if ev.session then "pointer" else nil,
							hover = if ev.session then { bg = "$hover" } else nil,
							on_click = if ev.session
								then function()
									zeron.open { session = ev.session }
								end
								else nil,
							ui.row {
								grow = 1,
								min_w = 0,
								items = "center",
								gap = "$space.2",
								Badge.Dot { tone = tone :: any, size = 7 },
								ui.column {
									grow = 1,
									min_w = 0,
									gap = 2,
									ui.text {
										ev.title,
										literal = true,
										text_size = "$font.size.xs",
										weight = "$font.weight.medium",
										color = "$text.primary",
									},
									ui.text {
										ev.body,
										literal = true,
										text_size = "$font.size.xs",
										color = "$text.secondary",
										truncate = true,
									},
								},
							},
							ui.text {
								format_ago(ev.at),
								text_size = "$font.size.xs",
								color = "$text.tertiary",
								tabular = true,
							},
						}
					)
				end

				local quota_section_children: { any } = {
					w_full = true,
					gap = "$space.2",
					ui.row {
						w_full = true,
						flex_wrap = true,
						items = "center",
						justify = "between",
						gap = "$space.2",
						ui.text {
							zeron.s("hub.section_quota"),
							text_size = "$font.size.sm",
							weight = "$font.weight.semibold",
							color = "$text.primary",
						},
						ui.row {
							items = "center",
							gap = "$space.2",
							if #all_accounts > 0
								then Button {
									tone = if filter_drawer_open:get() then "accent" else "secondary",
									size = "xs",
									on_click = function()
										filter_drawer_open:set(not filter_drawer_open:peek())
									end,
									Icon { name = "tuning", size = 13 },
									ui.text {
										zeron.s("hub.manage_providers", { shown = #visible_accounts, total = #all_accounts }),
										literal = true,
									},
								}
								else ui.div { w = 0 },
							Button {
								tone = "secondary",
								size = "xs",
								busy = radar.refreshing,
								on_click = function()
									radar.refresh_usage()
								end,
								Icon { name = "refresh", size = 13 },
								ui.text { zeron.t("hub.refresh_quota") },
							},
						},
					},
				}

				if filter_drawer_open:get() and #filter_chips > 0 then
					table.insert(
						quota_section_children,
						ui.column {
							w_full = true,
							p = "$space.3",
							gap = "$space.2",
							rounded = "$radius.xl",
							bg = "$surface.raised",
							border = 1,
							border_color = "$border",
							ui.row {
								w_full = true,
								flex_wrap = true,
								items = "center",
								gap = "$space.1",
								table.unpack(filter_chips),
							},
							ui.row {
								w_full = true,
								items = "center",
								justify = "end",
								gap = "$space.2",
								Button {
									tone = "ghost",
									size = "xs",
									on_click = function()
										radar.hide_inactive_providers()
									end,
									ui.text { zeron.t("hub.filter_only_valid") },
								},
								Button {
									tone = "ghost",
									size = "xs",
									on_click = function()
										radar.show_all_providers()
									end,
									ui.text { zeron.t("hub.filter_show_all") },
								},
							},
						}
					)
				end

				if #acct_cards > 0 then
					for _, card in acct_cards do
						table.insert(quota_section_children, card)
					end
					if hidden_count > 0 and not filter_drawer_open:get() then
						table.insert(
							quota_section_children,
							ui.text {
								zeron.s("hub.hidden_hint", { n = hidden_count }),
								literal = true,
								text_size = "$font.size.xs",
								color = "$text.tertiary",
							}
						)
					end
				else
					table.insert(
						quota_section_children,
						ui.div {
							w_full = true,
							py = "$space.4",
							rounded = "$radius.xl",
							bg = "$surface.raised",
							border = 1,
							border_color = "$border.subtle",
							EmptyState {
								icon = "eye-closed",
								size = "sm",
								title = zeron.s("hub.no_quota_title"),
								body = zeron.s("hub.no_quota_body"),
							},
						}
					)
				end

				return ui.column {
					w_full = true,
					gap = "$space.5",
					ui.row {
						w_full = true,
						flex_wrap = true,
						gap = "$space.3",
						stat_card(
							tostring(#sum.working),
							zeron.s("hub.stat_working"),
							if #sum.working > 0 then "$accent" else "$text.primary",
							"status-working",
							"$accent"
						),
						stat_card(
							tostring(#sum.attention),
							zeron.s("hub.stat_attention"),
							if #sum.attention > 0 then "$zeron.tone.warning.ink" else "$text.primary",
							"status-input",
							"$zeron.tone.warning.ink"
						),
						stat_card(
							tostring(#sum.failed),
							zeron.s("hub.stat_failed"),
							if #sum.failed > 0 then "$zeron.tone.danger.ink" else "$text.primary",
							"danger-triangle",
							"$zeron.tone.danger.ink"
						),
						stat_card(function(): string
							local mq = radar.min_quota()
							return if mq ~= nil then `{math.floor(mq + 0.5)}%` else "—"
						end, zeron.s("hub.stat_quota"), function(): string
							local mq = radar.min_quota()
							if mq == nil then
								return "$text.secondary"
							elseif mq <= warn_pct then
								return "$zeron.tone.danger.ink"
							elseif mq <= warn_pct * 2 then
								return "$zeron.tone.warning.ink"
							end
							return "$zeron.tone.success.ink"
						end, "shield-check", "$zeron.tone.success.ink"),
					},
					ui.column(quota_section_children),
					ui.column {
						w_full = true,
						gap = "$space.2",
						ui.text {
							zeron.s("hub.section_sessions"),
							text_size = "$font.size.sm",
							weight = "$font.weight.semibold",
							color = "$text.primary",
						},
						if #all_rows > 0
							then ui.column { w_full = true, gap = "$space.2", table.unpack(all_rows) }
							else ui.row {
								w_full = true,
								p = "$space.4",
								gap = "$space.3",
								items = "center",
								justify = "between",
								rounded = "$radius.xl",
								bg = "$surface.raised",
								border = 1,
								border_color = "$border.subtle",
								ui.row {
									items = "center",
									gap = "$space.3",
									WebGauge.OrbWeb { pct = 100, warn_pct = warn_pct, size = 54 },
									ui.column {
										gap = 2,
										ui.text {
											zeron.s("hub.no_sessions_title"),
											text_size = "$font.size.sm",
											weight = "$font.weight.semibold",
											color = "$text.primary",
										},
										ui.text {
											zeron.s("hub.no_sessions_body"),
											text_size = "$font.size.xs",
											color = "$text.secondary",
										},
									},
								},
								Icon { name = "shield-check", size = 18, color = "$zeron.tone.success.ink" },
							},
					},
					ui.column {
						w_full = true,
						gap = "$space.2",
						ui.text {
							zeron.s("hub.section_events"),
							text_size = "$font.size.sm",
							weight = "$font.weight.semibold",
							color = "$text.primary",
						},
						if #event_nodes > 0
							then ui.column { w_full = true, gap = "$space.2", table.unpack(event_nodes) }
							else ui.row {
								w_full = true,
								px = "$space.3",
								py = "$space.2",
								rounded = "$radius.lg",
								bg = "$surface.raised",
								border = 1,
								border_color = "$border.subtle",
								items = "center",
								gap = "$space.2",
								Icon { name = "bell", size = 13, color = "$text.tertiary" },
								ui.text {
									zeron.s("hub.no_events"),
									text_size = "$font.size.xs",
									color = "$text.tertiary",
								},
							},
					},
				}
			end

			local function build_web_cards(): Node
				local q = string.lower(string.gsub(search:get(), "^%s*(.-)%s*$", "%1"))
				local fk = filter_kind:get()
				local exp_map = expanded_cards:get()
				local items = db.items()
				local cards: { Node } = {}

				for _, it in items do
					local kind_ok = fk == "all" or it.kind == fk
					local search_ok = q == ""
						or string.find(string.lower(it.title), q, 1, true) ~= nil
						or string.find(string.lower(it.content), q, 1, true) ~= nil
					if kind_ok and search_ok then
						local is_prompt = it.kind == "prompt"
						local is_expanded = exp_map[it.id] == true
						local is_long = #it.content > 140 or string.find(it.content, "\n", 1, true) ~= nil
						local item_id = it.id
						local item_title = it.title
						local item_content = it.content
						local next_kind = if is_prompt then "snippet" else "prompt"

						local card_head_left: { any } = {
							grow = 1,
							min_w = 0,
							items = "center",
							gap = "$space.2",
							ui.div {
								w = 3,
								h = 18,
								rounded = "$radius.full",
								bg = if is_prompt then "$accent" else "$zeron.syntax.string",
								shrink = 0,
							},
							Badge.Badge {
								zeron.s(if is_prompt then "hub.kind_prompt" else "hub.kind_snippet"),
								tone = if is_prompt then "accent" else "neutral",
								size = "sm",
								shape = "pill",
							},
							ui.text {
								item_title,
								literal = true,
								text_size = "$font.size.sm",
								weight = "$font.weight.semibold",
								color = "$text.primary",
								truncate = true,
							},
						}
						if it.project and it.project ~= "" then
							table.insert(card_head_left, Badge.Tag { it.project, size = "sm" })
						end

						local card_actions: { any } = {
							shrink = 0,
							items = "center",
							gap = "$space.1",
							Button {
								tone = "accent",
								size = "xs",
								on_click = function()
									zeron.compose(item_content)
									zeron.toast(zeron.s("composer.inserted"))
								end,
								Icon { name = "fast-tier-bold", size = 12 },
								ui.text { zeron.t("hub.insert_btn") },
							},
							Button {
								tone = "ghost",
								size = "xs",
								icon = true,
								label = zeron.s(if is_prompt then "hub.demote_btn" else "hub.promote_btn"),
								on_click = function()
									db.set_kind(item_id, next_kind)
								end,
								Icon { name = if is_prompt then "star-bold" else "star", size = 13 },
							},
							Button {
								tone = "ghost",
								size = "xs",
								icon = true,
								label = zeron.s("hub.edit_btn"),
								on_click = function()
									edit_title:set(item_title)
									edit_content:set(item_content)
									editing_id:set(item_id)
								end,
								Icon { name = "pen", size = 13 },
							},
							Button {
								tone = "ghost",
								size = "xs",
								icon = true,
								label = zeron.s("hub.delete_btn"),
								on_click = function()
									db.remove(item_id)
								end,
								Icon { name = "trash-bin-minimalistic", size = 13 },
							},
						}

						local body_node: Node = if is_expanded
							then ui.div {
								w_full = true,
								ui.text {
									item_content,
									literal = true,
									wrap = true,
									text_size = "$font.size.xs",
									color = "$text.secondary",
								},
							}
							else ui.div {
								w_full = true,
								max_h = 64,
								overflow = "hidden",
								ui.text {
									item_content,
									literal = true,
									wrap = true,
									text_size = "$font.size.xs",
									color = "$text.secondary",
								},
							}

						local card_children: { any } = {
							w_full = true,
							p = "$space.3",
							gap = "$space.2",
							rounded = "$radius.xl",
							bg = "$surface.raised",
							border = 1,
							border_color = if editing_id:get() == item_id then "$accent" else "$border.subtle",
							ui.row {
								w_full = true,
								items = "center",
								justify = "between",
								gap = "$space.2",
								ui.row(card_head_left),
								ui.row(card_actions),
							},
							body_node,
						}
						if is_long then
							table.insert(
								card_children,
								ui.row {
									w_full = true,
									justify = "end",
									Button {
										tone = "ghost",
										size = "xs",
										on_click = function()
											local next_exp = table.clone(expanded_cards:peek())
											next_exp[item_id] = not (next_exp[item_id] == true)
											expanded_cards:set(next_exp)
										end,
										ui.text { zeron.t(if is_expanded then "hub.collapse_btn" else "hub.expand_btn") },
									},
								}
							)
						end
						table.insert(cards, ui.column(card_children))
					end
				end

				if #cards > 0 then
					return ui.column { w_full = true, gap = "$space.2", table.unpack(cards) }
				end
				return ui.div {
					w_full = true,
					py = "$space.5",
					rounded = "$radius.xl",
					bg = "$surface.raised",
					border = 1,
					border_color = "$border.subtle",
					EmptyState {
						icon = "star",
						size = "sm",
						title = zeron.s("hub.empty_web_title"),
						body = zeron.s("hub.empty_web_body"),
					},
				}
			end

			local function count_by_kind(kind: string): number
				local n = 0
				for _, it in db.items() do
					if kind == "all" or it.kind == kind then
						n += 1
					end
				end
				return n
			end

			local function build_web_tab(): Node
				return ui.column {
					w_full = true,
					gap = "$space.4",
					-- Inline Edit drawer (kept mounted cleanly outside list presence, shown via ui.presence on editing_id only)
					ui.presence(function(): string
						local eid = editing_id:get()
						return if eid > 0 then tostring(eid) else ""
					end, function(ekey: string): Node
						if ekey == "" then
							return ui.div { h = 0 }
						end
						local eid = tonumber(ekey) or 0
						return ui.column {
							w_full = true,
							p = "$space.3",
							gap = "$space.2",
							rounded = "$radius.xl",
							bg = "$surface.raised",
							border = 1,
							border_color = "$accent",
							ui.row {
								w_full = true,
								items = "center",
								justify = "between",
								ui.row {
									items = "center",
									gap = "$space.2",
									Icon { name = "pen", size = 14, color = "$accent" },
									ui.text {
										zeron.t("hub.edit_btn"),
										text_size = "$font.size.sm",
										weight = "$font.weight.semibold",
										color = "$text.primary",
									},
								},
								Button {
									tone = "ghost",
									size = "xs",
									icon = true,
									on_click = function()
										editing_id:set(0)
									end,
									Icon { name = "close", size = 13 },
								},
							},
							TextField {
								value = edit_title,
								size = "sm",
								w_full = true,
							},
							TextArea {
								value = edit_content,
								rows = 3,
								max_rows = 8,
								size = "sm",
								w_full = true,
							},
							ui.row {
								w_full = true,
								justify = "end",
								gap = "$space.2",
								Button {
									tone = "secondary",
									size = "xs",
									on_click = function()
										editing_id:set(0)
									end,
									ui.text { zeron.t("hub.cancel_btn") },
								},
								Button {
									tone = "accent",
									size = "xs",
									on_click = function()
										db.update(eid, edit_title:peek(), edit_content:peek(), function()
											editing_id:set(0)
											zeron.toast(zeron.s("hub.updated_toast"))
										end)
									end,
									ui.text { zeron.t("hub.save_edit_btn") },
								},
							},
						}
					end, { w_full = true }),
					-- Weave New Strand composer card (inputs stay mounted so focus never drops)
					ui.column {
						w_full = true,
						p = "$space.3",
						gap = "$space.2",
						rounded = "$radius.xl",
						bg = "$surface.raised",
						border = 1,
						border_color = "$border.subtle",
						ui.row {
							w_full = true,
							flex_wrap = true,
							items = "center",
							justify = "between",
							gap = "$space.2",
							ui.row {
								items = "center",
								gap = "$space.2",
								Icon { name = "magic-stick", size = 14, color = "$accent" },
								ui.text {
									zeron.t("hub.composer_heading"),
									text_size = "$font.size.sm",
									weight = "$font.weight.semibold",
									color = "$text.primary",
								},
							},
							Tabs {
								value = new_kind,
								look = "pill",
								size = "sm",
								options = {
									{ value = "prompt", label = zeron.s("hub.kind_prompt") },
									{ value = "snippet", label = zeron.s("hub.kind_snippet") },
								},
							},
						},
						TextField {
							value = new_title,
							placeholder = zeron.s("hub.new_title_ph"),
							size = "sm",
							clearable = true,
							w_full = true,
						},
						TextArea {
							value = new_content,
							placeholder = zeron.s("hub.new_content_ph"),
							rows = 2,
							max_rows = 6,
							size = "sm",
							w_full = true,
						},
						ui.row {
							w_full = true,
							items = "center",
							justify = "end",
							gap = "$space.2",
							Button {
								tone = "ghost",
								size = "xs",
								on_click = function()
									new_title:set("")
									new_content:set("")
								end,
								ui.text { zeron.t("hub.clear_btn") },
							},
							Button {
								tone = "accent",
								size = "xs",
								on_click = function()
									if string.gsub(new_title:peek(), "%s+", "") ~= "" and string.gsub(new_content:peek(), "%s+", "") ~= "" then
										db.add(new_kind:peek(), new_title:peek(), new_content:peek(), nil, function()
											new_title:set("")
											new_content:set("")
										end)
									end
								end,
								Icon { name = "plus", size = 13 },
								ui.text { zeron.t("hub.save_btn") },
							},
						},
					},
					ui.row {
						w_full = true,
						flex_wrap = true,
						items = "center",
						justify = "between",
						gap = "$space.2",
						Tabs {
							value = filter_kind,
							look = "pill",
							size = "sm",
							options = {
								{
									value = "all",
									label = zeron.s("hub.filter_all"),
									count = function(): number
										return count_by_kind("all")
									end,
								},
								{
									value = "prompt",
									label = zeron.s("hub.filter_prompt"),
									count = function(): number
										return count_by_kind("prompt")
									end,
								},
								{
									value = "snippet",
									label = zeron.s("hub.filter_snippet"),
									count = function(): number
										return count_by_kind("snippet")
									end,
								},
							},
						},
						ui.div {
							w = 240,
							min_w = 160,
							TextField {
								value = search,
								icon = "search",
								placeholder = zeron.s("hub.search_placeholder"),
								size = "sm",
								clearable = true,
								w_full = true,
							},
						},
					},
					ui.presence(function(): string
						local items = db.items()
						local first_id = if items[1] then items[1].id else 0
						local exp = expanded_cards:get()
						local exp_n = 0
						for _, v in exp do
							if v then
								exp_n += 1
							end
						end
						return `{filter_kind:get()}:{search:get()}:{#items}:{first_id}:{db.rev()}:{exp_n}:{editing_id:get()}`
					end, function(): Node
						return build_web_cards()
					end, { w_full = true }),
				}
			end

			return ui.column {
				w_full = true,
				h_full = true,
				bg = "$background",
				ui.scroll {
					w_full = true,
					grow = 1,
					min_h = 0,
					ui.column {
						w_full = true,
						max_w = 920,
						mx = "auto",
						px = "$space.6",
						pt = "$space.6",
						pb = "$space.8",
						gap = "$space.4",
						-- Spider-Verse Hero Banner
						ui.div {
							w_full = true,
							relative = true,
							overflow = "hidden",
							rounded = "$radius.xl",
							bg = "$surface.raised",
							border = 1,
							border_color = "$border",
							ui.presence(function(): string
								if ui.theme and ui.theme.current then
									ui.theme.current:get()
								end
								return if zeron.read("appearance") == "light" then "light" else "dark"
							end, function(mode: string): Node
								return ui.div {
									w_full = true,
									h_full = true,
									opacity = if mode == "light" then 0.34 else 0.16,
									ui.image {
										src = if mode == "light" then "art/skyline-light.webp" else "art/skyline.webp",
										w_full = true,
										h_full = true,
										fit = "cover",
										aria_hidden = true,
									},
								}
							end, { absolute = true, left = 0, right = 0, top = 0, bottom = 0 }),
							ui.div {
								absolute = true,
								right = 0,
								top = 0,
								pointer_events = "none",
								WebGauge.CornerWeb { size = 108, alpha = 0.42 },
							},
							ui.row {
								w_full = true,
								p = "$space.4",
								items = "center",
								justify = "between",
								gap = "$space.3",
								flex_wrap = true,
								ui.row {
									items = "center",
									gap = "$space.3",
									ui.div {
										w = 44,
										h = 44,
										rounded = "$radius.xl",
										bg = "$background",
										border = 1,
										border_color = "$accent",
										items = "center",
										justify = "center",
										shrink = 0,
										ui.image {
											src = "art/spider-crest.webp",
											w = 30,
											h = 30,
											fit = "contain",
											aria_hidden = true,
										},
									},
									ui.column {
										gap = 3,
										ui.text {
											zeron.t("page.title"),
											text_size = "$font.size.xl",
											weight = "$font.weight.bold",
											color = "$text.primary",
										},
										ui.text {
											zeron.t("hub.subtitle"),
											text_size = "$font.size.xs",
											color = "$text.secondary",
										},
									},
								},
								ui.row {
									items = "center",
									gap = "$space.2",
									zeron.slot("hub_actions", {
										direction = "row",
										items = "center",
										gap = "$space.2",
									}),
									ui.presence(function(): string
									local s = radar.summary()
									return `{#s.attention}:{#s.failed}:{#s.working}:{if s.low_quota then "1" else "0"}`
								end, function(key: string): Node
									local attn_s, fail_s, work_s, low_s = string.match(key, "^(%d+):(%d+):(%d+):([01])$")
									local attn = tonumber(attn_s) or 0
									local fail = tonumber(fail_s) or 0
									local work = tonumber(work_s) or 0
									local low = low_s == "1"
									local alert = attn > 0 or fail > 0 or low
									local label = if alert
										then zeron.s("hub.hero_alert")
										elseif work > 0 then zeron.s("hub.hero_working", { n = work })
										else zeron.s("hub.hero_calm")
									local tone = if fail > 0 or low
										then "danger"
										elseif attn > 0 then "warning"
										elseif work > 0 then "accent"
										else "success"
									return Badge.Badge {
										label,
										tone = tone :: any,
										look = "soft",
										size = "sm",
										shape = "pill",
										dot = true,
									}
								end),
								},
							},
						},
						Tabs {
							value = active_tab,
							look = "underline",
							rule = true,
							options = {
								{
									value = "radar",
									label = zeron.s("hub.tab_radar"),
									icon = "shield-check",
									count = function(): number
										local s = radar.summary()
										return #s.working + #s.attention + #s.failed
									end,
								},
								{
									value = "web",
									label = zeron.s("hub.tab_web"),
									icon = "magic-stick",
									count = function(): number
										return #db.items()
									end,
								},
							},
						},
						ui.presence(function(): string
							local tab = active_tab:get()
							if tab == "web" then
								return "web"
							end
							local s = radar.summary()
							local sig_parts: { string } = {}
							for _, list in { s.attention, s.working, s.failed } do
								for _, it in list do
									table.insert(sig_parts, `{it.id}:{it.status}`)
								end
							end
							local dopen = if filter_drawer_open:get() then "1" else "0"
							return `radar:{table.concat(sig_parts, ",")}:{radar.usage_rev()}:{radar.hidden_rev()}:{radar.events_rev()}:{radar.warn_threshold()}:{dopen}`
						end, function(key: string): Node
							if key == "web" then
								return build_web_tab()
							end
							return build_radar()
						end, { w_full = true }),
					},
				},
			}
		end,
	}
end

return M
