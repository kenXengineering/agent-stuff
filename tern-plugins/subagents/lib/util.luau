--!strict
-- Small pure helpers shared by both blocks: time, text, and URL-ish encoding.

local M = {}

-- Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's civil_from_days, inverted).
local function days_from_civil(y: number, m: number, d: number): number
	y -= if m <= 2 then 1 else 0
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- "2026-10-13T16:24:20.291Z" -> epoch milliseconds (UTC), or nil.
function M.parse_iso(s: string?): number?
	if s == nil then
		return nil
	end
	local y, mo, d, h, mi, sec, frac = string.match(s, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)")
	if y == nil or mo == nil or d == nil or h == nil or mi == nil or sec == nil then
		return nil
	end
	local days = days_from_civil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
	local ms = 0
	if frac ~= nil and frac ~= "" then
		ms = (tonumber("0." .. frac) :: number) * 1000
	end
	return (days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(sec) :: number)) * 1000 + ms
end

-- 83000 -> "1m 23s". Coarse on purpose: this is a glance at how stale something is.
function M.duration(ms: number): string
	local s = math.max(0, math.floor(ms / 1000))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return (s // 60) .. "m " .. (s % 60) .. "s"
	elseif s < 86400 then
		return (s // 3600) .. "h " .. ((s % 3600) // 60) .. "m"
	end
	return (s // 86400) .. "d " .. ((s % 86400) // 3600) .. "h"
end

-- Collapses whitespace runs and cuts to `max` characters with an ellipsis.
function M.oneline(text: string, max: number): string
	local squeezed = string.gsub(text, "%s+", " ")
	local s = string.match(squeezed, "^ ?(.-) ?$") or squeezed
	local len = utf8.len(s)
	if len ~= nil and len > max then
		local cut = utf8.offset(s, max) :: number
		return string.sub(s, 1, cut - 1) .. "…"
	end
	return s
end

local ESC: { [string]: string } = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "", f = "" }

-- Undoes JSON string escapes in text cut from a (possibly truncated) JSON document.
function M.unescape(s: string): string
	local out = string.gsub(s, "\\(.)", function(c)
		return ESC[c] or c
	end)
	return out
end

function M.basename(path: string): string
	return string.match(path, "([^/]*)$") or path
end

function M.dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

function M.strip_suffix(s: string, suffix: string): string
	if #s >= #suffix and string.sub(s, -#suffix) == suffix then
		return string.sub(s, 1, #s - #suffix)
	end
	return s
end

-- Percent-encoding for a path carried in a URL query.
function M.encode(s: string): string
	local out = string.gsub(s, "[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return out
end

function M.decode(s: string): string
	local out = string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end)
	return out
end

function M.shell_dir(): string
	-- The scan script lives beside the plugin's Luau files.
	return tern.plugin.dir .. "/scripts"
end

-- Runs scripts/scan.sh and hands its stdout to `cb` (nil when it failed).
function M.scan(args: { string }, cb: (out: string?, err: string?) -> ())
	local argv = { "sh", M.shell_dir() .. "/scan.sh" }
	for _, a in args do
		table.insert(argv, a)
	end
	tern.process.run(argv, { timeout_ms = 15000 }, function(r)
		if r.status ~= 0 then
			cb(nil, if r.stderr ~= "" then r.stderr else "scan.sh exited " .. tostring(r.status))
		else
			cb(r.stdout, nil)
		end
	end)
end

return M
