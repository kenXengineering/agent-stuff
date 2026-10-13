// Renders exchanges to a standalone HTML page and prints it to PDF with headless Chromium.

import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { Exchange } from "./select";

export interface DocumentMeta {
	title: string;
	subtitle: string;
}

// tagFilter neutralizes raw <script>/<iframe>/… in model output (GFM tagfilter); the CSP below
// additionally forbids script execution and network access other than images.
const MARKDOWN_OPTIONS = { tagFilter: true, autolinks: true };

const STYLE = `
@page { size: A4; margin: 18mm 16mm; }
* { box-sizing: border-box; }
body { font: 10.5pt/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; color: #1f2328; margin: 0; }
header { border-bottom: 2px solid #d0d7de; margin-bottom: 18px; padding-bottom: 8px; }
header h1 { font-size: 15pt; margin: 0 0 2px; }
header p { color: #656d76; font-size: 9pt; margin: 0; }
section + section { border-top: 1px solid #d0d7de; margin-top: 22px; padding-top: 16px; }
.prompt { background: #f6f8fa; border-left: 4px solid #8c959f; border-radius: 4px; padding: 6px 12px; margin-bottom: 14px; }
.label { color: #656d76; font-size: 8.5pt; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; margin-bottom: 4px; }
h1, h2, h3, h4 { line-height: 1.25; margin: 1.1em 0 .5em; break-after: avoid; }
h1 { font-size: 16pt; } h2 { font-size: 13.5pt; } h3 { font-size: 12pt; } h4 { font-size: 10.5pt; }
p, ul, ol, table, pre, blockquote { margin: 0 0 .8em; }
a { color: #0969da; text-decoration: none; }
code { font: 9pt/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; background: #eff1f3; border-radius: 4px; padding: .1em .35em; }
pre { background: #f6f8fa; border: 1px solid #d8dee4; border-radius: 6px; padding: 10px 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
pre code { background: none; padding: 0; }
blockquote { border-left: 4px solid #d0d7de; color: #57606a; padding: 0 12px; }
table { border-collapse: collapse; width: 100%; font-size: 9.5pt; }
th, td { border: 1px solid #d0d7de; padding: 5px 9px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; }
tr { break-inside: avoid; }
li.task-list-item { list-style: none; }
img { max-width: 100%; }
hr { border: 0; border-top: 1px solid #d0d7de; }
`;

export function renderHtml(exchanges: readonly Exchange[], meta: DocumentMeta): string {
	const sections = exchanges
		.map(ex => {
			const prompt = ex.prompt
				? `<div class="prompt"><div class="label">Prompt</div>${Bun.markdown.html(ex.prompt, MARKDOWN_OPTIONS)}</div>`
				: "";
			const label = ex.prompt ? `<div class="label">Response</div>` : "";
			return `<section>${prompt}${label}${Bun.markdown.html(ex.response, MARKDOWN_OPTIONS)}</section>`;
		})
		.join("\n");
	const title = Bun.escapeHTML(meta.title);
	return `<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: file: https:">
<title>${title}</title>
<style>${STYLE}</style></head>
<body><header><h1>${title}</h1><p>${Bun.escapeHTML(meta.subtitle)}</p></header>
${sections}
</body></html>`;
}

function browserCandidates(): string[] {
	const override = process.env.OMP_PDF_BROWSER;
	if (override) return [override];
	const home = os.homedir();
	switch (process.platform) {
		case "darwin":
			return ["Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser", "Google Chrome Canary"].flatMap(app => [
				`/Applications/${app}.app/Contents/MacOS/${app}`,
				`${home}/Applications/${app}.app/Contents/MacOS/${app}`,
			]);
		case "win32": {
			const roots = [process.env.PROGRAMFILES, process.env["PROGRAMFILES(X86)"], process.env.LOCALAPPDATA].filter(
				(r): r is string => !!r,
			);
			return roots.flatMap(root => [
				path.join(root, "Google", "Chrome", "Application", "chrome.exe"),
				path.join(root, "Microsoft", "Edge", "Application", "msedge.exe"),
			]);
		}
		default:
			return ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "brave-browser"]
				.map(bin => Bun.which(bin))
				.filter((p): p is string => !!p);
	}
}

async function findBrowser(): Promise<string> {
	for (const candidate of browserCandidates()) {
		if (await Bun.file(candidate).exists()) return candidate;
	}
	throw new Error(
		"/pdf needs Chrome, Chromium, Edge, or Brave to render PDFs. Install one or set OMP_PDF_BROWSER to its executable.",
	);
}

/** Prints `html` to `outputPath` and returns once the PDF is on disk. */
export async function printToPdf(html: string, outputPath: string): Promise<void> {
	const browser = await findBrowser();
	const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "omp-pdf-"));
	try {
		const htmlPath = path.join(workDir, "chat.html");
		await Bun.write(htmlPath, html);
		await fs.mkdir(path.dirname(outputPath), { recursive: true });
		await fs.rm(outputPath, { force: true });

		const proc = Bun.spawn(
			[
				browser,
				"--headless",
				"--disable-gpu",
				"--no-first-run",
				"--no-default-browser-check",
				"--disable-extensions",
				"--disable-background-networking",
				"--disable-sync",
				"--disable-component-update",
				"--use-mock-keychain",
				"--password-store=basic",
				`--user-data-dir=${path.join(workDir, "profile")}`,
				"--no-pdf-header-footer",
				"--print-to-pdf-no-header",
				`--print-to-pdf=${outputPath}`,
				Bun.pathToFileURL(htmlPath).href,
			],
			{ stdout: "ignore", stderr: "pipe", timeout: 60_000 },
		);
		// Chrome reports "<N> bytes written to file <path>" once the PDF is complete, but on macOS
		// the headless process can linger for a long time afterwards; stop it as soon as it reports.
		let stderr = "";
		let printed = false;
		const decoder = new TextDecoder();
		for await (const chunk of proc.stderr) {
			stderr += decoder.decode(chunk, { stream: true });
			if (/bytes written to file/.test(stderr)) {
				printed = true;
				proc.kill();
				break;
			}
		}
		const exitCode = await proc.exited;
		const written = await fs.stat(outputPath).catch(() => undefined);
		if (!written || written.size === 0 || (!printed && exitCode !== 0)) {
			const detail = stderr.trim().split("\n").slice(-3).join("\n");
			throw new Error(`/pdf: ${path.basename(browser)} failed to print (exit ${exitCode}).${detail ? `\n${detail}` : ""}`);
		}
	} finally {
		await fs.rm(workDir, { recursive: true, force: true });
	}
}
