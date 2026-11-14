--!strict
local Button = require("@ds/button")
local Glass = require("@ds/glass")
local Icon = require("@ds/icon")
local IconButton = require("@ds/icon_button")
local ink = require("@ds/visual_ink")
local material = require("@ds/material")
local motion = require("@ds/motion")

local db = require("./db")
local layout = require("./layout")
local radar = require("./radar")

local M = {}
local zeron_ref: any = nil

local function is_light_theme(): boolean
	if ui.theme and ui.theme.current then
		ui.theme.current:get()
	end
	if zeron_ref and type(zeron_ref.read) == "function" then
		local ok, app = pcall(function()
			return zeron_ref.read("appearance")
		end)
		if ok and app == "light" then
			return true
		elseif ok and app == "dark" then
			return false
		end
	end
	if ui.theme and type(ui.theme.get) == "function" then
		local ok, bg = pcall(function()
			return ui.theme.get("background")
		end)
		if ok and type(bg) == "string" and string.sub(bg, 1, 1) == "#" and #bg >= 7 then
			local r = (tonumber(string.sub(bg, 2, 3), 16) or 0) / 255
			local g = (tonumber(string.sub(bg, 4, 5), 16) or 0) / 255
			local b = (tonumber(string.sub(bg, 6, 7), 16) or 0) / 255
			return (0.299 * r + 0.587 * g + 0.114 * b) > 0.52
		end
	end
	return false
end

type SpunWeb = {
	id: number,
	x: number,
	by: number,
	radius: number,
	born: number,
	life: number,
}

type SessionBrief = {
	id: string,
	title: string,
	kind: string, -- "completed" | "attention" | "working" | "current" | "patrol"
}

type SpiderPose = {
	x: number,
	by: number,
	hd: number,
	wp: number,
	look: number,
	hop: number,
	st: number,
	sang: number,
}

type SpiderSlot = {
	idx: number,
	active: State<boolean>,
	phase: State<string>, -- "walk" | "peek" | "weave" | "rappel" | "completed" | "swing"
	pose: State<SpiderPose>,
	whisper: State<string?>,
	sid: string?,
	title: string,
	kind: string,
	tx: number,
	tby: number,
	anchor_by: number,
	swing_ax: number,
	swing_aby: number,
	swing_sx0: number,
	swing_by0: number,
	whisper_until: number,
	mode_until: number,
	weave_angle: number,
	rappel_dir: number,
}

local TICK_MS = 20
local ACTOR_BOX = 72
local MAX_SPIDERS = 5
local MAX_WEBS = 3
local SWING_SHOOT_S = 0.26
local SWING_TOTAL_S = 1.42

local WHISPERS_IDLE = {
	"pet.whisper_1",
	"pet.whisper_2",
	"pet.whisper_3",
	"pet.whisper_4",
}

-- Module-local PRNG state (avoids mutating global Lua math.randomseed)
local rng_state = 2463534242

local function rand_seed(seed: number)
	local v = math.floor(seed) % 2147483647
	if v <= 0 then
		v = 135792468
	end
	rng_state = v
end

local function rand_float(): number
	rng_state = (rng_state * 48271) % 2147483647
	return (rng_state - 1) / 2147483646
end

local function rand_int(lo: number, hi: number): number
	local a = math.floor(lo)
	local b = math.floor(hi)
	if b <= a then
		return a
	end
	return a + math.floor(rand_float() * (b - a + 1))
end

local function clamp(v: number, lo: number, hi: number): number
	if hi < lo then
		return lo
	end
	return math.max(lo, math.min(hi, v))
end

local function norm_angle(a: number): number
	while a > math.pi do
		a -= math.pi * 2
	end
	while a < -math.pi do
		a += math.pi * 2
	end
	return a
end

local function short_title(title: string, max_chars: number?): string
	local limit = max_chars or 14
	local n = utf8.len(title)
	if n and n > limit then
		local off = utf8.offset(title, limit + 1)
		if off then
			return string.sub(title, 1, off - 1) .. "…"
		end
	end
	return title
end

local function clone_pose(p: SpiderPose): SpiderPose
	return {
		x = p.x,
		by = p.by,
		hd = p.hd,
		wp = p.wp,
		look = p.look,
		hop = p.hop,
		st = p.st,
		sang = p.sang,
	}
end

