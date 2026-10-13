// Parses `/pdf` arguments and picks the matching exchanges from a session branch.

export interface Selection {
	/** Number of items to take; `Infinity` means everything. */
	count: number;
	/** Take from the end of the chat (`last`) or the beginning (`first`). */
	from: "first" | "last";
	/** Include the user prompt that preceded each response. */
	includePrompts: boolean;
	/** Output path as typed by the user (relative paths resolve against the session cwd). */
	outputPath?: string;
	/** Human-readable label, also used for the default filename. */
	label: string;
}

export interface Exchange {
	prompt?: string;
	response: string;
	model?: string;
}

export const USAGE =
	"Usage: /pdf [last|first] [N|all] [responses|exchanges] [with prompts] [file.pdf]\n" +
	"Examples: /pdf · /pdf last two responses · /pdf last 3 exchanges · /pdf whole chat · /pdf last response with prompt ~/answer.pdf";

type WordKind = "all" | "last" | "first" | "response" | "exchange" | "chat" | "prompt" | "filler";

const NUMBER_WORDS: Record<string, number> = {
	two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
	eleven: 11, twelve: 12, thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17,
	eighteen: 18, nineteen: 19, twenty: 20, couple: 2, pair: 2, single: 1,
};

const WORD_KIND: Record<string, WordKind> = {
	all: "all", every: "all", everything: "all", entire: "all", whole: "all", full: "all", complete: "all",
	last: "last", latest: "last", final: "last", previous: "last", prior: "last", recent: "last", most: "last",
	first: "first", earliest: "first", initial: "first", oldest: "first",
	// Units that print only the assistant's answer.
	response: "response", responses: "response", answer: "response", answers: "response", reply: "response",
	replies: "response", message: "response", messages: "response", output: "response", outputs: "response",
	// Units that print the user prompt together with the answer.
	exchange: "exchange", exchanges: "exchange", turn: "exchange", turns: "exchange", "q&a": "exchange",
	qa: "exchange",
	// The conversation as a whole: "/pdf chat" and "/pdf whole chat" print everything with prompts,
	// while "/pdf last chat" means the last response.
	chat: "chat", chats: "chat", conversation: "chat", conversations: "chat", session: "chat", transcript: "chat",
	prompt: "prompt", prompts: "prompt", question: "prompt", questions: "prompt", request: "prompt",
	requests: "prompt",
	with: "filler", including: "filler", include: "filler", incl: "filler", plus: "filler", and: "filler",
	print: "filler", export: "filler", render: "filler", save: "filler", make: "filler", create: "filler",
	generate: "filler", pdf: "filler", pdfs: "filler", the: "filler", a: "filler", an: "filler", my: "filler",
	your: "filler", of: "filler", me: "filler", please: "filler", just: "filler", only: "filler", to: "filler",
	as: "filler", into: "filler", in: "filler", file: "filler", from: "filler", this: "filler", these: "filler",
	those: "filler", ones: "filler", "chat's": "filler", assistant: "filler", "assistant's": "filler",
	model: "filler", "model's": "filler", agent: "filler", "agent's": "filler", it: "filler", that: "filler",
};

export function parseSelection(args: string): Selection {
	let count: number | undefined;
	let from: "first" | "last" = "last";
	let anchored = false;
	let includePrompts = false;
	let sawChat = false;
	let outputPath: string | undefined;
	const unknown: string[] = [];

	for (const raw of args.trim().split(/\s+/).filter(Boolean)) {
		if (/\.pdf$/i.test(raw)) {
			outputPath = raw;
			continue;
		}
		const word = raw.toLowerCase().replace(/^[^\w&']+|[^\w&']+$/g, "");
		if (!word) continue;
		if (/^\d+$/.test(word)) {
			count = Number(word);
			continue;
		}
		if (Object.hasOwn(NUMBER_WORDS, word)) {
			count = NUMBER_WORDS[word];
			continue;
		}
		if (word === "one") {
			// "one" is both a number ("one response") and a pronoun ("the last one").
			count ??= 1;
			continue;
		}
		const kind = Object.hasOwn(WORD_KIND, word) ? WORD_KIND[word] : undefined;
		switch (kind) {
			case "all":
				count = Infinity;
				break;
			case "last":
			case "first":
				from = kind;
				anchored = true;
				break;
			case "exchange":
			case "prompt":
				includePrompts = true;
				break;
			case "chat":
				sawChat = true;
				break;
			case "response":
			case "filler":
				break;
			default:
				unknown.push(raw);
		}
	}

	if (unknown.length > 0) {
		throw new Error(`/pdf: didn't understand ${unknown.map(w => `"${w}"`).join(", ")}.\n${USAGE}`);
	}
	if (count !== undefined && count < 1) {
		throw new Error(`/pdf: count must be at least 1.\n${USAGE}`);
	}

	if (sawChat && (count === Infinity || (count === undefined && !anchored))) {
		count = Infinity;
		includePrompts = true;
	}
	const finalCount = count ?? 1;

	return {
		count: finalCount,
		from,
		includePrompts,
		outputPath,
		label: describe(finalCount, from, includePrompts),
	};
}

function describe(count: number, from: "first" | "last", includePrompts: boolean): string {
	const noun = includePrompts ? "exchange" : "response";
	if (count === Infinity) return includePrompts ? "full chat" : `all ${noun}s`;
	return count === 1 ? `${from} ${noun}` : `${from} ${count} ${noun}s`;
}

/** Minimal structural view of session entries; see `ctx.sessionManager.getBranch()`. */
interface BranchEntry {
	type: string;
	message?: {
		role?: string;
		content?: unknown;
		model?: string;
	};
}

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((block): block is { type: "text"; text: string } => block?.type === "text" && typeof block.text === "string")
		.map(block => block.text.trim())
		.filter(Boolean)
		.join("\n\n");
}

/**
 * Groups the branch into user-prompt → assistant-answer exchanges. The answer is
 * the text of the turn's final assistant message that has text, i.e. what the
 * user reads as the response; progress narration between tool calls, thinking,
 * and tool calls are dropped. Turns without any assistant text are omitted.
 */
export function collectExchanges(branch: readonly BranchEntry[]): Exchange[] {
	const exchanges: Exchange[] = [];
	let current: Exchange | undefined;

	for (const entry of branch) {
		if (entry.type !== "message" || !entry.message) continue;
		const { role } = entry.message;
		if (role === "user") {
			if (current?.response) exchanges.push(current);
			current = { prompt: textOf(entry.message.content) || undefined, response: "" };
		} else if (role === "assistant") {
			const text = textOf(entry.message.content);
			if (!text) continue;
			current ??= { response: "" };
			current.response = text;
			current.model = entry.message.model ?? current.model;
		}
	}
	if (current?.response) exchanges.push(current);
	return exchanges;
}

/** Applies the selection's count/direction and drops prompts unless they were asked for. */
export function pick(exchanges: readonly Exchange[], selection: Selection): Exchange[] {
	const picked =
		selection.count >= exchanges.length
			? exchanges
			: selection.from === "last"
				? exchanges.slice(exchanges.length - selection.count)
				: exchanges.slice(0, selection.count);
	return selection.includePrompts ? [...picked] : picked.map(({ prompt: _prompt, ...rest }) => rest);
}
