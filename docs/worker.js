/* ImageCap compression engine.
 *
 * Runs in a Web Worker. Canvas encoding is heavy and entirely synchronous, so
 * on the main thread it blocks painting — the page freezes and even a spinner
 * stops animating. Out here the UI stays live, and several of these run at
 * once so a batch finishes in a fraction of the time.
 */
"use strict";

let heicReady = false;

/* --------------------------------------------------------------------------
   Format policy
-------------------------------------------------------------------------- */
function outputType(name) {
  const ext = (name.match(/\.([^.]+)$/) || [, ""])[1].toLowerCase();
  switch (ext) {
    case "jpg": case "jpeg": return { mime: "image/jpeg", ext, lossy: true, converted: false };
    case "png":              return { mime: "image/png", ext: "png", lossy: false, converted: false };
    case "webp":             return { mime: "image/webp", ext: "webp", lossy: true, converted: false };
    // Decodable but not encodable by browsers, so these change format.
    case "gif":              return { mime: "image/png", ext: "png", lossy: false, converted: true };
    default:                 return { mime: "image/jpeg", ext: "jpg", lossy: true, converted: true };
  }
}

const isHeic = name => /\.(heic|heif)$/i.test(name);

/* --------------------------------------------------------------------------
   Canvas helpers
-------------------------------------------------------------------------- */
function drawTo(source, w, h, flatten) {
  const canvas = new OffscreenCanvas(w, h);
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  // JPEG has no alpha channel, so transparency must become white, not black.
  if (flatten) { ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, w, h); }
  ctx.drawImage(source, 0, 0, w, h);
  return canvas;
}

const encode = (canvas, mime, quality) => canvas.convertToBlob({ type: mime, quality });

/* --------------------------------------------------------------------------
   The quality search

   Encoders take a quality number, not a byte target. Size grows monotonically
   with quality, so the highest quality that still fits is a binary search.
-------------------------------------------------------------------------- */
async function searchQuality(canvas, mime, maxBytes, floor = 0, iterations = 8, probeTop = true) {
  // Probing full quality is only worth an encode when the source is in the
  // right ballpark. On a 16 MB photo aimed at 1.9 MB it cannot possibly fit,
  // and at full resolution that wasted encode is one of the slowest steps.
  if (probeTop) {
    const top = await encode(canvas, mime, 1.0);
    if (top && top.size <= maxBytes) return { blob: top, quality: 1.0 };
  }

  let lo = floor, hi = 1.0, best = null;

  if (floor > 0) {
    const atFloor = await encode(canvas, mime, floor);
    if (!atFloor || atFloor.size > maxBytes) return null;   // caller shrinks instead
    best = { blob: atFloor, quality: floor };
  }

  for (let i = 0; i < iterations; i++) {
    const mid = (lo + hi) / 2;
    const blob = await encode(canvas, mime, mid);
    if (!blob) break;
    if (blob.size <= maxBytes) { best = { blob, quality: mid }; lo = mid; }
    else { hi = mid; }
  }
  return best;
}

/* Shrink dimensions until it fits, keeping quality as high as the cap allows.
   Binary searches the scale so we keep the largest image that fits rather than
   the first one that happens to. Fewer inner quality steps here: this loop can
   run seven times, and the extra precision is not worth the encodes. */
async function searchScale(source, mime, maxBytes, lossy, floor, flatten) {
  const w0 = source.width, h0 = source.height;
  let lo = 0.02, hi = 1.0, best = null;

  for (let i = 0; i < 7; i++) {
    const mid = (lo + hi) / 2;
    const w = Math.max(1, Math.round(w0 * mid));
    const h = Math.max(1, Math.round(h0 * mid));
    const canvas = drawTo(source, w, h, flatten);

    let attempt = null;
    if (lossy) {
      const hit = await searchQuality(canvas, mime, maxBytes, floor, 5, false);
      if (hit) attempt = { blob: hit.blob, quality: hit.quality };
    } else {
      const blob = await encode(canvas, mime, 1.0);
      if (blob && blob.size <= maxBytes) attempt = { blob, quality: null };
    }

    if (attempt) { best = { ...attempt, width: w, height: h }; lo = mid; }
    else { hi = mid; }
  }
  return best;
}

