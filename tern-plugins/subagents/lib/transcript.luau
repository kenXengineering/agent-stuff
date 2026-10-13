--!strict
-- A live view of one omp transcript (JSONL): loads the tail of the file, folds tool calls
-- together with their results, and draws the conversation as native nodes. The same Viewer
-- runs inside the list block (drill-down) and in the standalone transcript block.

local util = require("./util")

local ui = tern.ui

local M = {}

local TAIL_LINES = 400 -- lines read per load; `p` adds this many more
local MAX_ENTRIES = 160 -- entries drawn (the newest)
local MAX_RESULT_CHARS = 6000
local MAX_RESULT_LINES = 120
local POLL_MS = 1500

export type Entry = {
	key: string,
	kind: string, -- user, assistant, thinking, tool, note
	text: string?,
	name: string?,
	args: { [string]: any }?,
	result: string?,
	status: string?, -- tools: running, done, error, cancelled
	started: number?,
	took: number?,
	foldable: boolean,
}

export type Viewer = {
	path: string,
	label: string,
	size: number,
	lines: number, -- tail length asked for
	more: boolean, -- the file has lines before the tail
	entries: { Entry },
	cursor: number,
	follow: boolean,
	expanded: { [string]: boolean },
	loaded: boolean,
	error: string?,
	busy: boolean,
	last_poll: number,
}

function M.new(path: string, label: string): Viewer
	return {
		path = path,
		label = label,
		size = -1,
		lines = TAIL_LINES,
		more = false,
		entries = {},
		cursor = 0,
		follow = true,
		expanded = {},
		loaded = false,
		error = nil,
		busy = false,
		last_poll = -math.huge,
	}
end

local function content_text(content: any): string
	if type(content) == "string" then
		return content
	end
	local parts: { string } = {}
	if type(content) == "table" then
		for _, block in content do
			if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
				table.insert(parts, block.text)
			end
		end
	end
	return table.concat(parts, "\n")
end

local function safe_key(s: string): string
	local out = string.gsub(s, "[^%w_%-]", "_")
	return out
end

