import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export function wholeFileHash(data: Buffer): string {
  return `sha256:${createHash("sha256").update(data).digest("hex")}`;
}

export async function readAttachedFile(
  file: string,
  startLine?: unknown,
  endLine?: unknown,
): Promise<{ hash: string; text: string }> {
  const data = await readFile(file);
  const hash = wholeFileHash(data);
  const lines = data.toString("utf8").split(/\r?\n/);
  const start = Math.max(1, Number(startLine ?? 1));
  const end = Math.min(lines.length, Number(endLine ?? start + 249));
  if (start > end) return { hash, text: `content_hash ${hash}` };
  const body = lines.slice(start - 1, end).map((line, index) => `${start + index}: ${line}`).join("\n");
  return { hash, text: `content_hash ${hash}\n${body}` };
}

if (process.argv.includes("--read-file-once")) {
  const readOnce = process.argv.indexOf("--read-file-once");
  const file = process.argv[readOnce + 1];
  if (!file) throw new Error("path is required");
  const startIndex = process.argv.indexOf("--start");
  const endIndex = process.argv.indexOf("--end");
  const { text } = await readAttachedFile(
    file,
    startIndex >= 0 ? process.argv[startIndex + 1] : undefined,
    endIndex >= 0 ? process.argv[endIndex + 1] : undefined,
  );
  process.stdout.write(text);
}
