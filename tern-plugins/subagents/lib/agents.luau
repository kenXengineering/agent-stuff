--!strict
-- Reads omp's session store: finds the sessions of a directory, turns scan.sh's digests
-- into agent records, and decides each agent's status from the tail of its transcript.

local util = require("./util")

local M = {}

export type Digest = { kind: string, sub: string, ts: number?, extra: string }

export type Agent = {
	name: string,
	file: string, -- transcript file name inside the session's artifact directory
	size: number,
	agent_kind: string?, -- the agent definition: "task", "explore", ...
	model: string?,
	task: string?,
	tools: number,
	requests: number,
	cost: number,
	tokens: number,
	started: number?, -- epoch ms
	last: number?, -- epoch ms of the newest entry
	status: string, -- Tern's agent statuses: running, idle, parked, aborted, failed, pending
	tool: string?, -- the tool in flight, when running one
	intent: string?,
	tool_started: number?,
}

export type Session = { file: string, id: string, dir: string, title: string }

-- A string value cut out of a JSON document that may be truncated.
local function json_string(s: string, key: string): string?
	local marker = '"' .. key .. '":"'
	local at = string.find(s, marker, 1, true)
	if at == nil then
		return nil
	end
	local i = at + #marker
	local buf: { string } = {}
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" then
			table.insert(buf, string.sub(s, i, i + 1))
			i += 2
		elseif c == '"' then
			return util.unescape(table.concat(buf))
		else
			table.insert(buf, c)
			i += 1
		end
	end
	return util.unescape(table.concat(buf)) -- truncated: what there is
end

M.json_string = json_string

