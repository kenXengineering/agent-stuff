# One pass over an omp subagent transcript (JSONL).
#
# Prints, in this order:
#   stats <TAB> tools <TAB> requests <TAB> cost <TAB> tokens <TAB> started
#   e <TAB> kind <TAB> sub <TAB> timestamp <TAB> extra      (the last RING significant entries)
#
# Entries are classified from raw text instead of decoded: transcript lines can be
# hundreds of KB (tool results), and only a few keys decide the agent's status. A raw
# `"key":"` can only be a real key, because quotes inside JSON strings are escaped.
# Scanning uses plain index/substr, not regex, so long lines stay cheap and awk flavours agree.
# The one regex is a tab squash on a 400-char slice.

# The text after the first `marker`, up to the next quote (at most 400 chars), else "".
function after(line, marker,    p, rest, q) {
	p = index(line, marker)
	if (!p) return ""
	rest = substr(line, p + length(marker), 400)
	q = index(rest, "\"")
	return q ? substr(rest, 1, q - 1) : rest
}

# The number after the first `marker`, else 0.
function number(line, marker,    p) {
	p = index(line, marker)
	return p ? substr(line, p + length(marker), 24) + 0 : 0
}

# Adds the usage cost of a message or model_usage line.
function add_cost(line,    p) {
	p = index(line, "\"cost\":{")
	if (p) cost += number(substr(line, p, 300), "\"total\":")
}

function push(kind, sub_, ts, extra) {
	slot = n % RING
	ek[slot] = kind; es[slot] = sub_; et[slot] = ts; ex[slot] = extra
	n++
}

BEGIN { RING = 16; n = 0; tools = 0; req = 0; cost = 0; tokens = 0; started = "" }

NR == 2 && started == "" { started = after($0, "\"timestamp\":\"") }

{
	if (substr($0, 1, 17) == "{\"type\":\"message\"") {
		role = after($0, "\"message\":{\"role\":\"")
		ts = after($0, "\"timestamp\":\"")
		if (role == "assistant") {
			req++
			tokens = number($0, "\"totalTokens\":") + 0
			add_cost($0)
			calls = ""
			rest = $0
			while ((p = index(rest, "\"type\":\"toolCall\",\"id\":\"")) > 0) {
				rest = substr(rest, p + 24)
				calls = calls (calls == "" ? "" : ",") after(rest, "\"name\":\"")
			}
			push("m", role, ts, after($0, "\"stopReason\":\"") "|" calls)
		} else {
			push("m", role, ts, "")
		}
	} else if (substr($0, 1, 16) == "{\"type\":\"custom\"") {
		ct = after($0, "\"customType\":\"")
		if (ct == "tool_execution_start") {
			tools++
			p = index($0, "\"args\":")
			args = p ? substr($0, p + 7, 400) : ""
			gsub(/\t/, " ", args)
			push("c", ct, after($0, "\"startedAt\":\""), after($0, "\"toolName\":\"") "|" args)
		} else if (ct == "session_exit") {
			push("c", ct, after($0, "\"recordedAt\":\""), after($0, "\"kind\":\""))
		}
	} else if (substr($0, 1, 21) == "{\"type\":\"model_usage\"") {
		add_cost($0)
	}
}

END {
	printf "stats\t%d\t%d\t%.6f\t%d\t%s\n", tools, req, cost, tokens, started
	first = n > RING ? n - RING : 0
	for (j = first; j < n; j++) {
		slot = j % RING
		printf "e\t%s\t%s\t%s\t%s\n", ek[slot], es[slot], et[slot], ex[slot]
	}
}
