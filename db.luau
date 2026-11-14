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
local REV: State<number> = ui.state("spider_db_rev", 0)
local zeron_ref: any = nil
local seeding_in_flight = false

local DEFAULT_PROMPT_KEYS = { "1", "2", "3", "4", "5" }

local function is_valid_kind(kind: string): boolean
	return kind == "prompt" or kind == "snippet"
end

local function sql_str(s: string): string
	return "'" .. string.gsub(s, "'", "''") .. "'"
end

local function notify_db_error(key: string, err: any)
	print("spider-man db error:", err)
	if zeron_ref then
		pcall(function()
			zeron_ref.toast(zeron_ref.s(key))
		end)
	end
end

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
			REV:set(REV:peek() + 1)
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
			);
			CREATE TABLE IF NOT EXISTS spider_meta (
				k TEXT PRIMARY KEY,
				v TEXT NOT NULL
			);
		]])
		:after(function()
			if not seeded:peek() and not seeding_in_flight then
				seeding_in_flight = true
				local now = math.floor(os.time())
				local selects: { string } = {}
				for _, idx in DEFAULT_PROMPT_KEYS do
					local title = sql_str(zeron.s(`db.p{idx}_title`))
					local body = sql_str(zeron.s(`db.p{idx}_content`))
					table.insert(selects, `SELECT 'prompt' AS kind, {title} AS title, {body} AS content`)
				end
				local union_sql = table.concat(selects, " UNION ALL ")
				local script = table.concat({
					"BEGIN IMMEDIATE;",
					"INSERT OR IGNORE INTO spider_meta (k, v) SELECT 'seeded_v1', '1' WHERE EXISTS (SELECT 1 FROM spider_snippets);",
					`INSERT INTO spider_snippets (kind, title, content, project, created_at) SELECT kind, title, content, '', {now} FROM ({union_sql}) WHERE NOT EXISTS (SELECT 1 FROM spider_meta WHERE k = 'seeded_v1');`,
					"INSERT OR IGNORE INTO spider_meta (k, v) VALUES ('seeded_v1', '1');",
					"COMMIT;",
				}, "\n")

				-- Single atomic transaction: rolls back cleanly on error so future startups retry.
				zeron.db
					.exec(script)
					:after(function()
						seeding_in_flight = false
						seeded:set(true)
						reload()
					end, function(err: any)
						print("spider-man db atomic seed error:", err)
						local function finish()
							seeding_in_flight = false
							reload()
						end
						local ok_rb, rb_promise = pcall(function()
							return zeron.db.exec("ROLLBACK;")
						end)
						if ok_rb and rb_promise then
							rb_promise:after(finish, finish)
						else
							finish()
						end
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

function M.rev(): number
	return REV:get()
end

function M.add(kind: string, title: string, content: string, project: string?, on_done: (() -> ())?)
	if not zeron_ref or not is_valid_kind(kind) then
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
			notify_db_error("db.save_failed", err)
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
			notify_db_error("db.save_failed", err)
		end)
end

function M.set_kind(id: number, kind: string, on_done: (() -> ())?)
	if not zeron_ref or not is_valid_kind(kind) then
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
			notify_db_error("db.save_failed", err)
		end)
end

function M.remove(id: number, on_done: (() -> ())?, on_err: ((any) -> ())?)
	if not zeron_ref then
		return
	end
	zeron_ref.db
		.exec("DELETE FROM spider_snippets WHERE id = ?", { id })
		:after(function()
			reload()
			if on_done then
				on_done()
			end
		end, function(err: any)
			if on_err then
				on_err(err)
			else
				notify_db_error("db.delete_failed", err)
			end
		end)
end

return M
