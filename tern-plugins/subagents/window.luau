--!strict
-- Window half. The list block asks to open a transcript beside it by opening a private
-- URL (host blocks can't place panes themselves); this claims that URL and splits the
-- block that asked, below it.

local util = require("./lib/util")

local PREFIX = "tern-subagents://transcript?"

local function query(url: string): { [string]: string }
	local out: { [string]: string } = {}
	for pair in string.gmatch(string.sub(url, #PREFIX + 1), "[^&]+") do
		local k, v = string.match(pair, "^([^=]+)=(.*)$")
		if k ~= nil and v ~= nil then
			out[k] = util.decode(v)
		end
	end
	return out
end

tern.route.link(function(link, cx)
	if string.sub(link.url, 1, #PREFIX) ~= PREFIX then
		return nil
	end
	local q = query(link.url)
	local path = q.path
	if path == nil or path == "" then
		cx:toast("error", "Subagents: no transcript path in link")
		return { handled = true }
	end
	local args = { path, q.label or util.strip_suffix(util.basename(path), ".jsonl") }
	local pane: number? = if link.pane ~= nil then link.pane else nil
	local opened: number? = nil
	if pane ~= nil then
		opened = cx.layout:split(pane, "down", { block = "subagents.transcript", args = args })
	end
	if opened == nil then
		opened = cx:new_block("subagents.transcript", args, "below")
	end
	if opened == nil then
		cx:toast("error", "Subagents: could not open the transcript block")
	end
	return { handled = true }
end)