-- Procedural articulated Spider-Man jumping spider OR cartoon Spider-Man swinging hero
local function SpiderActorCanvas(props: { slot: SpiderSlot }): Node
	local slot = props.slot
	return ui.canvas {
		w = ACTOR_BOX,
		h = ACTOR_BOX,
		draw = function(c: any, w: number, h: number)
			ui.theme.current:get()
			local ph = slot.phase:get()
			local p = slot.pose:get()
			local cx, cy = w / 2, h / 2 - p.hop
			local hd = p.hd
			local walk_p = p.wp
			local look = p.look
			local kind = slot.kind
			local sense = kind == "attention" or kind == "completed"

			local accent = ink.canvas("accent")
			local accent_soft = ink.canvas({ token = "accent", alpha = 0.30 })
			local warn_c = ink.canvas("warning")
			local ok_c = ink.canvas("success")
			local body_dark = ink.canvas({ token = "text.primary", alpha = 0.92 })
			local leg_col = ink.canvas({ token = "text.primary", alpha = 0.85 })
			local leg_hi = ink.canvas({ token = "accent", alpha = 0.90 })
			local light = is_light_theme()
			local shadow_c = if light then "#00000024" else ink.canvas({ token = "background", alpha = 0.42 })
			local eye_c = "#ffffff"
			local eye_rim = if light then "#090d16" else ink.canvas("background")

			-- === CARTOON SPIDER-MAN HERO (when swinging out after entering completed session) ===
			if ph == "swing" then
				local st = p.st
				local tilt = clamp((p.sang + math.pi / 2) * 0.55, -0.65, 0.65)
				local cos_t = math.cos(tilt)
				local sin_t = math.sin(tilt)
				local function rp(lx: number, ly: number): (number, number)
					return cx + lx * cos_t - ly * sin_t, cy + lx * sin_t + ly * cos_t
				end

				local suit_red = "#ef3340"
				local suit_blue = "#1d4ed8"
				local ink_line = "#090d16"
				local silk_c = if light then "#334155" else "#f8fafc"

				if st >= SWING_SHOOT_S then
					local streak_alpha = clamp((st - SWING_SHOOT_S) / 0.4, 0.25, 0.85)
					local streak_c = ink.canvas({ token = "accent", alpha = streak_alpha * 0.55 })
					local streak_w = ink.canvas({ token = "text.primary", alpha = streak_alpha * 0.45 })
					local s1x, s1y = rp(-9, 14)
					local s1e_x, s1e_y = rp(-13, 30)
					local s2x, s2y = rp(8, 16)
					local s2e_x, s2e_y = rp(11, 31)
					c:line(s1x, s1y, s1e_x, s1e_y, streak_c, 2.0)
					c:line(s2x, s2y, s2e_x, s2e_y, streak_w, 1.5)
				end

				local hrx, hry = rp(-3, 7)
				local krx, kry = rp(-11, 14)
				local frx, fry = rp(-16, 22)
				c:line(hrx, hry, krx, kry, ink_line, 6.2)
				c:line(hrx, hry, krx, kry, suit_blue, 4.2)
				c:line(krx, kry, frx, fry, ink_line, 5.4)
				c:line(krx, kry, frx, fry, suit_red, 3.6)

				local hlx, hly = rp(3, 7)
				local klx, kly = rp(12, 9)
				local flx, fly = rp(8, 20)
				c:line(hlx, hly, klx, kly, ink_line, 6.2)
				c:line(hlx, hly, klx, kly, suit_blue, 4.2)
				c:line(klx, kly, flx, fly, ink_line, 5.4)
				c:line(klx, kly, flx, fly, suit_red, 3.6)

				local sax, say = rp(-6, -2)
				local eax, eay = rp(-15, 4)
				local hax, hay = rp(-20, 10)
				c:line(sax, say, eax, eay, ink_line, 5.2)
				c:line(sax, say, eax, eay, suit_blue, 3.4)
				c:line(eax, eay, hax, hay, ink_line, 4.8)
				c:line(eax, eay, hax, hay, suit_red, 3.0)
				c:circle(hax, hay, 2.4, suit_red)

				local ax = slot.swing_ax - p.x
				local ay = -(slot.swing_aby - p.by)
				local shoot_ang = math.atan2(ay, ax)
				local sh_sx, sh_sy = rp(5, -3)
				local elbow_x = sh_sx + math.cos(shoot_ang) * 9
				local elbow_y = sh_sy + math.sin(shoot_ang) * 9
				local wrist_x = sh_sx + math.cos(shoot_ang) * 18
				local wrist_y = sh_sy + math.sin(shoot_ang) * 18
				c:line(sh_sx, sh_sy, elbow_x, elbow_y, ink_line, 5.2)
				c:line(sh_sx, sh_sy, elbow_x, elbow_y, suit_blue, 3.4)
				c:line(elbow_x, elbow_y, wrist_x, wrist_y, ink_line, 5.0)
				c:line(elbow_x, elbow_y, wrist_x, wrist_y, suit_red, 3.2)
				c:circle(wrist_x, wrist_y, 2.5, suit_red)
				c:circle(wrist_x, wrist_y, 1.3, silk_c)

				local tx0, ty0 = rp(0, 1)
				c:circle(tx0, ty0, 7.6, ink_line)
				c:circle(tx0, ty0, 6.2, suit_blue)
				local chest_top_x, chest_top_y = rp(0, -6)
				local chest_l_x, chest_l_y = rp(-5.2, 1)
				local chest_r_x, chest_r_y = rp(5.2, 1)
				local chest_bot_x, chest_bot_y = rp(0, 6.5)
				local chest_path = ui.path()
					:move(chest_top_x, chest_top_y)
					:line(chest_r_x, chest_r_y)
					:line(chest_bot_x, chest_bot_y)
					:line(chest_l_x, chest_l_y)
					:close()
				c:fill(chest_path, suit_red)
				local emb_x, emb_y = rp(0, -0.5)
				c:circle(emb_x, emb_y, 1.8, ink_line)

				local hx, hy = rp(1, -12)
				c:circle(hx, hy, 10.2, ink_line)
				c:circle(hx, hy, 8.8, suit_red)
				local wm_t_x, wm_t_y = rp(1, -20.5)
				local wm_b_x, wm_b_y = rp(1, -3.5)
				local wm_l_x, wm_l_y = rp(-7.5, -12)
				local wm_r_x, wm_r_y = rp(9.5, -12)
				c:line(wm_t_x, wm_t_y, wm_b_x, wm_b_y, ink_line, 0.75)
				c:line(wm_l_x, wm_l_y, wm_r_x, wm_r_y, ink_line, 0.75)

				local le_a_x, le_a_y = rp(-5.8, -14.8)
				local le_q1_x, le_q1_y = rp(-1.8, -14.2)
				local le_b_x, le_b_y = rp(-0.6, -11.5)
				local le_q2_x, le_q2_y = rp(-3.5, -9.2)
				local le_c_x, le_c_y = rp(-4.2, -9.2)
				local leye = ui.path()
					:move(le_a_x, le_a_y)
					:quad(le_q1_x, le_q1_y, le_b_x, le_b_y)
					:quad(le_q2_x, le_q2_y, le_c_x, le_c_y)
					:close()
				c:stroke(leye, ink_line, 2.1, { join = "round" })
				c:fill(leye, eye_c)

				local re_a_x, re_a_y = rp(7.8, -14.8)
				local re_q1_x, re_q1_y = rp(3.8, -14.2)
				local re_b_x, re_b_y = rp(2.6, -11.5)
				local re_q2_x, re_q2_y = rp(5.5, -9.2)
				local re_c_x, re_c_y = rp(6.2, -9.2)
				local reye = ui.path()
					:move(re_a_x, re_a_y)
					:quad(re_q1_x, re_q1_y, re_b_x, re_b_y)
					:quad(re_q2_x, re_q2_y, re_c_x, re_c_y)
					:close()
				c:stroke(reye, ink_line, 2.1, { join = "round" })
				c:fill(reye, eye_c)
				return
			end

			-- === REGULAR CRAWLING / COMPLETED SPIDER ===
			local cos_h = math.cos(hd)
			local sin_h = math.sin(hd)
			local function rot(lx: number, ly: number): (number, number)
				return cx + lx * cos_h - ly * sin_h, cy + lx * sin_h + ly * cos_h
			end

			local sx, sy = rot(-1, 2)
			c:circle(sx, sy + 2, 10, shadow_c)

			if ph == "completed" then
				local pulse = 0.5 + 0.5 * math.sin(walk_p * 1.1)
				c:stroke(ui.path():arc(cx, cy, 16 + pulse * 2.5, 0, 360), ok_c, 1.5)
			elseif sense then
				local pulse = 0.5 + 0.5 * math.sin(walk_p * 1.4)
				c:stroke(ui.path():arc(cx, cy, 15 + pulse * 3.0, 0, 360), warn_c, 1.4)
			elseif kind == "working" then
				local pulse = 0.5 + 0.5 * math.sin(walk_p * 0.9)
				c:stroke(ui.path():arc(cx, cy, 15 + pulse * 2.0, 0, 360), accent_soft, 1.15)
			end

			local tuck = if ph == "rappel" then 0.72 elseif ph == "peek" or ph == "completed" then 0.92 else 1.0
			local legs = {
				{ side = -1, ax = 4, ay = -3, base_a = -0.68, len1 = 7.5, len2 = 8.5, p = 0 },
				{ side = -1, ax = 2, ay = -3.5, base_a = -1.28, len1 = 8.0, len2 = 9.0, p = math.pi },
				{ side = -1, ax = 0, ay = -3.5, base_a = -1.88, len1 = 8.0, len2 = 9.0, p = 0 },
				{ side = -1, ax = -2, ay = -3, base_a = -2.42, len1 = 8.5, len2 = 9.5, p = math.pi },
				{ side = 1, ax = 4, ay = 3, base_a = 0.68, len1 = 7.5, len2 = 8.5, p = math.pi },
				{ side = 1, ax = 2, ay = 3.5, base_a = 1.28, len1 = 8.0, len2 = 9.0, p = 0 },
				{ side = 1, ax = 0, ay = 3.5, base_a = 1.88, len1 = 8.0, len2 = 9.0, p = math.pi },
				{ side = 1, ax = -2, ay = 3, base_a = 2.42, len1 = 8.5, len2 = 9.5, p = 0 },
			}
			for idx, lg in legs do
				local stride = if ph == "walk" or ph == "weave"
					then math.sin(walk_p + lg.p) * 0.28
					elseif ph == "rappel" then math.sin(walk_p * 0.5 + idx) * 0.08
					else math.sin(walk_p * 0.35 + idx * 0.7) * 0.04
				local a1 = lg.base_a + stride
				local bend = lg.side * 0.42 * tuck
				local kx = lg.ax + math.cos(a1) * lg.len1 * tuck
				local ky = lg.ay + math.sin(a1) * lg.len1 * tuck
				local tx = kx + math.cos(a1 + bend) * lg.len2 * tuck
				local ty = ky + math.sin(a1 + bend) * lg.len2 * tuck

				local x0, y0 = rot(lg.ax, lg.ay)
				local x1, y1 = rot(kx, ky)
				local x2, y2 = rot(tx, ty)
				local lc = if idx == 1 or idx == 5 then leg_hi else leg_col
				c:line(x0, y0, x1, y1, lc, 1.8)
				c:line(x1, y1, x2, y2, lc, 1.45)
			end

			local abx, aby = rot(-5.5, 0)
			local body_mark = if ph == "completed" then ok_c else accent
			c:circle(abx, aby, 5.8, body_mark)
			c:circle(abx, aby, 3.6, body_dark)
			c:circle(abx, aby, 1.7, body_mark)

			local hdx, hdy = rot(3.2, 0)
			c:circle(hdx, hdy, 4.4, body_dark)
			c:stroke(ui.path():arc(hdx, hdy, 4.4, 0, 360), body_mark, 1.0)

			local ex1, ey1 = rot(5.4, -1.7 + look * 0.9)
			local ex2, ey2 = rot(5.4, 1.7 + look * 0.9)
			c:circle(ex1, ey1, 1.55, eye_rim)
			c:circle(ex2, ey2, 1.55, eye_rim)
			c:circle(ex1, ey1, 1.15, eye_c)
			c:circle(ex2, ey2, 1.15, eye_c)
		end,
	}
