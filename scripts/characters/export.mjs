import { chromium } from "playwright";
import fs from "node:fs/promises";
import crypto from "node:crypto";
const manifest = JSON.parse(
  await fs.readFile(new URL("./characters.json", import.meta.url)),
);
const browser = await chromium.launch({
  executablePath:
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  args: ["--use-angle=metal"],
});
const page = await browser.newPage();
page.on("pageerror", (e) => console.error("PAGE ERROR", e));
await page.goto(process.env.RENDER_URL || "http://127.0.0.1:5197");
await page.waitForFunction(() => window.renderReady);
await fs.mkdir(new URL("./output/", import.meta.url), { recursive: true });
const results = [];
for (const entry of manifest.characters) {
  try {
    const result = await page.evaluate(
      (entry) => window.renderCharacter(entry),
      entry,
    );
    const bytes = Buffer.from(result.sheet.split(",")[1], "base64");
    await fs.writeFile(
      new URL("./output/" + entry.id + ".png", import.meta.url),
      bytes,
    );
    for (let i = 0; i < result.samples.length; i++)
      await fs.writeFile(
        new URL("./output/" + entry.id + "-" + i + ".png", import.meta.url),
        Buffer.from(result.samples[i].split(",")[1], "base64"),
      );
    delete result.sheet;
    delete result.samples;
    result.sha256 = crypto.createHash("sha256").update(bytes).digest("hex");
    results.push(result);
    console.log(JSON.stringify(result));
  } catch (e) {
    console.error("FAILED", entry.id, e);
    process.exitCode = 1;
  }
}
await fs.writeFile(
  new URL("./output/manifest.json", import.meta.url),
  JSON.stringify({ ...manifest, characters: results }, null, 2),
);
await browser.close();
