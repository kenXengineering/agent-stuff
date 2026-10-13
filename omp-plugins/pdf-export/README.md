# omp-pdf-export

`/pdf` exports chat responses from the current omp session to a rendered PDF (Markdown → styled HTML → headless Chrome).

## Install

```sh
omp plugin link ./pdf-export
```

One-off without installing: `omp -e ./pdf-export`.

Requires Chrome, Chromium, Edge, or Brave. Set `OMP_PDF_BROWSER=/path/to/browser` if it isn't found automatically.

## Usage

| Command | Prints |
|---|---|
| `/pdf` | last response |
| `/pdf print last response` | last response |
| `/pdf last two responses` | last 2 responses |
| `/pdf last response with prompt` | last prompt + response |
| `/pdf last 3 exchanges` | last 3 prompt + response pairs |
| `/pdf first response` | first response |
| `/pdf all responses` | every response |
| `/pdf whole chat` | every prompt + response |
| `/pdf last response ~/Desktop/answer.pdf` | last response, saved to that path |

Counts accept digits or words (`two`, `couple`, … `twenty`). Any argument ending in `.pdf` is the output path; otherwise the file goes to the session's working directory as `omp-<selection>-<timestamp>.pdf`. Unrecognized words abort with a usage hint instead of guessing.

A *response* is the final assistant message of a turn, the answer you read. Progress notes between tool calls, thinking, and tool calls/results are left out. If the agent is still responding, `/pdf` waits for it to finish.

## Notes

- Raw HTML in responses is neutralized (GFM tag filter), and the page's CSP blocks scripts. Remote `https:` images still load.
- Math (`$…$`) is printed as plain text.
