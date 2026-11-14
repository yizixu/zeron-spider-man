--!strict
local zeron = require("./zeron")("spider-man")
local Button = require("@ds/button")
local Icon = require("@ds/icon")
local material = require("@ds/material")
local motion = require("@ds/motion")

local db = require("./db")
local radar = require("./radar")
local hub = require("./hub")
local pet = require("./pet")
local layout = require("./layout")

local parallax = zeron.setting("parallax")
local notify_events = zeron.setting("notify_events")
local quota_warn_pct = zeron.setting("quota_warn_pct")
local show_composer_deco = zeron.setting("show_composer_deco")
local show_quick_save = zeron.setting("show_quick_save")
local show_sidebar_deco = zeron.setting("show_sidebar_deco")
local show_pet = zeron.setting("show_pet")

local active_tab = ui.state("spider_hub_tab", "radar")

layout.reset()
db.init(zeron)
radar.init(zeron, notify_events, quota_warn_pct)
hub.register(zeron, active_tab)
pet.register(zeron, show_pet, radar.ensure_wired, radar.cleanup)

local STEP_X, STEP_Y = 16, 10
local REACH = { off = 0, subtle = 0.5, normal = 1, deep = 1.8 } :: { [string]: number }
local SPRING = { stiffness = 140, damping = 20 }

local QUOTES = { "quotes.q1", "quotes.q2", "quotes.q3", "quotes.q4" }

local function is_light_theme(): boolean
	if ui.theme and ui.theme.current then
		ui.theme.current:get()
	end
	return zeron.read("appearance") == "light"
end

local function themed_web_image(dark_src: string, light_src: string, w: number, h: number): Node
	return ui.presence(function(): string
		return if is_light_theme() then "light" else "dark"
	end, function(mode: string): Node
		return ui.image {
			src = if mode == "light" then light_src else dark_src,
			w = w,
			h = h,
			fit = "contain",
			aria_hidden = true,
		}
	end, { w = w, h = h, shrink = 0 })
end

local function SpiderScene(reach: number, pointer: () -> any, light: boolean): Node
	local function axis(name: string): State<number>
		return ui.computed(function(): number
			local p = pointer()
			local v = if type(p) == "table" then p[name] else nil
			return if type(v) == "number" then v else 0.5
		end)
	end
	local px, py = axis("x"), axis("y")

	local over_x = math.ceil(2 * STEP_X * reach)
	local over_y = math.ceil(2 * STEP_Y * reach)

	local function layer(src: string, depth: number): Node
		local d = depth * reach
		return ui.div {
			absolute = true,
			left = -over_x,
			right = -over_x,
			top = -over_y,
			bottom = -over_y,
			x = if d > 0
				then ui.spring(px, {
					from = d * STEP_X,
					to = -d * STEP_X,
					stiffness = SPRING.stiffness,
					damping = SPRING.damping,
				})
				else nil,
			y = if d > 0
				then ui.spring(py, {
					from = d * STEP_Y,
					to = -d * STEP_Y,
					stiffness = SPRING.stiffness,
					damping = SPRING.damping,
				})
				else nil,
			ui.image { src = src, w_full = true, h_full = true, fit = "cover", aria_hidden = true },
		}
	end

	return ui.div {
		id = "spider-man-scene",
		w_full = true,
		h_full = true,
		relative = true,
		overflow = "hidden",
		role = "img",
		label = zeron.t("wallpaper.aria_label"),
		layer(if light then "art/skyline-light.webp" else "art/skyline.webp", 0.6),
		layer(if light then "art/web-near-light.webp" else "art/web-near.webp", 1.8),
	}
end

-- 1. 3D Parallax NYC Skyline Wallpaper
zeron.place {
	at = "#new-chat-background",
	fill = true,
	replace = function(): Node
		local pointer = zeron.live("pointer")
		return ui.presence(function(): string
			local reach = if motion.reduced() then 0 else (REACH[parallax:get()] or 1)
			local app = if is_light_theme() then "light" else "dark"
			return `{reach}:{app}`
		end, function(key: string): Node
			local r_str, app = string.match(key, "^([^:]+):(.+)$")
			return SpiderScene(tonumber(r_str) or 1, pointer, app == "light")
		end, { w_full = true, h_full = true })
	end,
}

