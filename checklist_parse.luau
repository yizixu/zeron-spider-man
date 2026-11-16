--!strict
-- Extract one explicit checklist from a reply. Keep nested lists and code
-- in their parent item, and favor numbered issues over secondary bullets.
local M = {}

export type Item = { title: string, body: string }
type Draft = { title: string, lines: { string } }
type Group = { numbered: boolean, level: number?, indent: number, items: { Draft } }

local function trim(text: string): string
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function ordered(line: string): string?
	local body = string.match(line, "^%d+[.)]%s+(%S.*)$")
		or string.match(line, "^%d+、%s*(%S.*)$")
		or string.match(line, "^%d+）%s*(%S.*)$")
		or string.match(line, "^（%d+）%s*(%S.*)$")
	if body then return body end
	local numeral, rest = string.match(line, "^(.-)、%s*(%S.*)$")
	if numeral and numeral ~= "" then
		for _, digit in { "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百" } do
			numeral = string.gsub(numeral, digit, "")
		end
		if numeral == "" then return rest end
	end
	return nil
end

local function numbered_heading(line: string): string?
	line = string.match(line, "^%*%*(.-)%*%*%s*$") or string.match(line, "^__(.-)__%s*$") or line
	local body = ordered(line)
	if body then return body end
	-- A labeled heading such as “Bug #2: …” or “问题 2：…”.
	local label, tail = string.match(line, "^(.-)%s*#?%d+%s*(.*)$")
	if not label or not tail then return nil end
	label = string.lower(trim(label))
	if label ~= "bug" and label ~= "issue" and label ~= "problem" and label ~= "问题" and label ~= "缺陷" then
		return nil
	end
	return string.match(tail, "^:%s*(%S.*)$")
		or string.match(tail, "^：%s*(%S.*)$")
		or string.match(tail, "^[-.]%s+(%S.*)$")
end

local function headline(text: string): string
	local first = string.match(text, "^%*%*(.-)%*%*") or string.match(text, "^__(.-)__") or text
	first = trim((string.gsub(string.gsub(first, "%[([^%]]+)%]%([^%)]+%)", "%1"), "`+", "")))
	if first == "" then first = trim(text) end
	local length = utf8.len(first)
	if length and length > 88 then
		local cutoff = utf8.offset(first, 89)
		if cutoff then return trim(string.sub(first, 1, cutoff - 1)) .. "…" end
	end
	return first
end

function M.parse(text: string): { Item }
	local lines = string.gsub(string.gsub(text, "\r\n", "\n"), "\r", "\n")
	local group: Group? = nil
	local best: Group? = nil
	local item: Draft? = nil
	local paragraph_open = false
	local fence: string? = nil
	local fence_item: Draft? = nil

	local function finish_group()
		local candidate = group
		if candidate and #candidate.items >= 2 then
			if not best or (candidate.numbered and not best.numbered)
				or (candidate.numbered == best.numbered and #candidate.items > #best.items) then
				best = candidate
			end
		end
		group = nil
		item = nil
		paragraph_open = false
	end

	local function add(body: string, numbered: boolean, level: number?, indent: number)
		if group and (group.level ~= level or group.numbered ~= numbered or group.indent ~= indent) then
			finish_group()
		end
		local target: Group = group or { numbered = numbered, level = level, indent = indent, items = {} }
		group = target
		local first = (string.gsub(body, "^%[[ xX]%]%s+", ""))
		local draft = { title = headline(first), lines = { first } }
		table.insert(target.items, draft)
		item = draft
		paragraph_open = true
	end

	for raw in string.gmatch(lines .. "\n", "(.-)\n") do
		local indent_text, line = string.match(raw, "^([ \t]*)(.*)$")
		local indent = #(indent_text or "")
		if indent_text and string.find(indent_text, "\t", 1, true) then indent = 4 end
		line = line or ""
		local marks = string.match(line, "^`+") or string.match(line, "^~+")
		if fence then
			if fence_item then table.insert(fence_item.lines, raw) end
			if marks and #marks >= #fence and string.sub(marks, 1, 1) == string.sub(fence, 1, 1)
				and not string.find(string.sub(line, #marks + 1), "%S") then
				fence, fence_item = nil, nil
			end
			continue
		elseif marks and #marks >= 3 and (indent <= 3 or (group and indent > group.indent)) then
			if group and not group.level and indent <= group.indent then finish_group() end
			fence, fence_item = marks, item
			paragraph_open = false
			if fence_item then table.insert(fence_item.lines, raw) end
			continue
		end

		if not string.find(line, "%S") then
			if item then table.insert(item.lines, raw) end
			paragraph_open = false
			continue
		end
		-- Only a top-level sibling can start another item. For heading-based
		-- issues, ordinary lists and deeper headings are part of the issue.
		if indent <= 3 and (not group or indent <= group.indent) then
			local hashes, heading = string.match(line, "^(#+)%s+(%S.*)$")
			local level = if hashes and #hashes <= 6 then #hashes else nil
			local numbered = if level and heading then numbered_heading((string.gsub(heading, "%s+#+%s*$", ""))) else nil
			if not level and (not group or not group.level or group.level == 7) then
				local bold = string.match(line, "^%*%*(.-)%*%*%s*$")
				numbered = if bold then numbered_heading(bold) else nil
				if numbered then level = 7 end
			end
			if level and (not group or not group.level or level <= group.level) then
				if numbered then add(numbered, true, level, indent) else finish_group() end
				continue
			end
			local rule = string.gsub(line, "%s+", "")
			if #rule >= 3 and (string.match(rule, "^%-+$") or string.match(rule, "^%*+$") or string.match(rule, "^_+$")) then
				finish_group()
				continue
			end
			if not group or not group.level then
				local order = ordered(line)
				local bullet = string.match(line, "^[-+*]%s+(%S.*)$")
				if order or bullet then
					add((order or bullet) :: string, order ~= nil, nil, indent)
				elseif item and paragraph_open and group and indent == group.indent and not string.match(line, "^>") then
					-- Markdown paragraphs in list items may continue without
					-- indentation until a blank line or another block starts.
					table.insert(item.lines, raw)
				else
					finish_group()
				end
				continue
			end
		end
		if item then table.insert(item.lines, raw) end
	end
	finish_group()

	local output: { Item } = {}
	if best then
		for _, draft in best.items do
			table.insert(output, { title = draft.title, body = trim(table.concat(draft.lines, "\n")) })
		end
	end
	return output
end

return M
