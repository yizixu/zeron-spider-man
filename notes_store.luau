--!strict
local M = {}

export type Source = { session: string?, title: string?, project: string?, message: string? }
export type Note = {
	id: number,
	content: string,
	session: string?,
	session_title: string?,
	project: string?,
	message: string?,
	created_at: number,
	updated_at: number,
}

local CREATE_SQL = [[
CREATE TABLE IF NOT EXISTS spider_notes (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	content TEXT NOT NULL CHECK(length(trim(content)) > 0),
	session TEXT NOT NULL DEFAULT '',
	session_title TEXT NOT NULL DEFAULT '',
	project TEXT NOT NULL DEFAULT '',
	message TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
]]
local LIST_SQL = "SELECT id, content, session, session_title, project, message, created_at, updated_at FROM spider_notes ORDER BY updated_at DESC, id DESC"
local INSERT_SQL = "INSERT INTO spider_notes (content, session, session_title, project, message, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
local UPDATE_SQL = "UPDATE spider_notes SET content = ?, updated_at = ? WHERE id = ?"
local DELETE_SQL = "DELETE FROM spider_notes WHERE id = ?"

local function optional_text(value: any): string?
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function M.new(zeron: any)
	local items: State<{ Note }> = ui.state("spider_notes_items", {} :: { Note })
	local ready: State<boolean> = ui.state("spider_notes_ready", false)
	local error_key: State<string?> = ui.state("spider_notes_error", nil :: string?)
	local revision: State<number> = ui.state("spider_notes_revision", 0)
	local request_seq = 0
	local initializing = false
	local initialized = false
	local store = {}

	local function fail(key: string, callback: ((string) -> ())?)
		if key == "notes.load_failed" then
			error_key:set(key)
			revision:set(revision:peek() + 1)
		end
		if callback then
			callback(key)
		end
	end

	local function request(start: () -> any, success: (any) -> (), failure: () -> ())
		local ok, promise = pcall(start)
		if not ok then
			failure()
			return
		end
		promise:after(success, failure)
	end

	function store.items(): { Note }
		return items:get()
	end

	function store.ready(): boolean
		return ready:get()
	end

	function store.error(): string?
		return error_key:get()
	end

	function store.rev(): number
		return revision:get()
	end

	function store.reload()
		request_seq += 1
		local seq = request_seq
		request(function()
			return zeron.db.query(LIST_SQL)
		end, function(rows: { any })
			if seq ~= request_seq then
				return
			end
			local list: { Note } = {}
			for _, row in rows do
				table.insert(list, {
					id = tonumber(row.id) or 0,
					content = tostring(row.content or ""),
					session = optional_text(row.session),
					session_title = optional_text(row.session_title),
					project = optional_text(row.project),
					message = optional_text(row.message),
					created_at = tonumber(row.created_at) or 0,
					updated_at = tonumber(row.updated_at) or 0,
				})
			end
			items:set(list)
			ready:set(true)
			error_key:set(nil)
			revision:set(revision:peek() + 1)
		end, function()
			if seq == request_seq then
				fail("notes.load_failed", nil)
			end
		end)
	end

	function store.init()
		if initializing then
			return
		end
		if initialized then
			store.reload()
			return
		end
		initializing = true
		request(function()
			return zeron.db.exec(CREATE_SQL)
		end, function()
			initializing = false
			initialized = true
			store.reload()
		end, function()
			initializing = false
			fail("notes.load_failed", nil)
		end)
	end

	function store.save(id: number?, content: string, source: Source?, done: ((number) -> ())?, on_error: ((string) -> ())?)
		local body = string.gsub(content, "^%s*(.-)%s*$", "%1")
		if body == "" then
			fail("notes.empty", on_error)
			return
		end
		if not initialized then
			fail("notes.load_failed", on_error)
			return
		end
		local src = source or {}
		local now = os.time()
		-- Reject earlier reads as soon as a write starts; only its subsequent
		-- reload may publish a new snapshot.
		request_seq += 1
		request(function()
			if id then
				return zeron.db.exec(UPDATE_SQL, { body, now, id })
			end
			return zeron.db.exec(INSERT_SQL, {
				body, src.session or "", src.title or "", src.project or "", src.message or "", now, now,
			})
		end, function(result: any)
			if (tonumber(result.changes) or 0) == 0 then
				fail("notes.missing", on_error)
				store.reload()
				return
			end
			local saved_id = id or tonumber(result.last_id)
			if not saved_id then
				fail("notes.save_failed", on_error)
				store.reload()
				return
			end
			error_key:set(nil)
			store.reload()
			if done then
				done(saved_id)
			end
		end, function()
			fail("notes.save_failed", on_error)
		end)
	end

	function store.remove(id: number, done: (() -> ())?, on_error: ((string) -> ())?)
		if not initialized then
			fail("notes.load_failed", on_error)
			return
		end
		request_seq += 1
		request(function()
			return zeron.db.exec(DELETE_SQL, { id })
		end, function()
			error_key:set(nil)
			store.reload()
			if done then
				done()
			end
		end, function()
			fail("notes.delete_failed", on_error)
		end)
	end

	return store
end

return M