end

-- Fixed-size radial spun web canvas (96x96)
local WEB_CANVAS_SZ = 96
local function SpunWebCanvas(props: { web: () -> SpunWeb?, now_fn: () -> number }): Node
	return ui.canvas {
		w = WEB_CANVAS_SZ,
		h = WEB_CANVAS_SZ,
		draw = function(c: any, w: number, h: number)
			ui.theme.current:get()
			local wb = props.web()
			if not wb then
				return
			end
			local age = props.now_fn() - wb.born
			local remain = math.max(0, wb.life - age)
			local fade = if age < 0.9
				then age / 0.9
				elseif remain < 4.0 then remain / 4.0
				else 1.0
			local light = is_light_theme()
			local alpha_line = (if light then 0.28 else 0.42) * fade
			local alpha_ring = (if light then 0.22 else 0.36) * fade
			if alpha_line <= 0.01 then
				return
			end

			local cx, cy = w / 2, h / 2
			local R = wb.radius
			local spokes = 8
			local step = (math.pi * 2) / spokes
			local silk = ink.canvas({ token = "text.primary", alpha = alpha_line })
			local silk_ring = ink.canvas({ token = "text.primary", alpha = alpha_ring })
			local hub = ink.canvas({ token = "accent", alpha = (if light then 0.62 else 0.55) * fade })

			for i = 0, spokes - 1 do
				local a = i * step + 0.2
				c:line(cx, cy, cx + R * math.cos(a), cy + R * math.sin(a), silk, 1.1)
			end
			for _, rf in { 0.34, 0.62, 0.9 } do
				local r = R * rf
				local p = ui.path():move(cx + r * math.cos(0.2), cy + r * math.sin(0.2))
				for i = 0, spokes - 1 do
					local a2 = (i + 1) * step + 0.2
					local amid = (i + 0.5) * step + 0.2
					local rc = r * 0.85
					p = p:quad(cx + rc * math.cos(amid), cy + rc * math.sin(amid), cx + r * math.cos(a2), cy + r * math.sin(a2))
				end
				p = p:close()
				c:stroke(p, silk_ring, 1.05, { join = "round" })
			end
			c:circle(cx, cy, 2.2, hub)
		end,
	}
end

