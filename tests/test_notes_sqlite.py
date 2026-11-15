"""Exercise the production note SQL against SQLite, using temporary databases only.

Run: python -m unittest discover -s tests -v
"""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "notes_store.luau").read_text(encoding="utf-8")
CREATE_SQL = re.search(r"local CREATE_SQL = \[\[(.*?)\]\]", SOURCE, re.S).group(1)


def sql(name):
    return re.search(rf'local {name}_SQL = "([^"\n]+)"', SOURCE).group(1)


class NotesPersistenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "notes.db"
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(CREATE_SQL)

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def add(self, body="随手记", timestamp=100, connection=None):
        db = connection or self.db
        return db.execute(sql("INSERT"), (body, "session-1", "来源对话", "project-1", "message-1", timestamp, timestamp)).lastrowid

    def test_restart_keeps_notes_and_does_not_seed_or_duplicate(self):
        note_id = self.add("第一行\n第二行 🕸")
        self.db.close()
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(CREATE_SQL)
        rows = self.db.execute(sql("LIST")).fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], note_id)
        self.assertEqual(rows[0]["content"], "第一行\n第二行 🕸")

    def test_edit_preserves_source_and_created_at(self):
        note_id = self.add()
        self.db.execute(sql("UPDATE"), ("更新想法", 200, note_id))
        row = self.db.execute(sql("LIST")).fetchone()
        self.assertEqual((row["content"], row["created_at"], row["updated_at"]), ("更新想法", 100, 200))
        self.assertEqual(tuple(row[k] for k in ("session", "session_title", "project", "message")),
                         ("session-1", "来源对话", "project-1", "message-1"))

    def test_bound_content_does_not_execute_sql(self):
        payload = "'); DROP TABLE spider_notes; --\n记得审查这个输入"
        self.add(payload)
        self.assertEqual(self.db.execute(sql("LIST")).fetchone()["content"], payload)

    def test_parallel_inserts_return_their_own_ids(self):
        def insert(index):
            connection = sqlite3.connect(self.path, timeout=10, isolation_level=None)
            try:
                body = f"并行笔记 {index}"
                return self.add(body, connection=connection), body
            finally:
                connection.close()

        with ThreadPoolExecutor(max_workers=4) as pool:
            pairs = list(pool.map(insert, range(16)))
        actual = {r["id"]: r["content"] for r in self.db.execute(sql("LIST"))}
        self.assertEqual(len(actual), 16)
        self.assertEqual(actual, dict(pairs))

    def test_sort_uses_updated_time_then_newest_id(self):
        first = self.add("first", 10)
        second = self.add("second", 10)
        self.assertEqual([r["id"] for r in self.db.execute(sql("LIST"))], [second, first])
        self.db.execute(sql("UPDATE"), ("edited", 20, first))
        self.assertEqual([r["id"] for r in self.db.execute(sql("LIST"))], [first, second])

    def test_delete_affects_only_chosen_note(self):
        first = self.add()
        second = self.add()
        self.db.execute(sql("DELETE"), (first,))
        self.assertEqual([r["id"] for r in self.db.execute(sql("LIST"))], [second])
        self.assertEqual(self.db.execute(sql("UPDATE"), ("gone", 200, first)).rowcount, 0)

    def test_empty_notes_rejected_by_database(self):
        for body in ("", "   "):
            with self.assertRaises(sqlite3.IntegrityError):
                self.add(body)
        self.assertEqual(list(self.db.execute(sql("LIST"))), [])


if __name__ == "__main__":
    unittest.main()
