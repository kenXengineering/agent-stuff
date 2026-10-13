--!strict
-- Host half. Two blocks:
--
--   subagents.list        the sub-agents of the omp session that runs in this block's
--                         directory, with live status. Click (or Enter) opens one's
--                         transcript in this same block; Esc, or Left twice, returns to
--                         the list. Cmd+click (Cmd+Enter) opens the transcript in a
--                         subagents.transcript block below instead.
--   subagents.transcript  one transcript, live, as its own block.
--
-- Everything comes from omp's own session files; see lib/agents.luau and scripts/scan.sh.

local ui = tern.ui
local util = require("./lib/util")
local agents = require("./lib/agents")
local transcript = require("./lib/transcript")

type Agent = agents.Agent
type Session = agents.Session
type Viewer = transcript.Viewer

local TICK_MS = 1500 -- loop period; the agent scan runs every REFRESH_EVERY ticks
local REFRESH_EVERY = 2
local SESSIONS_EVERY = 6 -- re-list the directory's sessions this often (in ticks)
local DOUBLE_LEFT_MS = 700

-- Whether pane `pane` still runs (a block that ended is gone from the list).
local function running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function safe(s: string): string
	local out = string.gsub(s, "[^%w_%-]", "_")
	return out
end

local function has(list: any, value: string): boolean
	if type(list) == "table" then
		for _, v in list do
			if v == value then
				return true
			end
		end
	end
	return false
end

------------------------------------------------------------------------------------------
-- subagents.list
------------------------------------------------------------------------------------------

type ListState = {
	cwd: string?,
	bucket: string?,
	sessions: { Session },
	pinned: string?, -- session id chosen with `s`; nil follows the newest
	session: Session?,
	agents: { [string]: Agent },
	sizes: { [string]: number },
	now: number, -- epoch ms at the last scan
	mono: number, -- tern.now() at the last scan
	ticks: number,
	busy: boolean,
	stopped: boolean,
	loaded: boolean,
	error: string?,
	sel: string?, -- file name of the selected agent
	viewing: string?, -- file name of the agent whose transcript fills the block
	viewer: Viewer?,
	restore: string?, -- transcript to reopen once the session is known
	left_at: number,
}

local function wall(state: ListState): number
	return state.now + (tern.now() - state.mono)
end

-- Shown status: a "running" agent that has been silent for STALE_MS reads as idle.
local function shown(state: ListState, a: Agent): string
	if a.status == "running" and a.last ~= nil and wall(state) - a.last > agents.STALE_MS then
		return "idle"
	end
	return a.status
end

local RANK: { [string]: number } = { running = 1, pending = 2, idle = 3, failed = 4, aborted = 4, parked = 5 }

local function ordered(state: ListState): { Agent }
	local list: { Agent } = {}
	for _, a in state.agents do
		table.insert(list, a)
	end
	table.sort(list, function(x, y)
		local rx, ry = RANK[shown(state, x)] or 9, RANK[shown(state, y)] or 9
		if rx ~= ry then
			return rx < ry
		end
		local lx, ly = x.last or 0, y.last or 0
		if lx ~= ly then
			return lx > ly
		end
		return x.name < y.name
	end)
	return list
end

local function merge(state: ListState, name: string, d: agents.Digested, init: agents.Init?)
	local a: Agent = state.agents[name]
		or {
			name = util.strip_suffix(name, ".jsonl"),
			file = name,
			size = 0,
			tools = 0,
			requests = 0,
			cost = 0,
			tokens = 0,
			status = "pending",
		}
	if init ~= nil then
		a.agent_kind, a.model, a.task = init.agent_kind, init.model, init.task
	end
	local activity = agents.classify(d.digests)
	a.tools, a.requests, a.cost, a.tokens = d.tools, d.requests, d.cost, d.tokens
	a.started = d.started or a.started
	a.status, a.tool, a.intent, a.tool_started, a.last = activity.status, activity.tool, activity.intent, activity.tool_started, activity.last
	a.size = state.sizes[name] or a.size
	state.agents[name] = a
end

