import * as PIXI from "pixi.js";
import "./src/utils/patch";
import { SpineMhy } from "./src/utils/SpineMhy";
window.renderCharacter = async (entry) => {
  const app = new PIXI.Application({
    width: 128,
    height: 128,
    resolution: 2,
    antialias: true,
    backgroundAlpha: 0,
    preserveDrawingBuffer: true,
    autoStart: false,
  });
  app.stop();
  document.body.replaceChildren(app.view);
  const resource = await new Promise((resolve, reject) => {
    app.loader.onError.add(reject);
    app.loader
      .add("/" + entry.path + ".json")
      .load((l, r) => resolve(r["/" + entry.path + ".json"]));
  });
  Object.assign(resource.spineData, {
    extra: resource.data.extra,
    extraConfig: resource.data.extraConfig,
    extraSlot: resource.data.extraSlot,
  });
  const actor = new SpineMhy(resource.spineData);
  actor.autoUpdate = false;
  app.stage.addChild(actor);
  actor.skeleton.setSkinByName(entry.skin);
  actor.skeleton.setSlotsToSetupPose();
  const animation = actor.spineData.animations.find(
    (a) => a.name === entry.animation,
  );
  if (!animation) throw new Error("Missing animation " + entry.animation);
  const duration = animation.duration;
  const count = Math.ceil(duration * 60);
  const dt = duration / count;
  actor.alignAutoBone(duration);
  actor.state.setAnimation(0, entry.animation, true);
  // Let secondary motion settle before measuring the entire loop, never fit individual frames.
  for (let i = 0; i < count * 4; i++) actor.update(dt);
  let minX = Infinity,
    minY = Infinity,
    maxX = -Infinity,
    maxY = -Infinity;
  for (let i = 0; i < count; i++) {
    actor.update(dt);
    let b = actor.getLocalBounds();
    minX = Math.min(minX, b.x);
    minY = Math.min(minY, b.y);
    maxX = Math.max(maxX, b.x + b.width);
    maxY = Math.max(maxY, b.y + b.height);
  }
  let scale = Math.min(120 / (maxX - minX), 120 / (maxY - minY));
  actor.scale.set(scale);
  actor.position.set(64 - ((minX + maxX) / 2) * scale, 124 - maxY * scale);
  // Hidden/transparent attachments can inflate skeleton bounds; fit the visible pixels over the whole cycle.
  const probe = document.createElement("canvas");
  probe.width = 256;
  probe.height = 256;
  const pc = probe.getContext("2d", { willReadFrequently: true });
  let ax = 256,
    ay = 256,
    bx = 0,
    by = 0;
  for (let i = 0; i < count; i++) {
    app.renderer.render(app.stage);
    pc.clearRect(0, 0, 256, 256);
    pc.drawImage(app.view, 0, 0);
    const pixels = pc.getImageData(0, 0, 256, 256).data;
    for (let y = 0; y < 256; y++)
      for (let x = 0; x < 256; x++)
        if (pixels[(y * 256 + x) * 4 + 3] > 16) {
          ax = Math.min(ax, x);
          ay = Math.min(ay, y);
          bx = Math.max(bx, x);
          by = Math.max(by, y);
        }
    actor.update(dt);
  }
  const fit = Math.min(240 / (bx - ax + 1), 240 / (by - ay + 1));
  actor.position.set(
    64 + (actor.x - (ax + bx + 1) / 4) * fit,
    124 + (actor.y - (by + 1) / 2) * fit,
  );
  actor.scale.set(scale * fit);
  const sheet = document.createElement("canvas");
  sheet.width = 128 * 8;
  sheet.height = 128 * Math.ceil(count / 8);
  const ctx = sheet.getContext("2d");
  const frameDigests = [];
  const samples = [];
  for (let i = 0; i < count; i++) {
    app.renderer.render(app.stage);
    ctx.drawImage(app.view, (i % 8) * 128, Math.floor(i / 8) * 128, 128, 128);
    if (
      i === 0 ||
      i === Math.floor(count / 4) ||
      i === Math.floor(count / 2) ||
      i === count - 1
    )
      samples.push(app.view.toDataURL());
    actor.update(dt);
  }
  const result = {
    ...entry,
    duration,
    frameCount: count,
    frameWidth: 128,
    frameHeight: 128,
    columns: 8,
    bounds: { minX, minY, maxX, maxY },
    sheet: sheet.toDataURL(),
    samples,
  };
  app.destroy(true, { children: true, texture: true, baseTexture: true });
  return result;
};
window.renderReady = true;
