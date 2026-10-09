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

export async function recordReadProvenance(dest: string | undefined, path: unknown, hash: string) {
  if (!dest || typeof path !== "string" || !path.trim()) return;
  const key = path.replace(/^\/+|\/+$/g, "").trim();
  let records: Record<string, { contentHash: string; readAt: string }> = {};
  try {
    records = JSON.parse(await readFile(dest, "utf8")) as typeof records;
  } catch {
    records = {};
  }
  records[key] = { contentHash: hash, readAt: new Date().toISOString() };
  await mkdir(dirname(dest), { recursive: true });
  await writeFile(dest, JSON.stringify(records), "utf8");
}

if (process.argv.includes("--read-file-once")) {
  const readOnce = process.argv.indexOf("--read-file-once");
  const file = process.argv[readOnce + 1];
  if (!file) throw new Error("path is required");
  const provenanceIndex = process.argv.indexOf("--provenance");
  const relativeIndex = process.argv.indexOf("--path");
  const startIndex = process.argv.indexOf("--start");
  const endIndex = process.argv.indexOf("--end");
  const { hash, text } = await readAttachedFile(
    file,
    startIndex >= 0 ? process.argv[startIndex + 1] : undefined,
    endIndex >= 0 ? process.argv[endIndex + 1] : undefined,
  );
  await recordReadProvenance(
    provenanceIndex >= 0 ? process.argv[provenanceIndex + 1] : undefined,
    relativeIndex >= 0 ? process.argv[relativeIndex + 1] : "",
    hash,
  );
  process.stdout.write(text);
}