local function chunks(names: { string }, n: number): { { string } }
	local out: { { string } } = {}
	for i = 1, #names, n do
		local chunk: { string } = {}
		for j = i, math.min(i + n - 1, #names) do
			table.insert(chunk, names[j])
		end
		table.insert(out, chunk)
	end
	return out
end

local open_here: (state: ListState, file: string, cx: BlockCx) -> ()

-- Looks at the session store and updates state; `done` runs when the scan is finished.
local function scan(state: ListState, cx: BlockCx, done: () -> ())
	local function fail(err: string?)
		state.error = err or "scan failed"
		done()
	end

	local function scan_agents()
		local session = state.session
		if session == nil or not tern.fs.exists(session.dir) then
			state.agents, state.sizes = {}, {}
			done()
			return
		end
		util.scan({ "sizes", session.dir }, function(out, err)
			if out == nil then
				return fail(err)
			end
			local sizes, now = agents.parse_sizes(out)
			if now ~= nil then
				state.now, state.mono = now, tern.now()
			end
			local changed: { string } = {}
			local fresh: { string } = {}
			for name, size in sizes do
				if state.sizes[name] ~= size or state.agents[name] == nil then
					table.insert(changed, name)
				end
				if state.agents[name] == nil then
					table.insert(fresh, name)
				end
			end
			for name in state.agents do
				if sizes[name] == nil then
					state.agents[name] = nil
				end
			end
			state.sizes = sizes
			state.error = nil
			if #changed == 0 then
				done()
				return
			end
			table.sort(changed)
			local pending = 0
			local inits: { [string]: agents.Init } = {}
			local digests: { [string]: agents.Digested } = {}
			local function joined()
				pending -= 1
				if pending > 0 then
					return
				end
				for name, d in digests do
					merge(state, name, d, inits[name])
				end
				if state.restore ~= nil and state.agents[state.restore] ~= nil then
					local file = state.restore
					state.restore = nil
					open_here(state, file, cx)
				end
				done()
			end
			for _, group in chunks(fresh, 40) do
				pending += 1
				local args = { "init", session.dir }
				for _, n in group do
					table.insert(args, n)
				end
				util.scan(args, function(init_out)
					if init_out ~= nil then
						for name, init in agents.parse_inits(init_out) do
							inits[name] = init
						end
					end
					joined()
				end)
			end
			for _, group in chunks(changed, 40) do
				pending += 1
				local args = { "agent", session.dir }
				for _, n in group do
					table.insert(args, n)
				end
				util.scan(args, function(agent_out, agent_err)
					if agent_out ~= nil then
						for name, d in agents.parse_digests(agent_out) do
							digests[name] = d
						end
					else
						state.error = agent_err
					end
					joined()
				end)
			end
		end)
	end

	local bucket = state.bucket
	if bucket == nil then
		state.error = "Cannot locate omp's session directory (no HOME)"
		done()
		return
	end
	if state.ticks % SESSIONS_EVERY ~= 0 and state.session ~= nil then
		scan_agents()
		return
	end
	util.scan({ "sessions", bucket }, function(out, err)
		if out == nil then
			return fail(err)
		end
		local sessions, now = agents.parse_sessions(out, bucket)
		if now ~= nil then
			state.now, state.mono = now, tern.now()
		end
		state.sessions = sessions
		local pick: Session? = sessions[1]
		if state.pinned ~= nil then
			for _, s in sessions do
				if s.id == state.pinned then
					pick = s
				end
			end
		end
		local previous = state.session
		if previous ~= nil and (pick == nil or previous.id ~= pick.id) then
			state.agents, state.sizes = {}, {}
			state.sel = nil
			state.viewing, state.viewer = nil, nil
		end
		state.session = pick
		scan_agents()
	end)
end

local function title_of(state: ListState): string
	local n = 0
	for _, a in state.agents do
		if shown(state, a) == "running" then
			n += 1
		end
	end
	if state.viewing ~= nil then
		return util.strip_suffix(state.viewing, ".jsonl")
	end
	return if n > 0 then "Subagents (" .. n .. " running)" else "Subagents"
end

function open_here(state: ListState, file: string, cx: BlockCx)
	local session = state.session
	if session == nil then
		return
	end
	local a = state.agents[file]
	local v = transcript.new(session.dir .. "/" .. file, if a ~= nil then a.name else file)
	state.viewing, state.viewer, state.sel = file, v, file
	transcript.poll(v, true, function()
		cx:render()
		transcript.follow_soon(v, cx)
	end)
end

local function close_view(state: ListState)
	state.viewing, state.viewer = nil, nil
end

local function open_below(state: ListState, file: string, cx: BlockCx)
	local session = state.session
	if session == nil then
		return
	end
	local a = state.agents[file]
	local label = if a ~= nil then a.name else util.strip_suffix(file, ".jsonl")
	cx:open("tern-subagents://transcript?path=" .. util.encode(session.dir .. "/" .. file) .. "&label=" .. util.encode(label))
end

local function agent_node(state: ListState, a: Agent): Node
	local status = shown(state, a)
	local now = wall(state)
	local stats: { [string]: any } = { tools = a.tools, requests = a.requests, cost = a.cost, tokens = a.tokens }
	if a.started ~= nil then
		if status == "running" then
			stats.age = math.max(0, now - a.started)
		elseif a.last ~= nil then
			stats.took = math.max(0, a.last - a.started)
		end
	end
	local tool: { [string]: any }? = nil
	if status == "running" and a.tool ~= nil then
		tool = {
			name = a.tool,
			intent = a.intent or a.tool,
			age = if a.tool_started ~= nil then math.max(0, now - a.tool_started) else nil,
		}
	end
	local task = a.task
	if status == "idle" and a.status == "running" and a.last ~= nil then
		task = "No transcript activity for " .. util.duration(now - a.last) .. " — " .. (task or "")
	end
	return ui.node("agent", {
		key = "a_" .. safe(a.name),
		name = a.name,
		agent = a.agent_kind,
		task = task,
		status = status,
		model = a.model,
		stats = stats,
		tool = tool,
		mark = if state.sel == a.file then "pick" else nil,
		actions = { click = "open=" .. a.file },
	})
end

local function counts(state: ListState): (number, number)
	local running_n, total = 0, 0
	for _, a in state.agents do
		total += 1
		if shown(state, a) == "running" then
			running_n += 1
		end
	end
	return running_n, total
end

local function list_view(state: ListState): BlockView
	local running_n, total = counts(state)
	local session = state.session
	local head: { Span } = { ui.span("Subagents", "strong") }
	if session ~= nil and session.title ~= "" then
		table.insert(head, ui.span("  " .. session.title, "muted"))
	end
	local header = ui.row({
		ui.text(head),
		ui.badge(running_n .. " running", if running_n > 0 then "accent" else "neutral"),
		ui.badge(total .. " total", "neutral"),
	})
	local body: { Node } = {}
	if state.error ~= nil then
		table.insert(body, ui.text({ ui.span("Scan failed: ", "error"), ui.span(state.error, "muted") }))
	elseif not state.loaded then
		table.insert(body, ui.node("spinner", { style = "dots", label = { ui.span("Reading omp sessions", "muted") } }))
	elseif session == nil then
		table.insert(body, ui.text({ ui.span("No omp session found for " .. (state.cwd or "this directory"), "muted") }))
		table.insert(body, ui.text({ ui.span("Start omp here and its subagents will show up.", "dim") }))
	elseif total == 0 then
		table.insert(body, ui.text({ ui.span("No subagents in this session yet.", "muted") }))
	end
	local rows: { Node } = {}
	for _, a in ordered(state) do
		table.insert(rows, agent_node(state, a))
	end
	table.insert(body, with(ui.col(rows), { key = "agents" }))
	local hint = "↑↓ select · enter open · o / ⌘click open below"
	if #state.sessions > 1 then
		hint ..= " · s next session"
	end
	return {
		main = ui.col({ header, ui.col(body) }),
		dock = ui.row({ ui.text({ ui.span(hint, "muted") }) }),
	}
end

local function transcript_view(state: ListState, v: Viewer): BlockView
	local a = state.viewing and state.agents[state.viewing]
	local head: { Span } = { ui.span(v.label, "strong") }
	local badges: { Node } = {
		with(ui.badge("← Subagents", "accent"), { actions = { click = "back" }, key = "back" }),
	}
	if a then
		table.insert(badges, ui.badge(shown(state, a), if shown(state, a) == "running" then "accent" else "neutral"))
		if a.model ~= nil then
			table.insert(head, ui.span("  " .. a.model, "muted"))
		end
		table.insert(head, ui.span(string.format("  %d tools · %d requests · $%.2f", a.tools, a.requests, a.cost), "dim"))
	end
	badges[#badges + 1] = ui.text(head)
	return {
		main = transcript.main(v, { ui.row(badges) }),
		dock = transcript.hints(v, "esc / ←← back"),
	}
end

local list: BlockDef<ListState> = {
	init = function(cx, args, saved)
		local cwd = args[1] or cx.cwd
		local state: ListState = {
			cwd = cwd,
			bucket = if cwd ~= nil then agents.bucket(cwd) else nil,
			sessions = {},
			pinned = if saved ~= nil then saved.pinned else nil,
			session = nil,
			agents = {},
			sizes = {},
			now = 0,
			mono = tern.now(),
			ticks = 0,
			busy = false,
			stopped = false,
			loaded = false,
			error = nil,
			sel = nil,
			viewing = nil,
			viewer = nil,
			restore = if saved ~= nil then saved.viewing else nil,
			left_at = -math.huge,
		}
		local function tick()
			if state.stopped or not running(cx.pane) then
				return
			end
			local viewer = state.viewer
			if viewer ~= nil and transcript.due(viewer) then
				transcript.poll(viewer, false, function(changed)
					if changed then
						cx:render()
						transcript.follow_soon(viewer, cx)
					end
				end)
			end
			local function later()
				tern.timer(TICK_MS, tick)
			end
			if state.ticks % REFRESH_EVERY == 0 and not state.busy then
				state.busy = true
				scan(state, cx, function()
					state.busy = false
					state.loaded = true
					if running(cx.pane) then
						cx:render()
					end
					later()
				end)
			else
				later()
			end
			state.ticks += 1
		end
		tick()
		return state
	end,

	title = function(state)
		return title_of(state)
	end,

	view = function(state, _cx)
		if state.viewer ~= nil then
			return transcript_view(state, state.viewer)
		end
		return list_view(state)
	end,

	key = function(state, key, cx)
		local v = state.viewer
		if v ~= nil then
			if key.name == "escape" then
				close_view(state)
				return true
			elseif key.name == "left" and not (key.ctrl or key.alt or key.meta or key.shift) then
				local now = tern.now()
				if now - state.left_at <= DOUBLE_LEFT_MS then
					state.left_at = -math.huge
					close_view(state)
					return true
				end
				state.left_at = now
				return false
			end
			return transcript.key(v, key, cx)
		end
		local order = ordered(state)
		local at = 0
		for i, a in order do
			if a.file == state.sel then
				at = i
			end
		end
		if key.name == "j" or key.name == "down" then
			local nxt = order[math.min(at + 1, #order)]
			state.sel = if nxt ~= nil then nxt.file else nil
		elseif key.name == "k" or key.name == "up" then
			local prev = order[math.max(at - 1, 1)]
			state.sel = if prev ~= nil then prev.file else nil
		elseif key.name == "enter" or key.name == "space" or key.name == "o" then
			if state.sel == nil then
				return false
			end
			if key.meta or key.name == "o" then
				open_below(state, state.sel, cx)
			else
				open_here(state, state.sel, cx)
			end
		elseif key.name == "s" and #state.sessions > 1 then
			local current = state.session
			local nxt = state.sessions[1]
			for i, s in state.sessions do
				if current ~= nil and s.id == current.id then
					nxt = state.sessions[i % #state.sessions + 1]
				end
			end
			state.pinned = nxt.id
			state.session, state.agents, state.sizes, state.sel = nxt, {}, {}, nil
			state.ticks = 1 -- next tick is not a session re-list
			scan(state, cx, function()
				cx:render()
			end)
		elseif key.name == "r" then
			state.sizes = {}
			scan(state, cx, function()
				cx:render()
			end)
			return false
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "open" and type(ev.value) == "string" then
			state.sel = ev.value
			if has(ev.mods, "meta") then
				open_below(state, ev.value, cx)
			else
				open_here(state, ev.value, cx)
			end
		elseif ev.act == "back" then
			close_view(state)
		elseif ev.act == "pick" and state.viewer ~= nil and type(ev.value) == "string" then
			transcript.pick(state.viewer, ev.value)
		end
	end,

	save = function(state)
		return { pinned = state.pinned, viewing = state.viewing }
	end,
}

tern.block.define("list", list)

------------------------------------------------------------------------------------------
-- subagents.transcript
------------------------------------------------------------------------------------------

type TranscriptState = { viewer: Viewer, stopped: boolean }

local transcript_block: BlockDef<TranscriptState> = {
	init = function(cx, args, saved)
		local path = args[1] or (if saved ~= nil then saved.path else nil)
		local label = args[2] or (if saved ~= nil then saved.label else nil)
		local viewer = transcript.new(path or "", label or util.strip_suffix(util.basename(path or ""), ".jsonl"))
		local state: TranscriptState = { viewer = viewer, stopped = path == nil }
		if path == nil then
			viewer.error = "No transcript path given"
			viewer.loaded = true
			return state
		end
		local function tick()
			if state.stopped or not running(cx.pane) then
				return
			end
			local function later()
				tern.timer(TICK_MS, tick)
			end
			if transcript.due(viewer) then
				transcript.poll(viewer, false, function(changed)
					if changed and running(cx.pane) then
						cx:render()
						transcript.follow_soon(viewer, cx)
					end
					later()
				end)
			else
				later()
			end
		end
		transcript.poll(viewer, true, function()
			cx:render()
			transcript.follow_soon(viewer, cx)
			tern.timer(TICK_MS, tick)
		end)
		return state
	end,

	title = function(state)
		return state.viewer.label
	end,

	view = function(state, _cx)
		local v = state.viewer
		return {
			main = transcript.main(v, {
				ui.row({ ui.text({ ui.span(v.label, "strong"), ui.span("  " .. v.path, "dim") }) }),
			}),
			dock = transcript.hints(v, nil),
		}
	end,

	key = function(state, key, cx)
		return transcript.key(state.viewer, key, cx)
	end,

	event = function(state, ev, _cx)
		if ev.ev == "action" and ev.act == "pick" and type(ev.value) == "string" then
			transcript.pick(state.viewer, ev.value)
		end
	end,

	save = function(state)
		return { path = state.viewer.path, label = state.viewer.label }
	end,
}

tern.block.define("transcript", transcript_block)
