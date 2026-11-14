--!strict
local M = {}

local refs: { [string]: any } = {}

M.win_w = ui.state("spider_layout_win_w", 1280)
M.stage_y = ui.state("spider_layout_stage_y", 0)
M.sidebar_r = ui.state("spider_layout_sidebar_r", 0)
M.panel_l = ui.state("spider_layout_panel_l", 0)
M.prose_cx = ui.state("spider_layout_prose_cx", 0)
M.prose_w = ui.state("spider_layout_prose_w", 0)

local function clamp(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

function M.ref(name: string): any
	local r = refs[name]
	if not r then
		r = ui.ref()
		refs[name] = r
	end
	return r
end

function M.probe(name: string): Node
	return ui.div {
		ref = M.ref(name),
		w_full = true,
		h = 0,
		overflow = "hidden",
		pointer_events = "none",
	}
end

local function box_of(name: string): { x: number, y: number, width: number, height: number }?
	local r = refs[name]
	if not r then
		return nil
	end
	local ok, list = pcall(function()
		return r:elements()
	end)
	if ok and type(list) == "table" then
		for _, e in list do
			if e and type(e.x) == "number" and type(e.width) == "number" and type(e.y) == "number" then
				return e
			end
		end
	end
	return nil
end

local function set_if_changed(st: any, val: number, tol: number): boolean
	local prev = tonumber(st:peek()) or 0
	if math.abs(prev - val) >= tol then
		st:set(val)
		return true
	end
	return false
end

function M.max_by(reactive: boolean?): number
	local sy = tonumber(if reactive then M.stage_y:get() else M.stage_y:peek()) or 0
	if sy > 240 then
		return clamp(math.floor(sy - 48), 320, 1400)
	end
	local ww = tonumber(if reactive then M.win_w:get() else M.win_w:peek()) or 1280
	return clamp(math.floor(ww * 0.48), 340, 1180)
end

function M.sample(): (number, number, boolean)
	local tb = box_of("titlebar")
	if tb and tb.width >= 100 then
		set_if_changed(M.win_w, math.floor(tb.width), 2)
	end
	if tb and tb.y > 220 then
		set_if_changed(M.stage_y, math.floor(tb.y), 2)
	end

	local W = math.max(360, tonumber(M.win_w:peek()) or 1280)
	local H_up = M.max_by(false)

	local cs = box_of("chat_session")
	local ch = box_of("chat_home")
	local pane = if cs and cs.width > 120 then cs elseif ch and ch.width > 120 then ch else nil
	local sh = box_of("session_header")
	local ct = box_of("composer_toolbar")
	local sb = box_of("sidebar")
	local rl = box_of("rail")

	local old_sr = tonumber(M.sidebar_r:peek()) or 0
	local old_pl = tonumber(M.panel_l:peek()) or 0

	local sr = 0
	local pl = 0

	if pane then
		local pane_l = pane.x
		local pane_r = pane.x + pane.width

		if pane_l <= 44 then
			sr = 0
		elseif rl and rl.width > 16 and rl.width <= 72 and pane_l <= 110 then
			sr = math.floor(math.max(rl.x + rl.width, pane_l - 6))
		else
			local cand = math.max(0, math.floor(pane_l - 6))
			if sb and sb.width > 70 and math.abs((sb.x + sb.width) - cand) <= 18 then
				sr = math.floor(sb.x + sb.width)
			else
				sr = cand
			end
		end
		sr = clamp(sr, 0, math.floor(W * 0.42))

		if pane_r >= W - 44 then
			pl = 0
		elseif pane_r > pane_l + 120 then
			pl = math.floor(pane_r + 5)
		else
			pl = 0
		end
	else
		if sh and sh.width > 120 then
			local sh_r = sh.x + sh.width
			if sh_r < W - 56 then
				pl = math.floor(sh_r + 5)
			else
				pl = 0
			end
		else
			pl = old_pl
		end

		local right_l = if pl > 0 then pl else W
		if rl and rl.width > 16 and rl.width <= 72 then
			sr = math.floor(rl.x + rl.width)
		elseif ct and ct.width > 120 then
			local ct_cx = ct.x + ct.width * 0.5
			local sr_inferred = 2 * ct_cx - right_l
			if sr_inferred <= 52 then
				sr = 0
			elseif sb and sb.width > 70 and math.abs((sb.x + sb.width) - sr_inferred) <= 44 then
				sr = math.floor(sb.x + sb.width)
			else
				sr = math.floor(clamp(sr_inferred, 0, W * 0.42))
			end
		else
			sr = old_sr
		end
	end

	local right_l = if pl > 0 then pl else W
	local cx = math.floor((sr + right_l) * 0.5)
	local pw = 0
	if ct and ct.width > 120 and ct.x >= sr - 12 and (ct.x + ct.width) <= right_l + 12 then
		cx = math.floor(ct.x + ct.width * 0.5)
		pw = math.floor(ct.width)
	end

	set_if_changed(M.sidebar_r, sr, 2)
	set_if_changed(M.panel_l, pl, 2)
	set_if_changed(M.prose_cx, cx, 2)
	set_if_changed(M.prose_w, pw, 2)

	local major_shift = math.abs(old_sr - sr) > 20 or math.abs(old_pl - pl) > 20
	return W, H_up, major_shift
end

return M