-- Drops private-use glyphs (nerd-font icons omp puts in titles).
local function plain(text: string): string
	local out: { string } = {}
	local ok = pcall(function()
		for _, cp in utf8.codes(text) do
			local private = (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000
			if not private then
				table.insert(out, utf8.char(cp))
			end
		end
	end)
	if not ok then
		return text
	end
	return table.concat(out)
end

-- Where omp keeps sessions: the session-dir override, the agent-dir override, or ~/.omp/agent.
function M.sessions_root(): string?
	local override = tern.getenv("PI_CODING_AGENT_SESSION_DIR")
	if override ~= nil and override ~= "" then
		return override
	end
	local agent_dir = tern.getenv("PI_CODING_AGENT_DIR")
	if agent_dir ~= nil and agent_dir ~= "" then
		return agent_dir .. "/sessions"
	end
	local home = tern.getenv("HOME")
	if home == nil or home == "" then
		return nil
	end
	return home .. "/" .. (tern.getenv("PI_CONFIG_DIR") or ".omp") .. "/agent/sessions"
end

-- omp buckets sessions by working directory: "-<path under home>" or "--<absolute path>--",
-- with separators turned into dashes.
function M.bucket(cwd: string): string?
	local root = M.sessions_root()
	local home = tern.getenv("HOME")
	if root == nil then
		return nil
	end
	local trimmed = string.gsub(cwd, "/+$", "")
	if home ~= nil and home ~= "" and string.sub(trimmed, 1, #home + 1) == home .. "/" then
		local rest = string.sub(trimmed, #home + 2)
		return root .. "/-" .. string.gsub(rest, "/", "-")
	end
	local absolute = string.gsub(string.sub(trimmed, 2), "/", "-")
	return root .. "/--" .. absolute .. "--"
end

-- Output of `scan.sh sessions`: the current time and the directory's main sessions, newest first.
function M.parse_sessions(out: string, bucket: string): ({ Session }, number?)
	local sessions: { Session } = {}
	local now: number? = nil
	for _, line in string.split(out, "\n") do
		local epoch = string.match(line, "^now (%d+)$")
		if epoch ~= nil then
			now = (tonumber(epoch) :: number) * 1000
		else
			local file, head = string.match(line, "^([^\t]+%.jsonl)\t(.*)$")
			if file ~= nil and head ~= nil then
				local stem = util.strip_suffix(file, ".jsonl")
				local title = json_string(head, "title")
				table.insert(sessions, {
					file = file,
					id = string.match(stem, "_(.+)$") or stem,
					dir = bucket .. "/" .. stem,
					title = plain(title or ""),
				})
			end
		end
	end
	return sessions, now
end

-- Output of `scan.sh sizes`: the current time and { [file name]: size }.
function M.parse_sizes(out: string): ({ [string]: number }, number?)
	local sizes: { [string]: number } = {}
	local now: number? = nil
	for _, line in string.split(out, "\n") do
		local epoch = string.match(line, "^now (%d+)$")
		if epoch ~= nil then
			now = (tonumber(epoch) :: number) * 1000
		else
			local size, name = string.match(line, "^(%d+)\t(.+)$")
			if size ~= nil and name ~= nil then
				sizes[name] = tonumber(size) :: number
			end
		end
	end
	return sizes, now
end

-- A line of `session_init`: what the agent is and what it was asked to do.
export type Init = { agent_kind: string?, model: string?, task: string? }

local function blurb(task: string): string
	local text = string.gsub(task, "^%s*Complete assignment thoroughly:%s*", "")
	text = string.gsub(text, "^#+%s*Target%s+", "")
	text = string.gsub(text, "#+%s*", "")
	return util.oneline(text, 200)
end

-- Output of `scan.sh init`: { [file name]: Init }.
function M.parse_inits(out: string): { [string]: Init }
	local inits: { [string]: Init } = {}
	local current: string? = nil
	for _, line in string.split(out, "\n") do
		local name = string.match(line, "^@@\t(.+)$")
		if name ~= nil then
			current = name
			inits[name] = {}
		elseif current ~= nil and string.sub(line, 1, 1) == "{" then
			local ok, entry = pcall(tern.json.decode, line)
			if ok and type(entry) == "table" then
				local task = entry.task
				inits[current] = {
					agent_kind = if type(entry.agent) == "string" then entry.agent else nil,
					model = if type(entry.resolvedModel) == "string" then entry.resolvedModel else nil,
					task = if type(task) == "string" then blurb(task) else nil,
				}
			end
		end
	end
	return inits
end

export type Digested = {
	tools: number,
	requests: number,
	cost: number,
	tokens: number,
	started: number?,
	digests: { Digest },
}

-- Output of `scan.sh agent`: { [file name]: Digested }.
function M.parse_digests(out: string): { [string]: Digested }
	local result: { [string]: Digested } = {}
	local current: Digested? = nil
	for _, line in string.split(out, "\n") do
		local name = string.match(line, "^@@\t(.+)$")
		if name ~= nil then
			current = { tools = 0, requests = 0, cost = 0, tokens = 0, started = nil, digests = {} }
			result[name] = current :: Digested
		elseif current ~= nil then
			local cols = string.split(line, "\t")
			if cols[1] == "stats" then
				current.tools = tonumber(cols[2]) or 0
				current.requests = tonumber(cols[3]) or 0
				current.cost = tonumber(cols[4]) or 0
				current.tokens = tonumber(cols[5]) or 0
				current.started = util.parse_iso(cols[6])
			elseif cols[1] == "e" and #cols >= 4 then
				table.insert(current.digests, {
					kind = cols[2],
					sub = cols[3],
					ts = util.parse_iso(cols[4]),
					extra = cols[5] or "",
				})
			end
		end
	end
	return result
end

-- What a tool call is doing, in a few words: its stated intent, else its main argument.
local function describe(tool: string, args: string): string?
	if tool == "wait" then
		return "Waiting for background jobs"
	end
	for _, key in { "i", "command", "path", "file", "pattern", "query", "url", "description" } do
		local value = json_string(args, key)
		if value ~= nil and value ~= "" then
			return util.oneline(value, 120)
		end
	end
	return nil
end

export type Activity = {
	status: string,
	tool: string?,
	intent: string?,
	tool_started: number?,
	last: number?,
}

-- Decides what an agent is doing from the newest significant entries of its transcript.
-- The file is the only evidence, so this is a reading, not a certainty: omp appends
-- `session_exit` when an agent is disposed, but a hard-killed omp leaves "running" behind
-- (see STALE_MS).
function M.classify(digests: { Digest }): Activity
	local last: number? = nil
	for i = #digests, 1, -1 do
		local d = digests[i]
		if last == nil then
			last = d.ts
		end
		if d.kind == "c" and d.sub == "session_exit" then
			return { status = if d.extra == "signal" then "aborted" else "parked", last = d.ts or last }
		elseif d.kind == "c" and d.sub == "tool_execution_start" then
			local tool, args = string.match(d.extra, "^([^|]*)|(.*)$")
			return {
				status = "running",
				tool = tool,
				intent = describe(tool or "", args or ""),
				tool_started = d.ts,
				last = d.ts,
			}
		elseif d.kind == "m" and d.sub == "assistant" then
			local stop, calls = string.match(d.extra, "^([^|]*)|(.*)$")
			if stop == "toolUse" then
				return { status = "running", tool = string.match(calls or "", "^[^,]+"), last = d.ts }
			elseif stop == "error" then
				return { status = "failed", last = d.ts }
			elseif stop == "aborted" then
				return { status = "aborted", last = d.ts }
			end
			return { status = "idle", last = d.ts }
		elseif d.kind == "m" and (d.sub == "toolResult" or d.sub == "user") then
			return { status = "running", last = d.ts } -- the model is composing its next turn
		end
	end
	return { status = "pending", last = last }
end

-- A "running" agent with no transcript write for this long is shown idle: omp was most
-- likely killed without recording session_exit. Tool calls (wait, long builds) can be
-- quiet for a long time, so this is deliberately generous.
M.STALE_MS = 45 * 60 * 1000

return M
