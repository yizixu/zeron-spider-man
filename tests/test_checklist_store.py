"""Exercise the checklist's production statements and host boundary."""

import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
local value = {}
local ui = { state = function()
    return { get = function() return value end, peek = function() return value end,
        set = function(_, nextValue) value = nextValue end }
end }
local function loadStore()
-- INJECT store
end
local pending = {}
local function request(sql, params)
    return { after = function(_, success, failure)
        table.insert(pending, { sql = sql, params = params or {}, success = success, failure = failure })
    end }
end
local store = loadStore().new({ db = { exec = request, query = request } })
local function hex(value)
    return (string.gsub(value, ".", function(byte) return string.format("%02x", string.byte(byte)) end))
end
local function answer(label, result)
    assert(#pending == 1, "checklist database work should not overlap")
    local req = table.remove(pending, 1)
    local fields = { label, hex(req.sql) }
    for _, param in req.params do
        table.insert(fields, type(param) == "number" and `n{param}` or `s{hex(param)}`)
    end
    print(table.concat(fields, "\t"))
    if result then req.success(result) else req.failure() end
end

local parsed = {
    { title = "先修这里", body = "'); DROP TABLE spider_checklist; --\n真实原文 🕸" },
    { title = "Second issue", body = "Second body" },
}
local saved = false
store.add("a", "m", parsed, function(count)
    assert(count == 2 and store.ready("a") and store.items("a")[1].title == parsed[1].title)
    saved = true
end, error)
store.load("b")
answer("schema", {})
answer("insert_a", { changes = 2 })
assert(not saved and not store.ready("a"), "success must wait for the refreshed list")
local row = { id = 1, message = "m", title = parsed[1].title, body = parsed[1].body, done = 0 }
answer("list_a", { row })
assert(saved and store.rev("a") == 1 and not store.items("a")[1].done)
answer("failed_list_b", nil)
assert(not store.ready("b") and store.error("b") == "checklist.load_failed")
store.load("b")
answer("list_b", {})
assert(store.ready("b") and not store.error("b") and #store.items("b") == 0)

store.add("b", "m", parsed)
answer("insert_b", { changes = 2 })
answer("after_insert_b", { row })
store.set_done("a", 1, true)
answer("check_a", { changes = 1 })
local checked = table.clone(row)
checked.done = 1
answer("after_check_a", { checked })
assert(store.items("a")[1].done and store.rev("a") == 2 and not store.items("b")[1].done)
store.set_done("b", 1, true)
answer("check_other_session", { changes = 0 })
answer("after_check_other_session", { row })
store.remove("a", 1)
answer("delete_a", { changes = 1 })
answer("after_delete_a", {})
store.clear("a")
answer("clear_a", { changes = 1 })
answer("after_clear_a", {})
assert(#store.items("a") == 0 and #store.items("b") == 1)

local overflow
store.add("a", "large", table.create(101, parsed[1]), nil, function(key) overflow = key end)
assert(overflow == "checklist.too_many" and #pending == 0, "oversized import does not reach SQLite")
'''

BATCH_HARNESS = HARNESS.split("local parsed =", 1)[0] + r'''
local empty = 0
store.set_many_done("a", {}, true, function() empty += 1 end, error)
store.remove_many("a", {}, function() empty += 1 end, error)
assert(empty == 2 and #pending == 0, "empty selections do not query or create the database")

local one = { id = 1, message = "m", title = "First", body = "First body", done = 1 }
local three = { id = 3, message = "m", title = "Third", body = "Third body", done = 1 }
local completed = false
store.set_many_done("a", { 1, 3, 4 }, true, function()
    assert(store.items("a")[1].done and store.rev("a") == 1)
    completed = true
end, error)
answer("schema", {})
answer("complete_many", { changes = 2 })
assert(not completed and #pending == 1, "batch completion must await exactly one readback")
answer("after_complete_many", { one, three })
assert(completed and #pending == 0, "batch success does not schedule extra reads")

store.set_many_done("a", { 1, 3 }, false)
answer("reopen_many", { changes = 2 })
one.done, three.done = 0, 0
answer("after_reopen_many", { one, three })
assert(not store.items("a")[1].done and store.rev("a") == 2)

local deleted = false
store.remove_many("a", { 1, 3, 4 }, function()
    assert(#store.items("a") == 0 and store.rev("a") == 3)
    deleted = true
end, error)
answer("remove_many", { changes = 2 })
assert(not deleted and #pending == 1, "batch deletion must await exactly one readback")
answer("after_remove_many", {})
assert(deleted and #pending == 0)

local failed
store.set_many_done("a", { 2 }, true, function() error("failed write must not succeed") end,
    function(key) failed = key end)
answer("failed_complete_many", nil)
assert(failed == "checklist.save_failed" and #pending == 0, "failed batch does not claim success or reload")
store.remove_many("a", { 2 }, nil, function(key) failed = key end)
answer("failed_remove_many", nil)
assert(failed == "checklist.delete_failed" and #pending == 0)
'''


class ChecklistStoreTests(unittest.TestCase):
    def test_batch_progress_and_delete_are_scoped_and_atomic(self):
        executable = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not executable:
            self.skipTest("Set LUAU_BIN to a Luau CLI executable")
        source = (ROOT / "checklist_store.luau").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory(prefix="spider-checklist-batch-") as temp:
            script = Path(temp) / "runtime.luau"
            script.write_text(BATCH_HARNESS.replace("-- INJECT store", source), encoding="utf-8")
            result = subprocess.run(
                [executable, str(script)], capture_output=True, encoding="utf-8", timeout=20
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            commands = {}
            for line in result.stdout.splitlines():
                label, sql, *params = line.split("\t")
                commands[label] = (
                    bytes.fromhex(sql).decode("utf-8"),
                    tuple(int(p[1:]) if p.startswith("n") else bytes.fromhex(p[1:]).decode("utf-8") for p in params),
                )

            with sqlite3.connect(":memory:") as conn:
                conn.executescript(commands["schema"][0])
                conn.executemany(
                    "INSERT INTO spider_checklist (id, session, message, title, body) VALUES (?, ?, ?, ?, ?)",
                    [(1, "a", "m", "First", "body 1"), (2, "a", "m", "Second", "body 2"),
                     (3, "a", "m", "Third", "body 3"), (4, "b", "m", "Other session", "body 4")],
                )
                complete_sql, complete_params = commands["complete_many"]
                self.assertIn("id IN (?, ?, ?)", complete_sql)
                self.assertEqual(complete_params, (1, "a", 1, 3, 4))
                self.assertEqual(conn.execute(complete_sql, complete_params).rowcount, 2)
                self.assertEqual(conn.execute("SELECT id, done FROM spider_checklist ORDER BY id").fetchall(),
                                 [(1, 1), (2, 0), (3, 1), (4, 0)])
                self.assertEqual(conn.execute(*commands["reopen_many"]).rowcount, 2)
                self.assertEqual(conn.execute("SELECT done FROM spider_checklist ORDER BY id").fetchall(),
                                 [(0,), (0,), (0,), (0,)])
                self.assertEqual(conn.execute(*commands["remove_many"]).rowcount, 2)
                self.assertEqual(conn.execute("SELECT id, session FROM spider_checklist ORDER BY id").fetchall(),
                                 [(2, "a"), (4, "b")])

    def test_atomic_import_and_session_progress(self):
        executable = os.environ.get("LUAU_BIN") or shutil.which("luau")
        if not executable:
            self.skipTest("Set LUAU_BIN to a Luau CLI executable")
        source = (ROOT / "checklist_store.luau").read_text(encoding="utf-8")

        with tempfile.TemporaryDirectory(prefix="spider-checklist-") as temp:
            script = Path(temp) / "runtime.luau"
            script.write_text(HARNESS.replace("-- INJECT store", source), encoding="utf-8")
            result = subprocess.run(
                [executable, str(script)], capture_output=True, encoding="utf-8", timeout=20
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            commands = {}
            for line in result.stdout.splitlines():
                label, sql, *params = line.split("\t")
                commands[label] = (
                    bytes.fromhex(sql).decode("utf-8"),
                    tuple(int(p[1:]) if p.startswith("n") else bytes.fromhex(p[1:]).decode("utf-8") for p in params),
                )

            path = Path(temp) / "checklist.db"
            conn = sqlite3.connect(path, isolation_level=None)
            try:
                conn.executescript(commands["schema"][0])

                def import_a(_):
                    other = sqlite3.connect(path, isolation_level=None, timeout=10)
                    try:
                        return other.execute(*commands["insert_a"]).rowcount
                    finally:
                        other.close()

                with ThreadPoolExecutor(max_workers=4) as pool:
                    self.assertEqual(sorted(pool.map(import_a, range(4))), [0, 0, 0, 2])

                rows = conn.execute(*commands["list_a"]).fetchall()
                self.assertEqual([row[2] for row in rows], ["先修这里", "Second issue"])
                self.assertEqual(rows[0][3], "'); DROP TABLE spider_checklist; --\n真实原文 🕸")
                self.assertEqual(conn.execute(*commands["list_b"]).fetchall(), [])
                self.assertEqual(conn.execute(*commands["insert_b"]).rowcount, 2)
                self.assertEqual(conn.execute(*commands["check_other_session"]).rowcount, 0)
                conn.execute(*commands["check_a"])
                self.assertEqual([row[4] for row in conn.execute(*commands["list_a"])], [1, 0])
                self.assertEqual(import_a(None), 0)

                conn.execute(*commands["delete_a"])
                self.assertEqual(import_a(None), 0, "do not restore individually removed rows")
                self.assertEqual(len(conn.execute(*commands["list_a"]).fetchall()), 1)
                conn.execute(*commands["clear_a"])
                self.assertEqual(import_a(None), 2, "a fully removed reply can be imported again")
                self.assertEqual([row[4] for row in conn.execute(*commands["list_b"])], [0, 0])
            finally:
                conn.close()


if __name__ == "__main__":
    unittest.main()