/* --------------------------------------------------------------------------
   Flat artwork vs photographs

   Decides what to sacrifice first for lossless formats. Artwork reuses a small
   set of colours and survives colour reduction almost invisibly; photographs
   band badly, so for those a smaller truecolour image beats a posterised one.
-------------------------------------------------------------------------- */
function isFlatArtwork(canvas) {
  const w = canvas.width, h = canvas.height;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const step = Math.max(1, Math.floor(Math.sqrt((w * h) / 20000)));
  const seen = new Set();
  let counted = 0;
  for (let y = 0; y < h; y += step) {
    const row = ctx.getImageData(0, y, w, 1).data;
    for (let x = 0; x < w; x += step) {
      const p = x * 4;
      if (row[p + 3] > 8) { seen.add((row[p] << 16) | (row[p + 1] << 8) | row[p + 2]); counted++; }
      if (seen.size > 6000) return false;   // clearly photographic
    }
  }
  if (counted < 200) return true;
  return seen.size * 8 < counted;
}

/* Canvas always writes truecolour PNG, so this is not a real palette image —
   but far fewer distinct colours deflate much better, which is the saving. */
function posterize(canvas, levels) {
  const w = canvas.width, h = canvas.height;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const img = ctx.getImageData(0, 0, w, h);
  const d = img.data;
  const q = 255 / (levels - 1);
  for (let i = 0; i < d.length; i += 4) {
    d[i]     = Math.round(Math.round(d[i]     / q) * q);
    d[i + 1] = Math.round(Math.round(d[i + 1] / q) * q);
    d[i + 2] = Math.round(Math.round(d[i + 2] / q) * q);
  }
  const out = new OffscreenCanvas(w, h);
  out.getContext("2d").putImageData(img, 0, 0);
  return out;
}

async function searchPosterize(canvas, maxBytes) {
  for (const levels of [32, 24, 16, 12, 8, 6, 4, 3, 2]) {
    const blob = await encode(posterize(canvas, levels), "image/png", 1.0);
    if (blob && blob.size <= maxBytes) return { blob, levels };
  }
  return null;
}

/* --------------------------------------------------------------------------
   HEIC
-------------------------------------------------------------------------- */
/* heic2any was written for a page, not a worker: it touches `window` and asks
   the DOM for a <canvas>. Both are easy to satisfy — OffscreenCanvas does the
   same job and differs only in offering convertToBlob instead of toBlob — and
   it is worth satisfying, because decoding a 25 MB HEIC on the main thread
   locks the page for several seconds. */
function shimDom() {
  if (self.window) return;
  self.window = self;
  self.document = {
    createElement(tag) {
      if (String(tag).toLowerCase() !== "canvas") return {};
      const c = new OffscreenCanvas(1, 1);
      c.toBlob = (cb, type, q) => c.convertToBlob({ type, quality: q }).then(cb, () => cb(null));
      return c;
    },
  };
}

function loadHeic() {
  if (heicReady) return;
  shimDom();
  importScripts("heic2any.min.js");
  heicReady = true;
}

async function heicToJpeg(file) {
  loadHeic();
  const out = await heic2any({ blob: file, toType: "image/jpeg", quality: 0.95 });
  const blob = Array.isArray(out) ? out[0] : out;
  return new File([blob], file.name, { type: "image/jpeg" });
}