function M.register(zeron: any, show_pet: any, on_mount_cb: (() -> ())?, on_cleanup_cb: (() -> ())?)
	zeron_ref = zeron
	rand_seed(ui.now() % 2147483646 + 1)

	zeron.place {
		at = "#titlebar",
		after = function(): Node
			if on_mount_cb then
				pcall(on_mount_cb)
			end
			if on_cleanup_cb then
				pcall(ui.on_cleanup, on_cleanup_cb)
			end
			local win_w = layout.win_w
			local stage_y = layout.stage_y

			local function max_by(reactive: boolean?): number
				return layout.max_by(reactive)
			end

			local function compute_zones(W: number, H_up: number, reactive: boolean?): { sidebar_r: number, panel_l: number, right_l: number, text_x1: number, text_x2: number }
				local sr_raw = tonumber(if reactive then layout.sidebar_r:get() else layout.sidebar_r:peek()) or 0
				local pl_raw = tonumber(if reactive then layout.panel_l:get() else layout.panel_l:peek()) or 0
				local cx_raw = tonumber(if reactive then layout.prose_cx:get() else layout.prose_cx:peek()) or 0
				local pw_raw = tonumber(if reactive then layout.prose_w:get() else layout.prose_w:peek()) or 0

				local sr = clamp(sr_raw, 0, W * 0.42)
				local panel_l = if pl_raw > (sr + 160) and pl_raw < (W - 40) then pl_raw else 0
				local right_l = if panel_l > 0 then panel_l else W

				local theme_pw = 720
				if ui.theme and type((ui.theme :: any).get) == "function" then
					local ok_pw, raw_pw = pcall(function() return (ui.theme :: any).get("zeron.prose.measure") end)
					if ok_pw and tonumber(raw_pw) then
						theme_pw = tonumber(raw_pw) :: number
					end
				end
				local max_pane_w = math.max(120, right_l - sr - 16)
				local pw = math.min(math.max(pw_raw, theme_pw), max_pane_w)

				local geo_cx = (sr + right_l) * 0.5
				local pcx = if cx_raw > (sr + 60) and cx_raw < (right_l - 60) and math.abs(cx_raw - geo_cx) <= 44
					then cx_raw
					else geo_cx

				local text_x1 = clamp(pcx - pw * 0.5 - 22, sr + 6, right_l - 80)
				local text_x2 = clamp(pcx + pw * 0.5 + 22, text_x1 + 80, right_l - 6)
				return { sidebar_r = sr, panel_l = panel_l, right_l = right_l, text_x1 = text_x1, text_x2 = text_x2 }
			end

			local function is_in_text_zone(x: number, by: number, W: number, H_up: number, reactive: boolean?): boolean
				local z = compute_zones(W, H_up, reactive)
				local over_sidebar = z.sidebar_r > 70 and x < (z.sidebar_r + 14) and by > 20 and by < (H_up - 8)
				local over_rail = z.sidebar_r > 20 and z.sidebar_r <= 70 and x < (z.sidebar_r + 10) and by > 20 and by < (H_up - 8)
				local over_prose = x >= z.text_x1 and x <= z.text_x2 and by > 28 and by < (H_up - 16)
				local over_right_panel = z.panel_l > 0 and x >= (z.panel_l - 14) and by > 20 and by < (H_up - 8)
				return over_sidebar or over_rail or over_prose or over_right_panel
			end

			local function pick_target(prefer_edge: boolean?): (number, number)
				local W = math.max(360, win_w:peek())
				local H_up = max_by(false)
				local z = compute_zones(W, H_up, false)
				local left_gap = z.text_x1 - z.sidebar_r
				local right_gap = z.right_l - z.text_x2

				local choices: { number } = {}
				if left_gap >= 68 then
					table.insert(choices, 1)
					table.insert(choices, 1)
				end
				if right_gap >= 68 then
					table.insert(choices, 2)
					table.insert(choices, 2)
					table.insert(choices, 2)
				end
				table.insert(choices, 3)
				table.insert(choices, 4)
				table.insert(choices, 5)
				if left_gap >= 64 or right_gap >= 64 then
					table.insert(choices, 6)
				end

				if prefer_edge or rand_float() < 0.96 then
					local spot = choices[rand_int(1, #choices)]
					if spot == 1 then
						local x1 = math.floor(z.sidebar_r + 22)
						local x2 = math.max(x1 + 8, math.floor(z.text_x1 - 24))
						return rand_int(x1, x2), rand_int(68, math.max(120, H_up - 32))
					elseif spot == 2 then
						local x1 = math.floor(z.text_x2 + 24)
						local x2 = math.max(x1 + 8, math.floor(z.right_l - 36))
						return rand_int(x1, x2), rand_int(68, math.max(120, H_up - 32))
					elseif spot == 3 then
						return clamp(math.floor(z.sidebar_r) + rand_int(12, 24), 40, z.right_l - 46), rand_int(64, math.max(120, H_up - 20))
					elseif spot == 4 then
						return rand_int(44, math.max(120, math.floor(W - 56))), H_up - rand_int(4, 22)
					elseif spot == 5 then
						local edge_x = if z.panel_l > 0 then math.floor(z.right_l - 24) else math.floor(W - 38)
						return clamp(edge_x + rand_int(-8, 8), 44, W - 28), rand_int(64, math.max(120, H_up - 24))
					else
						if right_gap >= 64 and (left_gap < 64 or rand_float() < 0.6) then
							local x1 = math.floor(z.text_x2 + 24)
							return rand_int(x1, math.max(x1 + 8, math.floor(z.right_l - 36))), rand_int(46, 72)
						else
							local x1 = math.floor(z.sidebar_r + 22)
							return rand_int(x1, math.max(x1 + 8, math.floor(z.text_x1 - 22))), rand_int(46, 72)
						end
					end
				end
				return rand_int(70, math.max(120, W - 70)), rand_int(H_up - 36, H_up - 8)
			end

			local slots: { SpiderSlot } = {}
			for i = 1, MAX_SPIDERS do
				local start_x, start_by = pick_target(true)
				local tx0, ty0 = pick_target(true)
				table.insert(slots, {
					idx = i,
					active = ui.use_state(false),
					phase = ui.use_state("walk"),
					pose = ui.use_state({
						x = start_x,
						by = start_by,
						hd = -0.2 + i * 0.7,
						wp = i * 1.1,
						look = 0.0,
						hop = 0.0,
						st = 0.0,
						sang = -math.pi / 2,
					}),
					whisper = ui.use_state(nil :: string?),
					sid = nil,
					title = "",
					kind = "patrol",
					tx = tx0,
					tby = ty0,
					anchor_by = start_by,
					swing_ax = start_x + 120,
					swing_aby = 680,
					swing_sx0 = start_x,
					swing_by0 = start_by,
					whisper_until = 0,
					mode_until = 0,
					weave_angle = 0,
					rappel_dir = 1,
				})
			end

			local menu_slot_idx = ui.use_state(0)
			local hovered_slot = ui.use_state(0)
			local hovered_whisper = ui.use_state(0)
			local meta_rev = ui.use_state(0)
			local stage_snapshot = ui.use_state({ w = 1280, h_up = 540, webs = {}, pets = {} } :: any)
			local last_stage_pub = 0.0
			local stage_had_content = false
			local clock_now = ui.use_state(ui.now() / 1000)

			local web_slots: { State<SpunWeb?> } = {}
			for _ = 1, MAX_WEBS do
				table.insert(web_slots, ui.use_state(nil :: SpunWeb?))
			end
			local next_web_slot = 1
			local web_seq = 0
			local has_webs = false
			local last_web_clock = 0.0

			local quota_label = zeron.s("pet.quota_none")
			local active_chat_id: string? = nil
			local prev_route_sid: string? = nil
			local working_count = 0

			local seen_working: { [string]: boolean } = {}
			local completed_pending: { [string]: { title: string } } = {}
			local swung_done: { [string]: boolean } = {}
			local sync_rev = ui.use_state(0)

			local route_live = zeron.live("route")

			local function is_pet_on(): boolean
				return show_pet:get() == true
			end

			local function say_slot(slot: SpiderSlot, text: string, secs: number?)
				slot.whisper:set(text)
				slot.whisper_until = ui.now() / 1000 + (secs or 4.5)
			end

			local function spawn_web(x: number, by: number)
				web_seq += 1
				web_slots[next_web_slot]:set({
					id = web_seq,
					x = x,
					by = by,
					radius = rand_int(28, 38),
					born = ui.now() / 1000,
					life = 22,
				})
				next_web_slot = (next_web_slot % MAX_WEBS) + 1
				has_webs = true
			end

			local function start_rappel(slot: SpiderSlot)
				local now_s = ui.now() / 1000
				local p = slot.pose:peek()
				slot.anchor_by = p.by
				slot.rappel_dir = 1
				slot.phase:set("rappel")
				local np = clone_pose(p)
				np.hd = math.pi / 2
				slot.pose:set(np)
				slot.mode_until = now_s + 5.0
			end

			local function start_weave(slot: SpiderSlot)
				local now_s = ui.now() / 1000
				local p = slot.pose:peek()
				local r = 10
				local start_ang = p.hd - math.pi / 2
				slot.tx = p.x - math.cos(start_ang) * r
				slot.tby = p.by + math.sin(start_ang) * r
				slot.phase:set("weave")
				slot.weave_angle = start_ang
				slot.mode_until = now_s + 2.2
				spawn_web(p.x, p.by)
				say_slot(slot, zeron.s("pet.spun_web"), 3.2)
			end

			local function launch_swing(slot: SpiderSlot)
				if slot.phase:peek() == "swing" then
					return
				end
				local sid = slot.sid
				if sid then
					completed_pending[sid] = nil
					swung_done[sid] = true
				end
				if menu_slot_idx:peek() == slot.idx then
					menu_slot_idx:set(0)
				end
				if motion.reduced() then
					slot.whisper:set(nil)
					slot.active:set(false)
					slot.sid = nil
					slot.phase:set("idle")
					sync_rev:set(sync_rev:peek() + 1)
					return
				end

				local W = math.max(360, win_w:peek())
				local H_up = max_by()
				local p = slot.pose:peek()
				local sx0, by0 = p.x, p.by

				local offset_x = rand_int(90, 260) * (if rand_float() < 0.5 then -1 else 1)
				local ax = clamp(sx0 + offset_x, 56, W - 56)
				if math.abs(ax - sx0) < 60 then
					ax = clamp(sx0 + (if sx0 < W * 0.5 then 140 else -140), 56, W - 56)
				end
				local aby = H_up + 170

				slot.swing_sx0 = sx0
				slot.swing_by0 = by0
				slot.swing_ax = ax
				slot.swing_aby = aby
				local np = clone_pose(p)
				np.st = 0
				np.hop = 6
				np.sang = math.atan2(-(aby - by0), ax - sx0)
				slot.pose:set(np)
				slot.whisper:set(nil)
				slot.phase:set("swing")
				say_slot(slot, zeron.s("pet.swing_say"), 1.3)
			end

			local function freeze_completed(slot: SpiderSlot)
				slot.phase:set("completed")
				local np = clone_pose(slot.pose:peek())
				np.hd = -math.pi / 2
				np.look = 0
				np.hop = 10
				slot.pose:set(np)
				slot.whisper:set(nil)
				if menu_slot_idx:peek() == slot.idx then
					menu_slot_idx:set(0)
				end
			end

			-- Wire Zeron turn events for immediate completion freeze + new-turn wakeup
			ui.effect(function()
				local stops: { () -> () } = {}
				pcall(function()
					table.insert(stops, zeron.on("turn.started", function(e: any)
						local cid = e and e.chat
						if type(cid) == "string" and cid ~= "" then
							seen_working[cid] = true
							completed_pending[cid] = nil
							swung_done[cid] = nil
							sync_rev:set(sync_rev:peek() + 1)
						end
					end))
					table.insert(stops, zeron.on("turn.finished", function(e: any)
						local cid = e and e.chat
						if type(cid) == "string" and cid ~= "" then
							seen_working[cid] = nil
							swung_done[cid] = nil
							local all = zeron.sessions() or {}
							local rec = all[cid]
							local stitle = if rec and type(rec.title) == "string" and rec.title ~= "" then rec.title else cid
							completed_pending[cid] = { title = stitle }
							sync_rev:set(sync_rev:peek() + 1)
						end
					end))
					table.insert(stops, zeron.on("turn.errored", function(e: any)
						local cid = e and e.chat
						if type(cid) == "string" and cid ~= "" then
							seen_working[cid] = nil
							swung_done[cid] = nil
							local all = zeron.sessions() or {}
							local rec = all[cid]
							local stitle = if rec and type(rec.title) == "string" and rec.title ~= "" then rec.title else cid
							completed_pending[cid] = { title = stitle }
							sync_rev:set(sync_rev:peek() + 1)
						end
					end))
				end)
				return function()
					for _, stop in stops do
						pcall(stop)
					end
				end
			end)

			-- Reactive session -> spider slot reconciliation
			ui.effect(function()
				local _rev = sync_rev:get()
				if show_pet:get() ~= true then
					menu_slot_idx:set(0)
					for _, sl in slots do
						sl.active:set(false)
					end
					return
				end

				local sum = radar.summary()
				local r = route_live()
				local all_sessions = zeron.sessions() or {}

				local cur_route_sid = if type(r) == "table" and r.session then tostring(r.session) else nil
				local route_changed = cur_route_sid ~= prev_route_sid
				prev_route_sid = cur_route_sid
				active_chat_id = cur_route_sid
				working_count = #sum.working

				if sum.min_quota ~= nil then
					quota_label = zeron.s("pet.quota_ok", { pct = math.floor(sum.min_quota + 0.5) })
				else
					quota_label = zeron.s("pet.quota_none")
				end

				for sid, rec in all_sessions do
					local st = tostring(rec.status or "")
					if st == "working" or st == "connecting" or st == "waiting" then
						seen_working[sid] = true
						completed_pending[sid] = nil
						swung_done[sid] = nil
					elseif seen_working[sid] then
						seen_working[sid] = nil
						local stitle = if type(rec.title) == "string" and rec.title ~= "" then rec.title else sid
						completed_pending[sid] = { title = stitle }
					end
				end

				-- Only auto-swing when the user newly navigates INTO a completed_pending session
				if route_changed and cur_route_sid and completed_pending[cur_route_sid] then
					for _, sl in slots do
						if sl.active:peek() and sl.sid == cur_route_sid and sl.phase:peek() == "completed" then
							launch_swing(sl)
							return
						end
					end
				end

				local desired: { SessionBrief } = {}
				local seen_id: { [string]: boolean } = {}
				local function add_desired(id: string, title: string, kind: string)
					if #desired >= MAX_SPIDERS or seen_id[id] then
						return
					end
					seen_id[id] = true
					table.insert(desired, { id = id, title = title, kind = kind })
				end

				for _, sl in slots do
					if sl.active:peek() and sl.phase:peek() == "swing" then
						local s_id = sl.sid or (`__swing_{sl.idx}`)
						add_desired(s_id, sl.title, "completed")
					end
				end

				for cid, info in completed_pending do
					if not swung_done[cid] then
						add_desired(cid, info.title, "completed")
					end
				end

				for _, item in sum.attention do
					add_desired(item.id, item.title, "attention")
				end

				for _, item in sum.working do
					add_desired(item.id, item.title, "working")
				end

				local assigned_slot: { [string]: SpiderSlot } = {}
				local used_slots: { [number]: boolean } = {}

				for _, d in desired do
					for _, sl in slots do
						if not used_slots[sl.idx] and sl.active:peek() and sl.sid == d.id then
							assigned_slot[d.id] = sl
							used_slots[sl.idx] = true
							break
						end
					end
				end

				for _, d in desired do
					if not assigned_slot[d.id] then
						local chosen: SpiderSlot? = nil
						for _, sl in slots do
							if not used_slots[sl.idx] and not sl.active:peek() then
								chosen = sl
								break
							end
						end
						if not chosen then
							for _, sl in slots do
								if not used_slots[sl.idx] and sl.phase:peek() ~= "swing" then
									chosen = sl
									break
								end
							end
						end
						if chosen then
							assigned_slot[d.id] = chosen
							used_slots[chosen.idx] = true
							local nx, nby = pick_target(false)
							local sx0, by0 = pick_target(false)
							chosen.sid = d.id
							local np = clone_pose(chosen.pose:peek())
							np.x = sx0
							np.by = by0
							np.hop = 8
							chosen.pose:set(np)
							chosen.tx = nx
							chosen.tby = nby
							chosen.phase:set("walk")
							chosen.active:set(true)
						end
					end
				end

				for _, sl in slots do
					if not used_slots[sl.idx] and sl.phase:peek() ~= "swing" then
						if sl.active:peek() then
							sl.active:set(false)
							sl.whisper:set(nil)
							if menu_slot_idx:peek() == sl.idx then
								menu_slot_idx:set(0)
							end
						end
					end
				end

				for _, d in desired do
					local sl = assigned_slot[d.id]
					if sl then
						local prev_phase = sl.phase:peek()
						sl.title = d.title
						sl.kind = d.kind
						if d.kind == "completed" and prev_phase ~= "completed" and prev_phase ~= "swing" then
							freeze_completed(sl)
						elseif d.kind ~= "completed" and prev_phase == "completed" then
							sl.phase:set("walk")
							local nx, nby = pick_target(false)
							sl.tx = nx
							sl.tby = nby
						end
					end
				end

				meta_rev:set(meta_rev:peek() + 1)
			end)

			-- Pure animation timer (stopped automatically when hidden/disabled or reduced-motion is enabled)
			ui.effect(function()
				if show_pet:get() ~= true or motion.reduced() then
					for _, sl in slots do
						if sl.active:peek() and sl.phase:peek() == "swing" then
							sl.active:set(false)
							sl.sid = nil
							sl.phase:set("idle")
						end
					end
					if stage_had_content then
						stage_had_content = false
						local w0 = math.max(360, tonumber(win_w:peek()) or 1280)
						local h0 = max_by(false)
						stage_snapshot:set({
							w = w0,
							h_up = h0,
							zones = compute_zones(w0, h0, false),
							webs = {},
							pets = {},
						})
					end
					return
				end
				local last_tick_ms = ui.now()
				local last_layout_ms = 0
				local tick_seq = 0
				local cached_W = math.max(360, tonumber(win_w:peek()) or 1280)
				local cached_H_up = max_by(false)
				return ui.every(TICK_MS, function()
					local now_ms = ui.now()
					local dt = clamp((now_ms - last_tick_ms) / 1000, 0.004, 0.05)
					last_tick_ms = now_ms
					tick_seq += 1

					local win = zeron.window(true)
					if not win.shown or motion.reduced() then
						return
					end
					local any_active = false
					for _, sl in slots do
						if sl.active:peek() then
							any_active = true
							break
						end
					end
					if not any_active and not has_webs then
						if stage_had_content then
							stage_had_content = false
							stage_snapshot:set({
								w = cached_W,
								h_up = cached_H_up,
								zones = compute_zones(cached_W, cached_H_up, false),
								webs = {},
								pets = {},
							})
						end
						return
					end

					local now_s = now_ms / 1000
					local layout_shifted = false
					if (now_ms - last_layout_ms) >= 60 then
						last_layout_ms = now_ms
						cached_W, cached_H_up, layout_shifted = layout.sample()
					end
					local W, H_up = cached_W, cached_H_up

					if layout_shifted then
						for _, sl in slots do
							if sl.active:peek() then
								local ph_now = sl.phase:peek()
								if (ph_now == "walk" or ph_now == "peek") and is_in_text_zone(sl.tx, sl.tby, W, H_up, false) then
									local nx, nby = pick_target(true)
									sl.tx = nx
									sl.tby = nby
									sl.phase:set("walk")
								end
							end
						end
					end

					if has_webs then
						local any_alive = false
						for i = 1, MAX_WEBS do
							local wb = web_slots[i]:peek()
							if wb then
								if (now_s - wb.born) >= wb.life then
									web_slots[i]:set(nil)
								else
									any_alive = true
								end
							end
						end
						has_webs = any_alive
						if any_alive and (now_s - last_web_clock) >= 0.2 then
							last_web_clock = now_s
							clock_now:set(now_s)
						end
					end

					local open_idx = menu_slot_idx:peek()

					for _, sl in slots do
						if sl.active:peek() then
							if sl.whisper:peek() ~= nil and now_s > sl.whisper_until then
								sl.whisper:set(nil)
							end

							local p = clone_pose(sl.pose:peek())
							if p.hop > 0.1 then
								p.hop = p.hop * math.exp(-dt * 4.14)
							else
								p.hop = 0
							end

							local ph = sl.phase:peek()
							if ph == "swing" then
								p.st += dt
								if p.st >= SWING_TOTAL_S then
									sl.active:set(false)
									sl.phase:set("walk")
									sl.whisper:set(nil)
									sync_rev:set(sync_rev:peek() + 1)
								else
									if p.st >= SWING_SHOOT_S then
										local u = (p.st - SWING_SHOOT_S) / (SWING_TOTAL_S - SWING_SHOOT_S)
										local ease = u * u * (0.35 + 0.65 * u)
										local ax, aby = sl.swing_ax, sl.swing_aby
										local end_x = ax + (ax - sl.swing_sx0) * 0.42
										local end_by = aby + 180
										local curve = math.sin(u * math.pi) * 28 * (if ax >= sl.swing_sx0 then -1 else 1)
										p.x = sl.swing_sx0 + (end_x - sl.swing_sx0) * ease + curve
										p.by = sl.swing_by0 + (end_by - sl.swing_by0) * ease
										p.sang = math.atan2(-(end_by - sl.swing_by0), end_x - sl.swing_sx0)
									end
									sl.pose:set(p)
								end
							elseif ph == "completed" then
								if (tick_seq + sl.idx) % 4 == 0 then
									p.wp += dt * 14.0
									sl.pose:set(p)
								end
							elseif open_idx == sl.idx then
								if (tick_seq + sl.idx) % 4 == 0 then
									p.wp += dt * 12.0
									sl.pose:set(p)
								end
							elseif ph == "walk" then
								local dx = sl.tx - p.x
								local dby = sl.tby - p.by
								local dy_screen = -dby
								local dist = math.sqrt(dx * dx + dy_screen * dy_screen)
								if dist < 8 then
									local in_txt = is_in_text_zone(p.x, p.by, W, H_up, false)
									local roll = rand_float()
									if roll < 0.22 and not in_txt then
										sl.pose:set(p)
										start_weave(sl)
									elseif roll < 0.38 and p.by > 130 and not in_txt then
										sl.pose:set(p)
										start_rappel(sl)
									else
										sl.phase:set("peek")
										sl.mode_until = now_s + (1.8 + rand_float() * 2.4)
										if rand_float() < 0.18 and sl.whisper:peek() == nil then
											if sl.kind == "working" then
												say_slot(sl, short_title(sl.title, 12), 3.2)
											else
												local wk = WHISPERS_IDLE[rand_int(1, #WHISPERS_IDLE)]
												say_slot(sl, zeron.s(wk), 3.2)
											end
										end
										sl.pose:set(p)
									end
								else
									local speed = if sl.kind == "attention" then 94 elseif sl.kind == "working" then 72 else 58
									if is_in_text_zone(p.x, p.by, W, H_up, false) then
										speed = speed * 1.45
									end
									local target_a = math.atan2(dy_screen, dx)
									local ang_diff = norm_angle(target_a - p.hd)
									p.hd = p.hd + ang_diff * math.min(1, dt * 11.0)
									local align = clamp((math.cos(ang_diff) + 0.15) / 1.15, 0.12, 1.0)
									local step = math.min(dist, speed * align * dt)
									p.x = clamp(p.x + (dx / dist) * step, 28, W - 36)
									p.by = clamp(p.by + (dby / dist) * step, 44, H_up)
									p.wp += dt * (11.0 + 7.0 * align)
									sl.pose:set(p)
								end
							elseif ph == "peek" then
								if now_s >= sl.mode_until then
									p.look = 0
									local nx, nby = pick_target(false)
									sl.tx = nx
									sl.tby = nby
									sl.phase:set("walk")
									sl.pose:set(p)
								elseif (tick_seq + sl.idx) % 4 == 0 then
									p.wp += dt * 16.0
									p.look = math.sin(now_s * 3.2 + sl.idx)
									sl.pose:set(p)
								end
							elseif ph == "weave" then
								sl.weave_angle += dt * 4.5
								local r = 10
								p.x = clamp(sl.tx + math.cos(sl.weave_angle) * r, 36, W - 44)
								p.by = clamp(sl.tby - math.sin(sl.weave_angle) * r, 52, H_up)
								p.hd = sl.weave_angle + math.pi / 2
								p.wp += dt * 22
								if now_s >= sl.mode_until then
									local px, pby = pick_target(true)
									sl.tx = px
									sl.tby = pby
									sl.phase:set("walk")
								end
								sl.pose:set(p)
							elseif ph == "rappel" then
								p.wp += dt * 6
								local aby = sl.anchor_by
								local max_drop = math.min(82, math.max(36, aby - 46))
								local drop_dist = aby - p.by
								if now_s < sl.mode_until - 1.5 then
									if drop_dist < max_drop and sl.rappel_dir > 0 then
										p.by -= 44 * dt
									else
										sl.rappel_dir = 0
									end
								else
									if drop_dist > 2 then
										p.by = math.min(aby, p.by + 58 * dt)
									else
										p.by = aby
										local px, pby = pick_target(true)
										sl.tx = px
										sl.tby = pby
										sl.phase:set("walk")
									end
								end
								sl.pose:set(p)
							end
						end
					end

					if (now_s - last_stage_pub) >= 0.25 then
						local webs_out = {}
						if has_webs then
							for i = 1, MAX_WEBS do
								local wb = web_slots[i]:peek()
								if wb then
									table.insert(webs_out, { id = wb.id, x = wb.x, by = wb.by, r = wb.radius })
								end
							end
						end
						local pets_out = {}
						for _, sl in slots do
							if sl.active:peek() then
								local sp = sl.pose:peek()
								table.insert(pets_out, { idx = sl.idx, x = sp.x, by = sp.by, phase = sl.phase:peek(), sid = sl.sid })
							end
						end
						local has_now = (#webs_out > 0) or (#pets_out > 0)
						if has_now or stage_had_content then
							last_stage_pub = now_s
							stage_had_content = has_now
							local z_snap = compute_zones(W, H_up, false)
							stage_snapshot:set({
								w = W,
								h_up = H_up,
								zones = z_snap,
								webs = webs_out,
								pets = pets_out,
							})
						end
					end
				end)
			end)

			local function handle_complete_click(sl: SpiderSlot)
				local sid = sl.sid
				if sid and sid ~= "__patrol__" and active_chat_id ~= sid then
					zeron.open { session = sid }
				end
				launch_swing(sl)
			end

			local function selected_slot(): SpiderSlot?
				local idx = menu_slot_idx:get()
				if idx >= 1 and idx <= MAX_SPIDERS then
					return slots[idx]
				end
				return nil
			end

			-- Build direct children table using table.insert (NEVER mid-table table.unpack!)
			-- and use reactive hidden= on each absolute element (zero nested 0x0 wrapper clipping).
			local layer_children: { [any]: any } = {
				ref = layout.ref("titlebar"),
				id = "spider-pet-layer",
				w_full = true,
				h = 0,
				relative = true,
				overflow = "visible",
				pointer_events = "none",
				on_resize = function(size: { w: number, h: number }, el: any)
					if size.w >= 100 and math.abs(win_w:peek() - size.w) > 2 then
						win_w:set(size.w)
					end
					if el and type(el.y) == "number" and el.y > 220 and math.abs(stage_y:peek() - el.y) > 2 then
						stage_y:set(el.y)
					end
				end,
			}

			for slot_i = 1, MAX_WEBS do
				local slot_state = web_slots[slot_i]
				table.insert(layer_children, ui.div {
					absolute = true,
					hidden = function(): boolean
						return not (is_pet_on() and slot_state:get() ~= nil)
					end,
					left = function(): number
						local wb = slot_state:get()
						return if wb then wb.x - WEB_CANVAS_SZ / 2 else 0
					end,
					top = function(): number
						local wb = slot_state:get()
						return if wb then -wb.by - WEB_CANVAS_SZ / 2 else 0
					end,
					w = WEB_CANVAS_SZ,
					h = WEB_CANVAS_SZ,
					opacity = function(): number
						local wb = slot_state:get()
						if not wb then
							return 0
						end
						local W = math.max(360, win_w:get())
						local H_up = max_by(true)
						return if is_in_text_zone(wb.x, wb.by, W, H_up, true) then 0.20 else 0.78
					end,
					pointer_events = "none",
					SpunWebCanvas {
						web = function(): SpunWeb?
							return slot_state:get()
						end,
						now_fn = function(): number
							return clock_now:get()
						end,
					},
				})
			end

			table.insert(layer_children, ui.div {
				absolute = true,
				left = 0,
				top = 0,
				w = 0,
				h = 0,
				overflow = "visible",
				pointer_events = "none",
				provide = {
					spider_stage = stage_snapshot,
				},
				zeron.slot("stage", {
					w = 0,
					h = 0,
					overflow = "visible",
					pointer_events = "none",
				}),
			})

			for _, sl in slots do
				local function slot_visible(): boolean
					return is_pet_on() and sl.active:get()
				end

				-- 1. Silk rappel line
				table.insert(layer_children, ui.div {
					absolute = true,
					hidden = function(): boolean
						return not (slot_visible() and sl.phase:get() == "rappel")
					end,
					left = function(): number
						return sl.pose:get().x - 1
					end,
					top = function(): number
						return -sl.anchor_by
					end,
					w = 2,
					h = function(): number
						return math.max(0, sl.anchor_by - sl.pose:get().by)
					end,
					bg = function(): string
						return if is_light_theme() then "$text.tertiary" else "$border"
					end,
					opacity = function(): number
						return if is_light_theme() then 0.6 else 0.7
					end,
					pointer_events = "none",
				})

				-- 2. Diagonal Spider-Man swing web line
				table.insert(layer_children, ui.div {
					absolute = true,
					hidden = function(): boolean
						return not (slot_visible() and sl.phase:get() == "swing")
					end,
					pointer_events = "none",
					left = function(): number
						return math.min(sl.pose:get().x, sl.swing_ax) - 20
					end,
					top = function(): number
						return math.min(-sl.pose:get().by, -sl.swing_aby) - 20
					end,
					w = function(): number
						return math.max(40, math.abs(sl.swing_ax - sl.pose:get().x) + 40)
					end,
					h = function(): number
						return math.max(40, math.abs(sl.swing_aby - sl.pose:get().by) + 40)
					end,
					ui.canvas {
						w_full = true,
						h_full = true,
						pointer_events = "none",
						draw = function(c: any)
							if sl.phase:get() ~= "swing" then
								return
							end
							local p = sl.pose:get()
							local sx, sby = p.x, p.by
							local ax, aby = sl.swing_ax, sl.swing_aby
							local ox = math.min(sx, ax) - 20
							local oy = math.min(-sby, -aby) - 20

							local x1, y1 = sx - ox, -sby - oy
							local x2, y2 = ax - ox, -aby - oy
							local prog = clamp(p.st / (SWING_SHOOT_S * 0.85), 0, 1)
							local cur_x2 = x1 + (x2 - x1) * prog
							local cur_y2 = y1 + (y2 - y1) * prog

							local light = is_light_theme()
							local glow = ink.canvas({ token = "accent", alpha = if light then 0.28 else 0.24 })
							local silk_main = if light then "#334155" else "#f8fafc"
							c:line(x1, y1, cur_x2, cur_y2, glow, 4.0)
							c:line(x1, y1, cur_x2, cur_y2, silk_main, if light then 2.2 else 1.8)
							if light then
								c:line(x1, y1, cur_x2, cur_y2, "#ffffffcc", 0.9)
							end

							if prog >= 0.95 then
								c:circle(x2, y2, 3.2, silk_main)
								for k = 0, 5 do
									local ra = k * (math.pi / 3) + 0.3
									c:line(x2, y2, x2 + math.cos(ra) * 8, y2 + math.sin(ra) * 8, silk_main, if light then 1.3 else 1.1)
								end
							end
						end,
					},
				})

				-- 3. Persistent completion prompt pill (frozen above spider until clicked or entered)
				table.insert(layer_children, ui.button {
					absolute = true,
					hidden = function(): boolean
						return not (slot_visible() and sl.phase:get() == "completed")
					end,
					left = 0,
					top = 0,
					x = function(): number
						local W = math.max(360, win_w:get())
						return clamp(sl.pose:get().x - 92, 12, W - 224)
					end,
					y = function(): number
						local by_now = sl.pose:get().by
						return if by_now < max_by(true) - 80 then -by_now - 56 else -by_now + 32
					end,
					px = "$space.2",
					py = 5,
					rounded = "$radius.full",
					border = 1,
					border_color = "$success",
					bg = "$surface.raised",
					hover = { bg = "$surface.base", border_color = "$success" },
					active = { bg = "$surface.sunken", border_color = "$success" },
					shadow = "$shadow.lg",
					cursor = "pointer",
					pointer_events = function(): string
						return if slot_visible() and sl.phase:get() == "completed" then "auto" else "none"
					end,
					on_click = function()
						handle_complete_click(sl)
					end,
					ui.row {
						items = "center",
						gap = "$space.1",
						ui.div { w = 6, h = 6, rounded = "$radius.full", bg = "$success" },
						ui.text {
							function(): string
								meta_rev:get()
								local stitle = short_title(sl.title, 12)
								if sl.sid and sl.sid == active_chat_id then
									return zeron.s("pet.done_here_prompt", { title = stitle })
								end
								return zeron.s("pet.done_prompt", { title = stitle })
							end,
							literal = true,
							text_size = "$font.size.xs",
							weight = "$font.weight.bold",
							color = "$text.primary",
						},
					},
				})

				-- 4. Whisper speech bubble
				table.insert(layer_children, ui.button {
					absolute = true,
					hidden = function(): boolean
						return not (slot_visible() and sl.phase:get() ~= "completed" and sl.whisper:get() ~= nil and menu_slot_idx:get() ~= sl.idx)
					end,
					left = 0,
					top = 0,
					x = function(): number
						local W = math.max(360, win_w:get())
						return clamp(sl.pose:get().x - 72, 12, W - 196)
					end,
					y = function(): number
						local by_now = sl.pose:get().by
						return if by_now < max_by(true) - 80 then -by_now - 50 else -by_now + 30
					end,
					px = "$space.2",
					py = 4,
					rounded = "$radius.full",
					border = 1,
					border_color = "$border",
					bg = "$surface.raised",
					shadow = "$shadow.md",
					hover = { bg = "$surface.base", border_color = "$accent" },
					active = { bg = "$surface.sunken", border_color = "$accent" },
					cursor = "pointer",
					on_hover = function(inside: boolean)
						if inside then
							hovered_whisper:set(sl.idx)
						elseif hovered_whisper:peek() == sl.idx then
							hovered_whisper:set(0)
						end
					end,
					opacity = function(): number
						if hovered_whisper:get() == sl.idx or hovered_slot:get() == sl.idx then
							return 1.0
						end
						local p = sl.pose:get()
						local W = math.max(360, win_w:get())
						local H_up = max_by(true)
						return if is_in_text_zone(p.x, p.by, W, H_up, true) then 0.34 else 0.94
					end,
					pointer_events = function(): string
						return if slot_visible() and sl.whisper:get() ~= nil and menu_slot_idx:get() ~= sl.idx then "auto" else "none"
					end,
					on_click = function()
						if sl.sid and sl.sid ~= "__patrol__" and sl.kind == "attention" then
							zeron.open { session = sl.sid }
							sl.whisper:set(nil)
						elseif sl.phase:peek() ~= "swing" then
							menu_slot_idx:set(sl.idx)
						end
					end,
					ui.text {
						function(): string
							return sl.whisper:get() or ""
						end,
						literal = true,
						text_size = "$font.size.xs",
						color = "$text.primary",
					},
				})

				-- 5. Interactive Spider / Cartoon Spider-Man actor
				table.insert(layer_children, ui.button {
					absolute = true,
					hidden = function(): boolean
						return not slot_visible()
					end,
					left = -ACTOR_BOX / 2,
					top = -ACTOR_BOX / 2,
					x = function(): number
						return sl.pose:get().x
					end,
					y = function(): number
						return -sl.pose:get().by
					end,
					w = ACTOR_BOX,
					h = ACTOR_BOX,
					p = 0,
					bg = "#00000000",
					hover = { bg = "#00000000" },
					active = { bg = "#00000000" },
					rounded = "$radius.full",
					cursor = "pointer",
					on_hover = function(inside: boolean)
						if inside then
							hovered_slot:set(sl.idx)
						elseif hovered_slot:peek() == sl.idx then
							hovered_slot:set(0)
						end
					end,
					opacity = function(): number
						if hovered_slot:get() == sl.idx or menu_slot_idx:get() == sl.idx then
							return 1.0
						end
						local ph = sl.phase:get()
						if ph == "swing" or ph == "completed" then
							return 1.0
						end
						local p = sl.pose:get()
						local W = math.max(360, win_w:get())
						local H_up = max_by(true)
						return if is_in_text_zone(p.x, p.by, W, H_up, true) then 0.22 else 0.88
					end,
					pointer_events = function(): string
						return if slot_visible() then "auto" else "none"
					end,
					label = function(): string
						meta_rev:get()
						if sl.title ~= "" then
							return zeron.s("pet.tooltip_sess", { title = short_title(sl.title, 16) })
						end
						return zeron.s("pet.tooltip")
					end,
					on_click = function()
						local ph = sl.phase:peek()
						if ph == "swing" then
							return
						end
						if ph == "completed" then
							handle_complete_click(sl)
							return
						end
						local np = clone_pose(sl.pose:peek())
						np.hop = 8
						sl.pose:set(np)
						if menu_slot_idx:peek() == sl.idx then
							menu_slot_idx:set(0)
						else
							menu_slot_idx:set(sl.idx)
						end
					end,
					SpiderActorCanvas { slot = sl },
				})
			end

			-- 6. Interactive companion popover (single shared instance)
			table.insert(layer_children, Glass.Panel {
				id = "spider-pet-popover",
				kind = "menu",
				absolute = true,
				hidden = function(): boolean
					return not (is_pet_on() and selected_slot() ~= nil)
				end,
				left = function(): number
					local sl = selected_slot()
					local W = math.max(360, win_w:get())
					local x = if sl then sl.pose:get().x else 300
					return clamp(x - 136, 14, W - 286)
				end,
				top = function(): number
					local sl = selected_slot()
					local by_now = if sl then sl.pose:get().by else 260
					return if by_now < 220 then -by_now - 208 else -by_now + 32
				end,
				w = 272,
				p = "$space.3",
				gap = "$space.2",
				rounded = "$radius.xl",
				pointer_events = function(): string
					return if is_pet_on() and selected_slot() ~= nil then "auto" else "none"
				end,

				ui.row {
					w_full = true,
					items = "center",
					justify = "between",
					gap = "$space.2",
					ui.row {
						items = "center",
						gap = "$space.2",
						ui.image { src = "art/spider-crest.webp", w = 16, h = 16, fit = "contain", aria_hidden = true },
						ui.text { zeron.t("pet.title"), font = "$font.mono", text_size = "$font.size.xs", weight = "$font.weight.bold" },
					},
					ui.row {
						items = "center",
						gap = "$space.1",
						ui.text {
							function(): string
								meta_rev:get()
								return quota_label
							end,
							literal = true,
							font = "$font.mono",
							text_size = "$font.size.xs",
							color = "$text.tertiary",
						},
						IconButton.IconButton {
							icon = "close",
							size = "sm",
							label = zeron.s("pet.close"),
							on_click = function()
								menu_slot_idx:set(0)
							end,
						},
					},
				},

				ui.column {
					w_full = true,
					p = "$space.2",
					gap = "$space.2",
					rounded = "$radius.md",
					bg = "$surface.raised",
					border = 1,
					border_color = "$border",
					ui.column {
						w_full = true,
						gap = 4,
						ui.row {
							w_full = true,
							items = "center",
							gap = "$space.1",
							ui.div {
								w = 6,
								h = 6,
								rounded = "$radius.full",
								shrink = 0,
								bg = function(): string
									meta_rev:get()
									local sl = selected_slot()
									local k = if sl then sl.kind else "patrol"
									if k == "attention" then
										return "$warning"
									elseif k == "working" then
										return "$accent"
									elseif k == "current" then
										return "$success"
									end
									return "$text.tertiary"
								end,
							},
							ui.text {
								function(): string
									meta_rev:get()
									local sl = selected_slot()
									local k = if sl then sl.kind else "patrol"
									if k == "attention" then
										return zeron.s("pet.kind_attention")
									elseif k == "working" then
										return zeron.s("pet.kind_working")
									elseif k == "current" then
										return zeron.s("pet.kind_current")
									end
									return zeron.s("pet.kind_patrol")
								end,
								literal = true,
								font = "$font.mono",
								text_size = "$font.size.xs",
								color = function(): string
									meta_rev:get()
									local sl = selected_slot()
									local k = if sl then sl.kind else "patrol"
									if k == "attention" then
										return "$warning"
									elseif k == "working" then
										return "$accent"
									elseif k == "current" then
										return "$success"
									end
									return "$text.tertiary"
								end,
							},
						},
						ui.text {
							function(): string
								meta_rev:get()
								local sl = selected_slot()
								if not sl then
									return ""
								end
								if sl.kind == "patrol" or not sl.sid or sl.sid == "__patrol__" then
									return zeron.s("pet.status_patrol")
								end
								return short_title(sl.title, 28)
							end,
							literal = true,
							text_size = "$font.size.xs",
							weight = "$font.weight.medium",
							color = "$text.primary",
							wrap = true,
						},
					},
					ui.row {
						w_full = true,
						items = "center",
						gap = "$space.2",
						ui.show(function(): boolean
							meta_rev:get()
							local sl = selected_slot()
							return sl ~= nil and sl.sid ~= nil and sl.sid ~= "__patrol__"
						end, Button {
							tone = "primary",
							size = "sm",
							shape = "rounded",
							grow = 1,
							min_w = 0,
							on_click = function()
								local sl = selected_slot()
								if sl and sl.sid and sl.sid ~= "__patrol__" then
									zeron.open { session = sl.sid }
								end
								menu_slot_idx:set(0)
							end,
							Icon { name = "arrow-right", size = 12 },
							ui.text { zeron.t("pet.btn_open_chat") },
						}),
						Button {
							tone = "secondary",
							size = "sm",
							shape = "rounded",
							grow = 1,
							min_w = 0,
							on_click = function()
								local list = db.prompts()
								if active_chat_id ~= nil then
									zeron.compose(zeron.s("pet.inspect_prompt"))
									zeron.toast(zeron.s("pet.toast_composed"))
								elseif #list > 0 then
									local p_item = list[rand_int(1, #list)]
									zeron.compose(p_item.content)
									zeron.toast(zeron.s("pet.toast_prompt", { title = p_item.title }))
								else
									zeron.compose(zeron.s("pet.inspect_prompt"))
									zeron.toast(zeron.s("pet.toast_composed"))
								end
								menu_slot_idx:set(0)
							end,
							Icon { name = "magic-stick", size = 12 },
							ui.text {
								function(): string
									meta_rev:get()
									return if active_chat_id ~= nil
										then zeron.s("pet.btn_inspect_chat")
										else zeron.s("pet.btn_draft_prompt")
								end,
								literal = true,
							},
						},
					},
				},

				ui.row {
					w_full = true,
					items = "center",
					gap = "$space.1",
					Button {
						tone = "ghost",
						size = "xs",
						shape = "rounded",
						grow = 1,
						min_w = 0,
						on_click = function()
							local sl = selected_slot()
							menu_slot_idx:set(0)
							if sl then
								start_weave(sl)
							end
						end,
						Icon { name = "star", size = 11 },
						ui.text { zeron.t("pet.btn_weave") },
					},
					Button {
						tone = "ghost",
						size = "xs",
						shape = "rounded",
						grow = 1,
						min_w = 0,
						on_click = function()
							local sl = selected_slot()
							menu_slot_idx:set(0)
							if sl then
								start_rappel(sl)
								say_slot(sl, zeron.s("pet.rappel_say"), 3.0)
							end
						end,
						Icon { name = "eye", size = 11 },
						ui.text { zeron.t("pet.btn_rappel") },
					},
					Button {
						tone = "ghost",
						size = "xs",
						shape = "rounded",
						grow = 1,
						min_w = 0,
						on_click = function()
							local sl = selected_slot()
							menu_slot_idx:set(0)
							if sl then
								local nx, nby = pick_target(false)
								sl.tx = nx
								sl.tby = nby
								sl.phase:set("walk")
								say_slot(sl, zeron.s("pet.roam_say"), 2.8)
							end
						end,
						Icon { name = "refresh", size = 11 },
						ui.text { zeron.t("pet.btn_roam") },
					},
				},
				zeron.slot("pet_actions", {
					w_full = true,
					gap = "$space.1",
				}),
			})

			return ui.div(layer_children)
		end,
	}
end

return M
