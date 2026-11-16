--!strict
local M = {}

export type DraftItem = { title: string, body: string }
export type Item = { id: number, message: string, title: string, body: string, done: boolean }
type View = { items: { Item }, ready: boolean, error: string?, rev: number }
type OnError = ((string) -> ())?
type Finish = () -> ()
type Job = (Finish) -> ()

local MAX_BATCH = 100
local EMPTY: View = { items = {}, ready = false, error = nil, rev = 0 }
local CREATE_SQL = [[
CREATE TABLE IF NOT EXISTS spider_checklist (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	session TEXT NOT NULL,
	message TEXT NOT NULL,
	title TEXT NOT NULL,
	body TEXT NOT NULL,
	done INTEGER NOT NULL DEFAULT 0 CHECK(done IN (0, 1))
);
CREATE INDEX IF NOT EXISTS spider_checklist_source ON spider_checklist (session, message);
]]
local LIST_SQL = "SELECT id, message, title, body, done FROM spider_checklist WHERE session = ? ORDER BY id"
local UPDATE_SQL = "UPDATE spider_checklist SET done = ? WHERE session = ? AND id = ?"
local DELETE_SQL = "DELETE FROM spider_checklist WHERE session = ? AND id = ?"
local CLEAR_SQL = "DELETE FROM spider_checklist WHERE session = ?"

local function ignore_count(done: Finish?): ((number) -> ())?
	return if done then function(_count: number) done() end else nil
end

local function insert_batch(session: string, message: string, items: { DraftItem }): (string, { any })
	local params: { any } = { session, message }
	local values: { string } = {}
	for index, item in items do
		table.insert(values, "(?, ?, ?)")
		table.insert(params, index)
		table.insert(params, item.title)
		table.insert(params, item.body)
	end
	table.insert(params, session)
	table.insert(params, message)
	-- One statement makes the whole import atomic, even across windows. While
	-- any item from the reply remains, importing it again is a no-op.
	local sql = "INSERT INTO spider_checklist (session, message, title, body) "
		.. "SELECT ?, ?, incoming.column2, incoming.column3 FROM (VALUES " .. table.concat(values, ", ") .. ") AS incoming "
		.. "WHERE NOT EXISTS (SELECT 1 FROM spider_checklist WHERE session = ? AND message = ?) "
		.. "ORDER BY incoming.column1"
	return sql, params
end

function M.new(zeron: any)
	local views: State<{ [string]: View }> = ui.state("spider_checklist_views", {} :: { [string]: View })
	local initialized = false
	local queue: { Job } = {}
	local running = false
	local store = {}

	local function put(session: string, view: View)
		local next_views = table.clone(views:peek())
		next_views[session] = view
		views:set(next_views)
	end

	local function request(start: () -> any, success: (any) -> (), failure: () -> ())
		local ok, promise = pcall(start)
		if not ok or not promise then
			failure()
			return
		end
		promise:after(success, failure)
	end

	local function run_next()
		if running or #queue == 0 then return end
		running = true
		local job = table.remove(queue, 1) :: Job
		job(function()
			running = false
			run_next()
		end)
	end

	local function enqueue(job: Job)
		table.insert(queue, job)
		run_next()
	end

	local function with_schema(work: Finish, fail: Finish)
		if initialized then
			work()
			return
		end
		request(function() return zeron.db.exec(CREATE_SQL) end, function()
			initialized = true
			work()
		end, fail)
	end

	local function load_error(session: string)
		local view = views:peek()[session] or EMPTY
		put(session, { items = view.items, ready = view.ready, error = "checklist.load_failed", rev = view.rev + 1 })
	end

	local function read(session: string, done: Finish, fail: Finish)
		request(function() return zeron.db.query(LIST_SQL, { session }) end, function(rows: { any })
			local list: { Item } = {}
			for _, row in rows do
				table.insert(list, {
					id = tonumber(row.id) :: number,
					message = row.message,
					title = row.title,
					body = row.body,
					done = tonumber(row.done) == 1,
				})
			end
			local prev = views:peek()[session] or EMPTY
			put(session, { items = list, ready = true, error = nil, rev = prev.rev + 1 })
			done()
		end, function()
			load_error(session)
			fail()
		end)
	end

	function store.items(session: string): { Item }
		return (views:get()[session] or EMPTY).items
	end

	function store.ready(session: string): boolean
		return (views:get()[session] or EMPTY).ready
	end

	function store.error(session: string): string?
		return (views:get()[session] or EMPTY).error
	end

	function store.rev(session: string): number
		return (views:get()[session] or EMPTY).rev
	end

	function store.load(session: string)
		enqueue(function(finish)
			with_schema(function()
				read(session, finish, finish)
			end, function()
				load_error(session)
				finish()
			end)
		end)
	end

	local function write(session: string, sql: string, params: { any }, error_key: string, done: ((number) -> ())?, on_error: OnError)
		-- Serialize reads and writes so an old response never overwrites newer
		-- progress, and publish the refreshed list before reporting success.
		enqueue(function(finish)
			local function fail(key: string)
				finish()
				if on_error then on_error(key) end
			end
			with_schema(function()
				request(function() return zeron.db.exec(sql, params) end, function(result: any)
					read(session, function()
						finish()
						if done then done(tonumber(result.changes) or 0) end
					end, function() fail("checklist.load_failed") end)
				end, function() fail(error_key) end)
			end, function()
				load_error(session)
				fail("checklist.load_failed")
			end)
		end)
	end

	function store.add(session: string, message: string, items: { DraftItem }, done: ((number) -> ())?, on_error: OnError)
		if #items > MAX_BATCH then
			if on_error then on_error("checklist.too_many") end
			return
		end
		if #items == 0 then
			if done then done(0) end
			return
		end
		local sql, params = insert_batch(session, message, items)
		write(session, sql, params, "checklist.save_failed", done, on_error)
	end

	function store.set_done(session: string, id: number, value: boolean, done: Finish?, on_error: OnError)
		write(session, UPDATE_SQL, { if value then 1 else 0, session, id }, "checklist.save_failed", ignore_count(done), on_error)
	end

	function store.remove(session: string, id: number, done: Finish?, on_error: OnError)
		write(session, DELETE_SQL, { session, id }, "checklist.delete_failed", ignore_count(done), on_error)
	end

	function store.set_many_done(session: string, ids: { number }, value: boolean, done: Finish?, on_error: OnError)
		if #ids == 0 then
			if done then done() end
			return
		end
		local params: { any } = { if value then 1 else 0, session }
		for _, id in ids do table.insert(params, id) end
		local sql = "UPDATE spider_checklist SET done = ? WHERE session = ? AND id IN ("
			.. table.concat(table.create(#ids, "?"), ", ") .. ")"
		write(session, sql, params, "checklist.save_failed", ignore_count(done), on_error)
	end

	function store.remove_many(session: string, ids: { number }, done: Finish?, on_error: OnError)
		if #ids == 0 then
			if done then done() end
			return
		end
		local params: { any } = { session }
		for _, id in ids do table.insert(params, id) end
		local sql = "DELETE FROM spider_checklist WHERE session = ? AND id IN ("
			.. table.concat(table.create(#ids, "?"), ", ") .. ")"
		write(session, sql, params, "checklist.delete_failed", ignore_count(done), on_error)
	end

	function store.clear(session: string, done: Finish?, on_error: OnError)
		write(session, CLEAR_SQL, { session }, "checklist.delete_failed", ignore_count(done), on_error)
	end

	return store
end

return M
