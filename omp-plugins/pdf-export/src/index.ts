// /pdf — export chat responses to a rendered PDF.
//
//   /pdf                          last response
//   /pdf last two responses       last 2 responses
//   /pdf last 3 exchanges         last 3 prompt + response pairs
//   /pdf whole chat               every prompt + response
//   /pdf last response ~/a.pdf    custom output path

import * as os from "node:os";
import * as path from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { renderHtml, printToPdf } from "./render";
import { collectExchanges, parseSelection, pick, type Selection, USAGE } from "./select";

export default function pdfExport(pi: ExtensionAPI) {
	pi.registerCommand("pdf", {
		description: "Export chat responses to PDF (default: last response). e.g. /pdf last two responses",
		handler: async (args, ctx) => {
			let selection: Selection;
			try {
				selection = parseSelection(args);
			} catch (err) {
				ctx.ui.notify(err instanceof Error ? err.message : String(err), "error");
				return;
			}

			if (!ctx.isIdle()) {
				ctx.ui.notify("/pdf: waiting for the current response to finish…", "info");
				await ctx.waitForIdle();
			}

			const exchanges = pick(collectExchanges(ctx.sessionManager.getBranch()), selection);
			if (exchanges.length === 0) {
				ctx.ui.notify(`/pdf: no responses to export yet.\n${USAGE}`, "warning");
				return;
			}

			const now = new Date();
			const stamp = now.toISOString().slice(0, 19).replace(/[-:]/g, "").replace("T", "-");
			const outputPath = selection.outputPath
				? path.resolve(ctx.cwd, selection.outputPath.replace(/^~(?=$|[\\/])/, os.homedir()))
				: path.join(ctx.cwd, `omp-${selection.label.replace(/\s+/g, "-")}-${stamp}.pdf`);

			const models = [...new Set(exchanges.map(ex => ex.model).filter(Boolean))].join(", ");
			const html = renderHtml(exchanges, {
				title: pi.getSessionName() || "omp chat",
				subtitle: [selection.label, models, now.toLocaleString()].filter(Boolean).join(" · "),
			});

			try {
				await printToPdf(html, outputPath);
			} catch (err) {
				ctx.ui.notify(err instanceof Error ? err.message : String(err), "error");
				return;
			}
			const shown = exchanges.length < selection.count && selection.count !== Infinity
				? ` (only ${exchanges.length} available)`
				: "";
			ctx.ui.notify(`Saved ${selection.label}${shown} to ${outputPath}`, "info");
		},
	});
}
