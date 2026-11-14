--!strict
local ink = require("@ds/visual_ink")

local M = {}

local function tone_token(pct: number, warn_pct: number): string
	if pct <= warn_pct then
		return "danger"
	elseif pct <= warn_pct * 2 then
		return "warning"
	end
	return "success"
end

-- Radial 8-spoke scalloped Orb-Weaver Spider Web quota dial.
function M.OrbWeb(props: { pct: number, warn_pct: number, size: number? }): Node
	local sz = props.size or 96
	local pct = math.max(0, math.min(100, math.floor(props.pct + 0.5)))
	local frac = pct / 100
	local tok = tone_token(pct, props.warn_pct)

	return ui.canvas {
		w = sz,
		h = sz,
		shrink = 0,
		draw = function(c: any, w: number, h: number)
			ui.theme.current:get()
			local cx, cy = w / 2, h / 2
			local R = math.min(w, h) / 2 - 7
			local spokes = 8
			local step = (math.pi * 2) / spokes
			local start_ang = -math.pi / 2

			local web_muted = ink.canvas({ token = "border", alpha = 0.72 })
			local web_ring_muted = ink.canvas({ token = "border", alpha = 0.52 })
			local active_fill = ink.canvas({ token = tok, alpha = 0.22 })
			local active_silk = ink.canvas({ token = tok, alpha = 0.75 })
			local active_bright = ink.canvas(tok)
			
			-- 1. Active scalloped sector / fill under the web
			if frac > 0.005 then
				if frac >= 0.999 then
					local p = ui.path():move(cx + R * math.cos(start_ang), cy + R * math.sin(start_ang))
					for i = 0, spokes - 1 do
						local a2 = start_ang + (i + 1) * step
						local amid = start_ang + (i + 0.5) * step
						local rc = R * 0.88
						p = p:quad(cx + rc * math.cos(amid), cy + rc * math.sin(amid), cx + R * math.cos(a2), cy + R * math.sin(a2))
					end
					p = p:close()
					c:fill(p, active_fill)
				else
					local total_rad = math.pi * 2 * frac
					local segs = math.max(4, math.ceil(28 * frac))
					local p = ui.path():move(cx, cy)
					for i = 0, segs do
						local a = start_ang + total_rad * (i / segs)
						p = p:line(cx + R * math.cos(a), cy + R * math.sin(a))
					end
					p = p:close()
					c:fill(p, active_fill)
				end
			end

			-- 2. Base 8 radial spokes (colored inside filled sweep, muted outside)
			local sweep_rad = math.pi * 2 * frac
			for i = 0, spokes - 1 do
				local rel = (i / spokes)
				local a = start_ang + i * step
				local x2 = cx + R * math.cos(a)
				local y2 = cy + R * math.sin(a)
				local covered = frac > 0.01 and (rel <= frac + 0.001)
				c:line(cx, cy, x2, y2, if covered then active_silk else web_muted, if covered then 1.25 else 1)
			end

			-- 3. Concentric scalloped orb-web rings (4 rings)
			local rings = { 0.36, 0.58, 0.79, 1.0 }
			for _, rf in rings do
				local r = R * rf
				local p = ui.path():move(cx + r * math.cos(start_ang), cy + r * math.sin(start_ang))
				for i = 0, spokes - 1 do
					local a2 = start_ang + (i + 1) * step
					local amid = start_ang + (i + 0.5) * step
					local rc = r * 0.86
					p = p:quad(cx + rc * math.cos(amid), cy + rc * math.sin(amid), cx + r * math.cos(a2), cy + r * math.sin(a2))
				end
				p = p:close()
				c:stroke(p, web_ring_muted, 1, { join = "round" })
			end

			-- 4. Highlighted inner web arcs across filled angle
			if frac > 0.02 then
				local sweep_deg = math.max(3, 360 * frac)
				for _, rf in { 0.58, 0.79 } do
					c:stroke(ui.path():arc(cx, cy, R * rf, -90, sweep_deg), active_silk, 1.15, { cap = "round" })
				end
				-- Outer luminous silk progress arc
				c:stroke(ui.path():arc(cx, cy, R, -90, sweep_deg), active_bright, 2.75, { cap = "round" })
			end

			-- 5. Dewdrop nodes on covered outer spokes
			if frac > 0.01 then
				for i = 0, spokes - 1 do
					if (i / spokes) <= frac + 0.001 then
						local a = start_ang + i * step
						c:circle(cx + R * math.cos(a), cy + R * math.sin(a), 2.1, active_bright)
					end
				end
				-- Progress tip node
				local tip_a = start_ang + sweep_rad
				local tx = cx + R * math.cos(tip_a)
				local ty = cy + R * math.sin(tip_a)
				c:circle(tx, ty, 4.5, ink.canvas({ token = tok, alpha = 0.35 }))
				c:circle(tx, ty, 2.5, active_bright)
			end

			-- 6. Center Spider-Crest hub & crisp percentage readout
			local hub_r = R * 0.44
			c:circle(cx, cy, hub_r, "$background")
			c:stroke(ui.path():arc(cx, cy, hub_r, 0, 360), if frac > 0 then active_silk else web_muted, 1.35)
			c:text(`{pct}%`, cx, cy, {
				size = 13,
				color = "$text.primary",
				align = "center",
				baseline = "middle",
				tabular = true,
				weight = 700,
			})
		end,
	}