-- 2. Composer bottom web ornament + toggleable 1-click Quick Prompt drawer
-- On new chat ("home"), Zeron draws a fixed-height .composer-tray behind the footer
-- that tucks 40px up behind the 26px pill corners. Using a zero-height anchor here
-- keeps body height untouched so the tray stays seamless, while floating our pill below.
zeron.place {
	at = "#composer-toolbar",
	after = function(): Node
		local prompts_open = ui.use_state(false)
		local route_live = zeron.live("route")

		local function build_header(): Node
			return ui.row {
				w_full = true,
				h = 22,
				px = "$zeron.space.snug",
				items = "center",
				justify = "between",
				gap = "$space.2",
				ui.row {
					grow = 1,
					min_w = 0,
					items = "center",
					gap = "$space.2",
					themed_web_image("art/web-left.webp", "art/web-left-light.webp", 76, 20),
					ui.div {
						grow = 1,
						h = 1,
						bg = "$border",
						opacity = 0.55,
					},
					ui.div {
						w = 4,
						h = 4,
						rounded = "$radius.full",
						bg = "$accent",
						opacity = 0.75,
						shrink = 0,
					},
				},
				ui.button {
					shrink = 0,
					h = 22,
					items = "center",
					justify = "center",
					gap = "$space.1",
					px = "$space.2",
					py = 0,
					rounded = "$radius.full",
					cursor = "pointer",
					bg = function(): string
						return if prompts_open:get() then "$hover" else "#00000000"
					end,
					color = function(): string
						return if prompts_open:get() then "$accent" else "$text.tertiary"
					end,
					hover = { bg = "$hover", color = "$accent" },
					active = { bg = "$pressed", color = "$accent" },
					label = zeron.t("composer.tooltip"),
					on_click = function()
						prompts_open:set(not prompts_open:peek())
					end,
					ui.image {
						src = "art/spider-crest.webp",
						w = 15,
						h = 15,
						fit = "contain",
						shrink = 0,
						aria_hidden = true,
					},
					ui.text {
						function(): string
							local n = #db.prompts()
							return `{zeron.s("composer.tagline")} ({n})`
						end,
						literal = true,
						font = "$font.mono",
						text_size = "$font.size.xs",
					},
				},
				ui.row {
					grow = 1,
					min_w = 0,
					items = "center",
					gap = "$space.2",
					ui.div {
						w = 4,
						h = 4,
						rounded = "$radius.full",
						bg = "$zeron.syntax.string",
						opacity = 0.75,
						shrink = 0,
					},
					ui.div {
						grow = 1,
						h = 1,
						bg = "$border",
						opacity = 0.55,
					},
					themed_web_image("art/web-right.webp", "art/web-right-light.webp", 76, 20),
				},
			}
		end

		local function build_drawer(): Node
			return ui.presence(function(): string
				if not prompts_open:get() then
					return ""
				end
				return `open:{#db.prompts()}:{db.rev()}`
			end, function(key: string): Node
				if key == "" then
					return ui.div { h = 0 }
				end
				local list = db.prompts()
				local chips: { Node } = {}
				for i = 1, math.min(#list, 8) do
					local item = list[i]
					table.insert(
						chips,
						Button {
							tone = "secondary",
							size = "xs",
							shape = "pill",
							on_click = function()
								zeron.compose(item.content)
								zeron.toast(zeron.s("composer.inserted"))
								prompts_open:set(false)
							end,
							ui.text { item.title, literal = true },
						}
					)
				end
				table.insert(
					chips,
					Button {
						tone = "ghost",
						size = "xs",
						shape = "pill",
						on_click = function()
							active_tab:set("web")
							zeron.toast(zeron.s("composer.manage_hint"))
							prompts_open:set(false)
						end,
						Icon { name = "magic-stick", size = 12 },
						ui.text { zeron.t("composer.manage") },
					}
				)
				return ui.row {
					w_full = true,
					flex_wrap = true,
					mt = "$space.1",
					px = "$space.2",
					py = "$space.1",
					items = "center",
					justify = "center",
					gap = "$space.1",
					table.unpack(chips),
				}
			end)
		end

		return ui.div {
			ref = layout.ref("composer_toolbar"),
			w_full = true,
			ui.presence(function(): string
			if show_composer_deco:get() ~= true then
				return ""
			end
			local r = route_live()
			return if type(r) == "table" and r.name == "home" then "home" else "session"
		end, function(mode: string): Node
			if mode == "" then
				return ui.div { h = 0 }
			end
			if mode == "home" then
				return ui.div {
					w_full = true,
					h = 0,
					relative = true,
					overflow = "visible",
					pointer_events = "none",
					ui.column {
						id = "spider-composer-ornament",
						absolute = true,
						top = 8,
						left = 0,
						right = 0,
						rounded = "$zeron.composer.tray.radius",
						bg = function(): string
							return if material.see_through() then "$zeron.composer.tint" else "$zeron.composer.solid"
						end,
						backdrop_blur = function(): number
							return if material.see_through() then 16 else 0
						end,
						py = 5,
						pointer_events = "auto",
						build_header(),
						build_drawer(),
					},
				}
			end
			return ui.column {
				id = "spider-composer-ornament",
				w_full = true,
				mt = "$space.1",
				pointer_events = "auto",
				build_header(),
				build_drawer(),
			}
		end, { w_full = true })
		}
	end,
}

-- 3. Left sidebar bottom: Corner webs + clean non-overlapping patrol status
zeron.place {
	at = "#sidebar",
	after = function(): Node
		local quote_idx = ui.use_state(0)
		return ui.div {
			ref = layout.ref("sidebar"),
			w_full = true,
			shrink = 0,
			ui.show(function(): boolean
				return show_sidebar_deco:get() == true
			end, ui.column {
			id = "spider-sidebar-footer",
			w_full = true,
			shrink = 0,
			overflow = "hidden",
			gap = 0,
			ui.div {
				w_full = true,
				h = 1,
				bg = "$border",
				opacity = 0.55,
			},
			ui.row {
				w_full = true,
				h = 30,
				px = "$space.1",
				items = "center",
				justify = "between",
				gap = "$space.1",
				overflow = "hidden",
				themed_web_image("art/web-left.webp", "art/web-left-light.webp", 38, 18),
				ui.button {
					grow = 1,
					min_w = 0,
					h = 24,
					px = "$space.1",
					py = 0,
					items = "center",
					justify = "center",
					gap = "$space.1",
					bg = "#00000000",
					rounded = "$radius.full",
					cursor = "pointer",
					hover = { bg = "$hover" },
					active = { bg = "$pressed" },
					label = zeron.t("sidebar.tooltip"),
					on_click = function()
						local sum = radar.summary()
						if #sum.attention > 0 then
							zeron.open { session = sum.attention[1].id }
						elseif #sum.working > 0 then
							zeron.open { session = sum.working[1].id }
						else
							local next_i = (quote_idx:peek() % #QUOTES) + 1
							quote_idx:set(next_i)
							zeron.toast(zeron.s(QUOTES[next_i]))
						end
					end,
					ui.image {
						src = "art/spider-crest.webp",
						w = 13,
						h = 13,
						fit = "contain",
						shrink = 0,
						aria_hidden = true,
					},
					ui.text {
						function(): string
							local sum = radar.summary()
							if #sum.attention > 0 then
								return zeron.s("sidebar.footer_attention", { n = #sum.attention })
							elseif #sum.working > 0 then
								return zeron.s("sidebar.footer_working", { n = #sum.working })
							end
							return zeron.s("sidebar.footer")
						end,
						literal = true,
						font = "$font.mono",
						text_size = "$font.size.xs",
						color = function(): string
							local sum = radar.summary()
							if #sum.attention > 0 then
								return "$warning"
							elseif #sum.working > 0 then
								return "$accent"
							end
							return "$text.tertiary"
						end,
						truncate = true,
					},
				},
				themed_web_image("art/web-right.webp", "art/web-right-light.webp", 38, 18),
			},
		}),
		}
	end,
}


-- 3b. Live ref-based layout probes (zero visual footprint, tracked every frame by layout.sample)
zeron.place {
	at = "#rail",
	after = function(): Node
		return layout.probe("rail")
	end,
}

zeron.place {
	at = "#chat-session",
	after = function(): Node
		return layout.probe("chat_session")
	end,
}

zeron.place {
	at = "#chat-home",
	after = function(): Node
		return layout.probe("chat_home")
	end,
}

zeron.place {
	at = "#session-header",
	after = function(): Node
		return layout.probe("session_header")
	end,
}

zeron.place {
	at = "#files-pane",
	after = function(): Node
		return layout.probe("files_pane")
	end,
}

zeron.place {
	at = "#panel",
	after = function(): Node
		return layout.probe("panel")
	end,
}

-- 5. Message hover action: Save any message directly into Spider-Web SQLite snippets
zeron.place {
	at = ".message-actions",
	after = function(): Node
		local msg = zeron.context("message")
		local sess = zeron.context("session")
		if not msg or type(msg.text) ~= "string" or msg.text == "" then
			return ui.div {}
		end
		local text_val = msg.text
		local title_hint = if sess and type(sess.title) == "string" and sess.title ~= "" then sess.title else "Chat"
		return ui.show(function(): boolean
			return show_quick_save:get() == true
		end, ui.button {
			items = "center",
			gap = "$space.1",
			px = "$space.1",
			h = 22,
			rounded = "$radius.sm",
			cursor = "pointer",
			bg = "#00000000",
			color = "$text.tertiary",
			hover = { bg = "$hover", color = "$accent" },
			active = { bg = "$pressed", color = "$accent" },
			label = zeron.t("msg.save"),
			on_click = function()
				local first_line = string.match(text_val, "^%s*([^\r\n]+)") or title_hint
				local snippet_title = string.sub(first_line, 1, 42)
				db.add("snippet", snippet_title, text_val, title_hint, function()
					zeron.toast(zeron.s("msg.saved"))
				end)
			end,
			Icon { name = "star", size = 12 },
			ui.text {
				zeron.t("msg.save"),
				text_size = "$font.size.xs",
			},
		})
	end,
}