/* --------------------------------------------------------------------------
   Per-file pipeline
-------------------------------------------------------------------------- */
async function process(file, settings, useDecoder) {
  const target = settings.maxBytes;
  const out = outputType(file.name);
  const base = file.name.replace(/\.[^.]+$/, "");
  const originalSize = file.size;

  let viaDecoder = false;
  if (isHeic(file.name) && useDecoder) {
    try { file = await heicToJpeg(file); viaDecoder = true; }
    catch (err) {
      return { name: file.name, before: originalSize, after: 0, treatment: "failed",
               note: "Could not convert this HEIC photo", detail: String(err && err.message || err) };
    }
  }

  let bitmap;
  try {
    // from-image applies EXIF rotation, so phone photos stay upright.
    bitmap = await createImageBitmap(file, { imageOrientation: "from-image" });
  } catch {
    return {
      name: file.name, before: originalSize, after: 0, treatment: "failed",
      note: isHeic(file.name) ? "This browser can't read HEIC — use Safari, or convert above"
                              : "Could not read this file",
    };
  }

  const ow = bitmap.width, oh = bitmap.height;
  let w = ow, h = oh, didResize = false;

  if (settings.maxDimension) {
    const longest = Math.max(w, h);
    if (longest > settings.maxDimension) {
      const f = settings.maxDimension / longest;
      w = Math.max(1, Math.round(w * f));
      h = Math.max(1, Math.round(h * f));
      didResize = true;
    }
  }

  // Already small enough and unchanged: pass the original through rather than
  // re-encoding it, which would only lose quality for nothing.
  if (!out.converted && !didResize && originalSize <= target) {
    bitmap.close();
    return { name: `${base}.${out.ext}`, before: originalSize, after: originalSize,
             treatment: "copied", blob: file, width: ow, height: oh, ow, oh };
  }

  const canvas = drawTo(bitmap, w, h, out.lossy);
  bitmap.close();

  let blob = null, quality = null, levels = null;
  let treatment = didResize ? "resized" : "ok";

  if (out.lossy) {
    // Skip the full-quality probe when the source dwarfs the target — it
    // cannot fit, and at full resolution it is an expensive way to find out.
    const probeTop = originalSize <= target * 1.5;
    const hit = await searchQuality(canvas, out.mime, target, settings.minQuality, 8, probeTop);
    if (hit) { blob = hit.blob; quality = hit.quality; }
  } else {
    const plain = await encode(canvas, out.mime, 1.0);
    if (plain && plain.size <= target) blob = plain;
    else if (isFlatArtwork(canvas)) {
      const hit = await searchPosterize(canvas, target);
      if (hit) { blob = hit.blob; levels = hit.levels; }
    }
  }

  // Nothing else worked — give up pixels.
  if (!blob) {
    const hit = await searchScale(canvas, out.mime, target, out.lossy, settings.minQuality, out.lossy)
             || await searchScale(canvas, out.mime, target, out.lossy, 0, out.lossy);
    if (hit) { blob = hit.blob; quality = hit.quality; w = hit.width; h = hit.height; treatment = "resized"; }
  }

  if (!blob) {
    return { name: file.name, before: originalSize, after: 0, treatment: "failed",
             note: "Could not reach the size limit for this image" };
  }

  // The scale search keeps as many pixels as will fit, so it often lands a
  // fraction under full size — 8126px becoming 8064px. That is a rounding
  // artefact nobody could see, and calling it "resized" makes a non-event look
  // like a compromise. Only report a resize worth the word.
  const meaningfullyResized = (ow > 0 ? w / ow : 1) < 0.97;
  if (treatment === "resized" && !meaningfullyResized) treatment = "ok";

  let note = null;
  if (viaDecoder) note = "HEIC converted to JPEG in your browser";
  else if (out.converted) note = `Saved as ${out.ext.toUpperCase()} — browsers can't write the original format`;
  else if (levels) note = "Colours reduced to fit";

  return { name: `${base}.${out.ext}`, before: originalSize, after: blob.size,
           treatment: out.converted ? "converted" : treatment,
           blob, width: w, height: h, ow, oh, quality, note, meaningfullyResized };
}

/* --------------------------------------------------------------------------
   Messages
-------------------------------------------------------------------------- */
self.onmessage = async (e) => {
  const { id, kind, file, settings, useDecoder } = e.data;

  if (kind === "heic-test") {
    // Done out here so a large HEIC does not stall the page while we find out.
    try { (await createImageBitmap(file)).close(); self.postMessage({ id, native: true }); }
    catch { self.postMessage({ id, native: false }); }
    return;
  }

  try {
    self.postMessage({ id, result: await process(file, settings, useDecoder) });
  } catch (err) {
    self.postMessage({
      id,
      result: { name: file.name, before: file.size, after: 0, treatment: "failed",
                note: "Something went wrong with this image" },
    });
  }
};