end

-- Horizontal Spider-Silk Tension Gauge replacing plain straight ProgressBar.
function M.SilkBar(props: { pct: number, warn_pct: number }): Node
	local pct = math.max(0, math.min(100, math.floor(props.pct + 0.5)))
	local frac = pct / 100
	local tok = tone_token(pct, props.warn_pct)

	return ui.canvas {
		w_full = true,
		h = 18,
		draw = function(c: any, w: number, h: number)
			ui.theme.current:get()
			local pad = 6
			local tw = math.max(12, w - pad * 2)
			local cy = h / 2
			local fill_x = pad + tw * frac

			local rail_muted = ink.canvas({ token = "border", alpha = 0.7 })
			local zig_muted = ink.canvas({ token = "border", alpha = 0.45 })
			local active_bright = ink.canvas(tok)
			local active_soft = ink.canvas({ token = tok, alpha = 0.48 })
			local active_glow = ink.canvas({ token = tok, alpha = 0.25 })

			-- Twin horizontal silk anchor cables
			c:line(pad, cy - 3, pad + tw, cy - 3, rail_muted, 1)
			c:line(pad, cy + 3, pad + tw, cy + 3, rail_muted, 1)

			-- Diagonal cross-weave silk lattice along full track
			local seg_w = 12
			local zig = ui.path():move(pad, cy - 3)
			local x = pad
			local up = false
			while x < pad + tw do
				local nx = math.min(pad + tw, x + seg_w)
				local ny = if up then cy - 3 else cy + 3
				zig = zig:line(nx, ny)
				x = nx
				up = not up
			end
			c:stroke(zig, zig_muted, 1, { join = "round" })

			-- Active illuminated silk tension weave up to fill_x
			if frac > 0.01 then
				c:rect(pad, cy - 3, math.max(2, fill_x - pad), 6, active_glow, 3)
				c:line(pad, cy - 3, fill_x, cy - 3, active_soft, 1.4)
				c:line(pad, cy + 3, fill_x, cy + 3, active_soft, 1.4)

				local azig = ui.path():move(pad, cy - 3)
				local ax = pad
				local aup = false
				while ax < fill_x do
					local nx = math.min(fill_x, ax + seg_w)
					local ny = if aup then cy - 3 else cy + 3
					azig = azig:line(nx, ny)
					ax = nx
					aup = not aup
				end
				c:stroke(azig, active_bright, 1.4, { join = "round", cap = "round" })
				c:line(pad, cy, fill_x, cy, active_bright, 1.75, { cap = "round" })
			end

			-- Anchor silk knots at 0%, 25%, 50%, 75%, 100%
			for i = 0, 4 do
				local q = i * 0.25
				local nx = pad + tw * q
				local lit = frac >= q - 0.005 and frac > 0
				c:circle(nx, cy, if lit then 2.3 else 1.8, if lit then active_bright else rail_muted)
			end

			-- Spider-Node indicator at current fill position
			if frac > 0 then
				c:circle(fill_x, cy, 5.2, active_glow)
				c:circle(fill_x, cy, 3.1, active_bright)
				c:circle(fill_x, cy, 1.2, "$background")
			end
		end,
	}
end

-- Subtle decorative radial corner spider-web watermark for banners & empty states.
function M.CornerWeb(props: { size: number?, alpha: number? }): Node
	local sz = props.size or 92
	local a = props.alpha or 0.35
	return ui.canvas {
		w = sz,
		h = sz,
		shrink = 0,
		draw = function(c: any, w: number, h: number)
			ui.theme.current:get()
			local ox, oy = w - 2, 2
			local max_r = math.min(w, h) - 6
			local stroke_col = ink.canvas({ token = "accent", alpha = a })
			local ring_col = ink.canvas({ token = "border", alpha = a * 1.3 })

			-- Radial spokes fanning into the bottom-left quadrant (180 deg down to 90 deg)
			local spoke_count = 6
			for i = 0, spoke_count - 1 do
				local ang = math.pi * (0.5 + 0.5 * (i / (spoke_count - 1)))
				c:line(ox, oy, ox + max_r * math.cos(ang), oy + max_r * math.sin(ang), stroke_col, 1)
			end

			-- 4 scalloped corner web arcs
			for _, rf in { 0.28, 0.52, 0.76, 0.98 } do
				local r = max_r * rf
				local p = ui.path():move(ox + r * math.cos(math.pi * 0.5), oy + r * math.sin(math.pi * 0.5))
				for i = 0, spoke_count - 2 do
					local a1 = math.pi * (0.5 + 0.5 * (i / (spoke_count - 1)))
					local a2 = math.pi * (0.5 + 0.5 * ((i + 1) / (spoke_count - 1)))
					local amid = (a1 + a2) / 2
					local rc = r * 0.87
					p = p:quad(ox + rc * math.cos(amid), oy + rc * math.sin(amid), ox + r * math.cos(a2), oy + r * math.sin(a2))
				end
				c:stroke(p, ring_col, 1)
			end
		end,
	}
end

return M