-- Folds decoded transcript records into entries. A tool call and its result become one
-- entry; a call with no result yet is running only while nothing came after it.
function M.build(records: { any }): { Entry }
	local entries: { Entry } = {}
	local calls: { [string]: Entry } = {}
	for _, rec in records do
		local id = safe_key(tostring(rec.id or #entries))
		local ts = util.parse_iso(rec.timestamp)
		if rec.type == "message" and type(rec.message) == "table" then
			local msg = rec.message
			if msg.role == "user" then
				local text = content_text(msg.content)
				if text ~= "" then
					table.insert(entries, { key = "u" .. id, kind = "user", text = text, foldable = true, started = ts })
				end
			elseif msg.role == "assistant" and type(msg.content) == "table" then
				for i, block in msg.content do
					if type(block) == "table" then
						if block.type == "text" and type(block.text) == "string" and block.text ~= "" then
							table.insert(entries, { key = "a" .. id .. "_" .. i, kind = "assistant", text = block.text, foldable = false, started = ts })
						elseif block.type == "thinking" and type(block.thinking) == "string" and block.thinking ~= "" then
							table.insert(entries, { key = "k" .. id .. "_" .. i, kind = "thinking", text = block.thinking, foldable = true, started = ts })
						elseif block.type == "toolCall" and type(block.id) == "string" then
							local call: Entry = {
								key = "t" .. safe_key(block.id),
								kind = "tool",
								name = if type(block.name) == "string" then block.name else "tool",
								args = if type(block.arguments) == "table" then block.arguments else {},
								status = "running",
								started = ts,
								foldable = true,
							}
							calls[block.id] = call
							table.insert(entries, call)
						end
					end
				end
				if msg.stopReason == "error" or msg.stopReason == "aborted" then
					local why = if type(msg.errorMessage) == "string" then msg.errorMessage else msg.stopReason
					table.insert(entries, { key = "x" .. id, kind = "note", text = "Turn " .. tostring(msg.stopReason) .. ": " .. tostring(why), foldable = false })
				end
			elseif msg.role == "toolResult" then
				local call = if type(msg.toolCallId) == "string" then calls[msg.toolCallId] else nil
				local text = content_text(msg.content)
				if call ~= nil then
					call.result = text
					call.status = if msg.isError == true then "error" else "done"
					if call.started ~= nil and ts ~= nil then
						call.took = math.max(0, ts - call.started)
					end
				else
					-- The call fell off the front of the tail.
					table.insert(entries, {
						key = "r" .. id,
						kind = "tool",
						name = if type(msg.toolName) == "string" then msg.toolName else "result",
						args = {},
						result = text,
						status = if msg.isError == true then "error" else "done",
						foldable = true,
					})
				end
			end
		elseif rec.type == "custom" and rec.customType == "session_exit" then
			local kind = if type(rec.data) == "table" and type(rec.data.kind) == "string" then rec.data.kind else "normal"
			table.insert(entries, { key = "e" .. id, kind = "note", text = "Session exited (" .. kind .. ")", foldable = false })
		end
	end
	-- A call still waiting for its result is running only if it is the last thing that happened.
	local last = entries[#entries]
	for _, entry in entries do
		if entry.kind == "tool" and entry.status == "running" and entry ~= last then
			entry.status = "cancelled"
		end
	end
	return entries
end

-- Decodes the tail of a transcript. Skips records the view doesn't draw before decoding,
-- so a stray 50 KB session_init line costs nothing.
function M.parse(out: string): { Entry }
	local records: { any } = {}
	for _, line in string.split(out, "\n") do
		local head = string.sub(line, 1, 17)
		if head == '{"type":"message"' or string.sub(line, 1, 16) == '{"type":"custom"' then
			local ok, rec = pcall(tern.json.decode, line)
			if ok and type(rec) == "table" then
				table.insert(records, rec)
			end
		end
	end
	return M.build(records)
end

-- Reloads when the file grew (or on `force`). `cb(changed)` runs on the host worker.
function M.poll(v: Viewer, force: boolean, cb: (changed: boolean) -> ())
	if v.busy then
		return
	end
	v.busy = true
	v.last_poll = tern.now()
	util.scan({ "size", v.path }, function(out, err)
		if out == nil then
			v.busy = false
			v.error = err
			cb(true)
			return
		end
		local size = tonumber(string.match(out, "%d+") or "") or -1
		if size == v.size and not force then
			v.busy = false
			cb(false)
			return
		end
		util.scan({ "tail", v.path, tostring(v.lines) }, function(tail, tail_err)
			v.busy = false
			if tail == nil then
				v.error = tail_err
				cb(true)
				return
			end
			v.error = nil
			v.size = size
			v.loaded = true
			local count = select(2, string.gsub(tail, "\n", ""))
			v.more = count >= v.lines
			local entries = M.parse(tail)
			if #entries > MAX_ENTRIES then
				local trimmed: { Entry } = {}
				for i = #entries - MAX_ENTRIES + 1, #entries do
					table.insert(trimmed, entries[i])
				end
				entries = trimmed
			end
			v.entries = entries
			if v.follow or v.cursor > #entries then
				v.cursor = #entries
			end
			cb(true)
		end)
	end)
end

function M.due(v: Viewer): boolean
	return not v.busy and tern.now() - v.last_poll >= POLL_MS
end

local TARGET_KIND: { [string]: string } = {
	bash = "command",
	read = "path",
	write = "path",
	edit = "path",
	ast_edit = "path",
	grep = "pattern",
	glob = "pattern",
	find = "pattern",
	web_search = "query",
}

-- The one argument worth showing on a tool's head line.
local function target_of(entry: Entry): (string?, string)
	local args = entry.args or {}
	local name = entry.name or ""
	local function str(key: string): string?
		local v = args[key]
		return if type(v) == "string" and v ~= "" then v else nil
	end
	local primary: string? = nil
	if name == "bash" then
		primary = str("command")
	elseif name == "read" or name == "write" then
		primary = str("path") or str("file")
	elseif name == "edit" then
		local input = str("input")
		primary = str("path") or (if input ~= nil then string.match(input, "%[([^%]#]+)") else nil)
	elseif name == "grep" or name == "glob" or name == "find" then
		primary = str("pattern")
	elseif name == "web_search" then
		primary = str("query")
	end
	if primary ~= nil then
		return util.oneline(primary, 240), TARGET_KIND[name] or "text"
	end
	local intent = str("i") or str("description") or str("path") or str("command")
	return (if intent ~= nil then util.oneline(intent, 240) else nil), "text"
end

local function clip(text: string): string
	local lines = string.split(text, "\n")
	local hidden = 0
	if #lines > MAX_RESULT_LINES then
		hidden = #lines - MAX_RESULT_LINES
		local kept: { string } = {}
		for i = 1, MAX_RESULT_LINES do
			kept[i] = lines[i]
		end
		text = table.concat(kept, "\n")
	end
	if #text > MAX_RESULT_CHARS then
		text = string.sub(text, 1, MAX_RESULT_CHARS)
		hidden = math.max(hidden, 1)
	end
	if hidden > 0 then
		text ..= "\n… output truncated"
	end
	return text
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function entry_node(v: Viewer, entry: Entry, index: number): Node
	local marked = if index == v.cursor then "pick" else nil
	local open = v.expanded[entry.key] == true
	local click = { click = "pick=" .. entry.key }
	if entry.kind == "assistant" then
		return with(ui.node("md", { text = entry.text }), { key = entry.key, mark = marked, actions = click })
	elseif entry.kind == "user" then
		local card = ui.card({ ui.span("Prompt", "strong"), ui.span(" " .. util.oneline(entry.text or "", 100), "muted") }, {
			ui.node("md", { text = entry.text }),
		})
		return with(card, { key = entry.key, tone = "user", collapsible = true, collapsed = not open, mark = marked, actions = click })
	elseif entry.kind == "thinking" then
		local section = ui.node("section", { head = { ui.span("Thinking", "muted em"), ui.span(" " .. util.oneline(entry.text or "", 100), "dim") } }, {
			ui.node("md", { text = entry.text }),
		})
		return with(section, { key = entry.key, collapsible = true, collapsed = not open, mark = marked, actions = click })
	elseif entry.kind == "tool" then
		local target, kind = target_of(entry)
		local body: { Node } = {}
		if entry.result ~= nil and entry.result ~= "" then
			table.insert(body, ui.node("ansi", { text = clip(entry.result) }))
		end
		local name = entry.name or "tool"
		return ui.node("tool", {
			key = entry.key,
			name = name,
			title = name,
			target = target,
			targetKind = kind,
			status = entry.status,
			took = entry.took,
			collapsible = #body > 0,
			collapsed = not open,
			preview = { lines = 6 },
			mark = marked,
			actions = click,
		}, body)
	end
	return with(ui.text({ ui.span(entry.text or "", "muted em") }), { key = entry.key, mark = marked })
end

-- The conversation: header line, then the entries (keyed, so folds and scroll survive updates).
function M.main(v: Viewer, header: { Node }?): Node
	local children: { Node } = {}
	local lead: { Node } = header or {}
	for _, h in lead do
		table.insert(children, h)
	end
	if v.error ~= nil then
		table.insert(children, ui.text({ ui.span("Cannot read transcript: ", "error"), ui.span(v.error, "muted") }))
	elseif not v.loaded then
		table.insert(children, ui.node("spinner", { style = "dots", label = { ui.span("Loading transcript", "muted") } }))
	elseif #v.entries == 0 then
		table.insert(children, ui.text({ ui.span("Nothing in this transcript yet", "muted") }))
	end
	local list: { Node } = {}
	if v.more and v.loaded then
		table.insert(list, with(ui.text({ ui.span("Earlier history not shown. Press p to load more.", "muted em") }), { key = "more" }))
	end
	for i, entry in v.entries do
		table.insert(list, entry_node(v, entry, i))
	end
	table.insert(children, ui.col(list))
	with(children[#children] :: Node, { key = "entries" })
	return ui.col(children)
end

function M.entry_id(v: Viewer, index: number): string?
	local entry = v.entries[index]
	if entry == nil then
		return nil
	end
	return "main.entries." .. entry.key
end

-- Scrolls the view to the cursor entry. Safe to call right after a state change: the
-- frame is sent after the render the same handler queued... except for brand-new nodes,
-- which is why `follow_soon` waits a beat.
function M.reveal(v: Viewer, cx: BlockCx, how: string)
	local id = M.entry_id(v, v.cursor)
	if id ~= nil then
		cx:frame({ { "reveal", id, how } })
	end
end

function M.follow_soon(v: Viewer, cx: BlockCx)
	tern.timer(60, function()
		if v.follow then
			M.reveal(v, cx, "end")
		end
	end)
end

function M.hints(v: Viewer, back: string?): Node
	local spans: { Span } = {}
	if back ~= nil then
		table.insert(spans, ui.span(back, "accent"))
		table.insert(spans, ui.span("  "))
	end
	table.insert(spans, ui.span("j/k move · space fold · G follow" .. (if v.follow then " (on)" else "") .. " · g top · p more · r reload", "muted"))
	return ui.row({ ui.text(spans) })
end

-- Handles a key for the viewer. Returns true when state changed, false when ignored.
function M.key(v: Viewer, key: Key, cx: BlockCx): boolean
	local n = #v.entries
	local name = key.name
	if key.ctrl or key.alt or key.meta then
		return false
	end
	if name == "j" or name == "down" then
		v.cursor = math.min(v.cursor + 1, n)
	elseif name == "k" or name == "up" then
		v.cursor = math.max(v.cursor - 1, 1)
	elseif name == "page_down" then
		v.cursor = math.min(v.cursor + 8, n)
	elseif name == "page_up" then
		v.cursor = math.max(v.cursor - 8, 1)
	elseif name == "g" or name == "home" then
		v.cursor = 1
	elseif key.text == "G" or name == "end" then
		v.cursor = n
	elseif name == "space" or name == "enter" then
		local entry = v.entries[v.cursor]
		if entry ~= nil and entry.foldable then
			v.expanded[entry.key] = not v.expanded[entry.key]
		end
		return true
	elseif name == "p" then
		v.lines += TAIL_LINES
		M.poll(v, true, function()
			cx:render()
		end)
		return false
	elseif name == "r" then
		M.poll(v, true, function()
			cx:render()
		end)
		return false
	else
		return false
	end
	v.follow = v.cursor >= n
	M.reveal(v, cx, if v.follow then "end" else "nearest")
	return true
end

-- A click on an entry moves the cursor there.
function M.pick(v: Viewer, key: string)
	for i, entry in v.entries do
		if entry.key == key then
			v.cursor = i
			v.follow = i >= #v.entries
			return
		end
	end
end

return M
