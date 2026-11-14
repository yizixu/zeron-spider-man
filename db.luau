--!strict
local M = {}

export type Snippet = {
	id: number,
	kind: string, -- "prompt" | "snippet"
	title: string,
	content: string,
	project: string?,
	created_at: number,
}

local ITEMS: State<{ Snippet }> = ui.state("spider_db_items", {} :: { Snippet })
local READY: State<boolean> = ui.state("spider_db_ready", false)
local zeron_ref: any = nil

local DEFAULT_PROMPTS = {
	{
		title = "代码审查",
		content = "请重点审查当前改动中的边界条件、并发/异步竞态、错误处理与潜在性能问题，按严重程度列出问题及最小修复建议。",
	},
	{
		title = "定位报错",
		content = "请先分析这个报错的根因、触发条件与完整调用链，再给出最直接可靠的修复方案和验证命令。",
	},
	{
		title = "补充单测",
		content = "请为当前改动补充覆盖正常路径、边界条件与异常分支的单元测试，并运行测试确认全部通过。",
	},
	{
		title = "改动总结",
		content = "请用简洁要点总结本次涉及的文件、核心逻辑变更、潜在风险以及下一步建议的验证步骤。",
	},
	{
		title = "Commit 信息",
		content = "请根据当前改动生成 1 条简洁准确的 Conventional Commits 提交信息（附带简短要点说明）。",
	},
}

local function reload()
	if not zeron_ref then
		return
	end
	zeron_ref.db
		.query("SELECT id, kind, title, content, project, created_at FROM spider_snippets ORDER BY CASE WHEN kind = 'prompt' THEN 0 ELSE 1 END, id DESC")
		:after(function(rows: { any })
			local out: { Snippet } = {}
			for _, r in rows or {} do
				table.insert(out, {
					id = tonumber(r.id) or 0,
					kind = tostring(r.kind or "snippet"),
					title = tostring(r.title or ""),
					content = tostring(r.content or ""),
					project = if r.project and r.project ~= "" then tostring(r.project) else nil,
					created_at = tonumber(r.created_at) or 0,
				})
			end
			ITEMS:set(out)
			READY:set(true)
		end, function(err: any)
			print("spider-man db query error:", err)
		end)
end

function M.init(zeron: any)
	zeron_ref = zeron
	local seeded = zeron.store("spider_seeded_v1", false)
	zeron.db
		.exec([[
			CREATE TABLE IF NOT EXISTS spider_snippets (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				kind TEXT NOT NULL,
				title TEXT NOT NULL,
				content TEXT NOT NULL,
				project TEXT,
				created_at INTEGER NOT NULL
			)
		]])
		:after(function()
			if not seeded:peek() then
				seeded:set(true)
				zeron.db
					.query("SELECT COUNT(*) AS cnt FROM spider_snippets")
					:after(function(rows: { any })
						local cnt = (rows and rows[1] and tonumber(rows[1].cnt)) or 0
						if cnt == 0 then
							local now = os.time()
							local pending = #DEFAULT_PROMPTS
							for _, item in DEFAULT_PROMPTS do
								zeron.db
									.exec(
										"INSERT INTO spider_snippets (kind, title, content, project, created_at) VALUES (?, ?, ?, ?, ?)",
										{ "prompt", item.title, item.content, "", now }
									)
									:after(function()
										pending -= 1
										if pending <= 0 then
											reload()
										end
									end)
							end
						else
							reload()
						end
					end, function()
						reload()
					end)
			else
				reload()
			end
		end, function(err: any)
			print("spider-man db init error:", err)
		end)
end

function M.items(): { Snippet }
	return ITEMS:get()
end

function M.prompts(): { Snippet }
	local out: { Snippet } = {}
	for _, it in ITEMS:get() do
		if it.kind == "prompt" then
			table.insert(out, it)
		end
	end
	return out
end

function M.ready(): boolean
	return READY:get()
end

function M.add(kind: string, title: string, content: string, project: string?, on_done: (() -> ())?)
	if not zeron_ref then
		return
	end
	local t = string.gsub(title, "^%s*(.-)%s*$", "%1")
	local c = string.gsub(content, "^%s*(.-)%s*$", "%1")
	if t == "" or c == "" then
		return
	end
	zeron_ref.db
		.exec(
			"INSERT INTO spider_snippets (kind, title, content, project, created_at) VALUES (?, ?, ?, ?, ?)",
			{ kind, t, c, project or "", os.time() }
		)
		:after(function()
			reload()
			if on_done then
				on_done()
			end
		end, function(err: any)
			print("spider-man db add error:", err)
		end)
end

function M.update(id: number, title: string, content: string, on_done: (() -> ())?)
	if not zeron_ref then
		return
	end
	local t = string.gsub(title, "^%s*(.-)%s*$", "%1")
	local c = string.gsub(content, "^%s*(.-)%s*$", "%1")
	if t == "" or c == "" then
		return
	end
	zeron_ref.db
		.exec("UPDATE spider_snippets SET title = ?, content = ? WHERE id = ?", { t, c, id })
		:after(function()
			reload()
			if on_done then
				on_done()
			end
		end, function(err: any)
			print("spider-man db update error:", err)
		end)
end

function M.set_kind(id: number, kind: string, on_done: (() -> ())?)
	if not zeron_ref then
		return
	end
	zeron_ref.db
		.exec("UPDATE spider_snippets SET kind = ? WHERE id = ?", { kind, id })
		:after(function()
			reload()
			if on_done then
				on_done()
			end
		end, function(err: any)
			print("spider-man db set_kind error:", err)
		end)
end

function M.remove(id: number)
	if not zeron_ref then
		return
	end
	zeron_ref.db.exec("DELETE FROM spider_snippets WHERE id = ?", { id }):after(function()
		reload()
	end)
end

return M
