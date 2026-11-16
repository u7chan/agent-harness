#!/usr/bin/env node
// Deterministic frame preparation and media validation; no browser management.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

process.umask(0o077);

function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}

function positive(value, name, integer = false) {
  const n = Number(value);
  requireValue(Number.isFinite(n) && n > 0 && (!integer || Number.isSafeInteger(n)),
    `${name} must be a positive ${integer ? 'safe integer' : 'number'}`);
  return n;
}

function settings(fps, width, height, frames) {
  const result = {
    fps: positive(fps, 'fps', true),
    width: positive(width, 'width', true),
    height: positive(height, 'height', true),
    frames: positive(frames, 'frames', true),
  };
  requireValue(result.width % 2 === 0 && result.height % 2 === 0,
    'width and height must be even for yuv420p');
  return result;
}

function command(binary, args) {
  const result = spawnSync(binary, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.error) throw new Error(`${binary}: ${result.error.message}`);
  requireValue(result.status === 0,
    `${binary} failed (${result.status ?? result.signal}): ${result.stderr.trim()}`);
  return result.stdout;
}

function writeJSON(filename, value) {
  fs.writeFileSync(filename, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
}

function frameName(index) {
  return `frame-${String(index).padStart(6, '0')}.png`;
}

function readRender(output) {
  const raw = JSON.parse(fs.readFileSync(path.join(output, 'render.json'), 'utf8'));
  return settings(raw.fps, raw.width, raw.height, raw.frames);
}

function requireFrames(output, config) {
  const framesDir = path.join(output, 'frames');
  const names = fs.readdirSync(framesDir);
  requireValue(names.length === config.frames, `expected ${config.frames} frames, found ${names.length}`);
  for (let i = 0; i < config.frames; i++) {
    const stat = fs.statSync(path.join(framesDir, frameName(i)));
    requireValue(stat.isFile() && stat.size > 0, `missing or empty frame ${i}`);
  }
  return framesDir;
}

function prepare(args) {
  requireValue(args.length >= 3 && args.length <= 6,
    'prepare <source.html> <new-output-dir> <seconds> [fps=24] [width=1280] [height=720]');
  const [source, destination, seconds, fps = 24, width = 1280, height = 720] = args;
  const duration = positive(seconds, 'seconds');
  const config = settings(fps, width, height, Math.ceil(duration * Number(fps)));
  const html = fs.readFileSync(source, 'utf8');
  const destinationPath = path.resolve(destination);
  const output = path.join(fs.realpathSync(path.dirname(destinationPath)), path.basename(destinationPath));
  const checkout = fs.realpathSync(fileURLToPath(new URL('../../', import.meta.url)));
  requireValue(output !== checkout && !output.startsWith(`${checkout}${path.sep}`),
    'output must be outside the skill checkout');
  requireValue(!fs.existsSync(output), 'output directory already exists; use a fresh directory');
  command('ffmpeg', ['-version']);
  command('ffprobe', ['-version']);
  fs.mkdirSync(output, { mode: 0o700 });
  fs.mkdirSync(path.join(output, 'frames'), { mode: 0o700 });
  fs.writeFileSync(path.join(output, 'source.html'), html, { flag: 'wx' });

  const captures = [];
  for (let start = 0; start < config.frames; start += 120) {
    const end = Math.min(start + 120, config.frames);
    const filename = `capture-${String(captures.length).padStart(4, '0')}.js`;
    const code = `async page => {
  const errors = [];
  const onError = error => errors.push(error.message);
  const blockNetwork = route => route.abort();
  page.on('pageerror', onError);
  await page.route('**/*', blockNetwork);
  try {
    await page.goto('about:blank');
    await page.setViewportSize({ width: ${config.width}, height: ${config.height} });
    await page.setContent(${JSON.stringify(html)}, { waitUntil: 'load' });
    await page.evaluate(async () => {
      await document.fonts.ready;
      if (typeof window.renderAt !== 'function') throw new Error('Missing window.renderAt(seconds)');
    });
    for (let i = ${start}; i < ${end}; i++) {
      await page.evaluate(async t => {
        await window.renderAt(t);
        await document.fonts.ready;
      }, i / ${config.fps});
      if (errors.length) throw new Error(errors.join('; '));
      await page.screenshot({
        path: ${JSON.stringify(path.join(output, 'frames', 'frame-'))} + String(i).padStart(6, '0') + '.png',
        scale: 'css', animations: 'disabled', caret: 'hide'
      });
    }
    if (errors.length) throw new Error(errors.join('; '));
    return { firstFrame: ${start}, endFrame: ${end}, captured: ${end - start} };
  } finally {
    page.off('pageerror', onError);
    await page.unroute('**/*', blockNetwork);
  }
}`;
    fs.writeFileSync(path.join(output, filename), code, { flag: 'wx' });
    captures.push(filename);
  }
  writeJSON(path.join(output, 'render.json'), { ...config, captures });
  return { directory: output, ...config, durationSeconds: config.frames / config.fps,
    captures: captures.map(name => path.join(output, name)) };
}

function encode(args) {
  requireValue(args.length === 1, 'encode <output-dir>');
  const output = fs.realpathSync(args[0]);
  const config = readRender(output);
  const framesDir = requireFrames(output, config);
  const video = path.join(output, 'video.mp4');
  const report = path.join(output, 'verification.json');
  const partial = path.join(output, 'video.partial.mp4');
  requireValue(!fs.existsSync(video) && !fs.existsSync(report) && !fs.existsSync(partial),
    'video, report, or partial output already exists; use a fresh directory');
  command('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-xerror', '-n',
    '-framerate', String(config.fps), '-start_number', '0',
    '-i', path.join(framesDir, 'frame-%06d.png'), '-frames:v', String(config.frames),
    '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '23', '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart', partial]);
  const probe = JSON.parse(command('ffprobe', ['-v', 'error', '-count_frames',
    '-show_streams', '-show_format', '-of', 'json', partial]));
  const stream = probe.streams?.find(s => s.codec_type === 'video');
  const duration = Number(probe.format?.duration);
  requireValue(probe.streams?.length === 1 && stream?.codec_name === 'h264' &&
    stream.pix_fmt === 'yuv420p' && stream.width === config.width && stream.height === config.height &&
    Number(stream.nb_read_frames) === config.frames && Number.isFinite(duration) && duration > 0 &&
    Math.abs(duration - config.frames / config.fps) <= 1 / config.fps,
  'encoded media does not match the requested silent H.264 frame sequence');
  command('ffmpeg', ['-v', 'error', '-xerror', '-i', partial, '-f', 'null', '-']);
  fs.renameSync(partial, video);
  const result = { video, source: path.join(output, 'source.html'), ...config,
    durationSeconds: duration, bytes: fs.statSync(video).size,
    codec: stream.codec_name, pixelFormat: stream.pix_fmt, audio: false, decode: 'passed' };
  writeJSON(report, result);
  return result;
}

function encodeGif(args) {
  requireValue(args.length >= 1 && args.length <= 4,
    'encode-gif <output-dir> [width=640] [fps=12] [colors=128]');
  const [directory, widthArg = '640', fpsArg = '12', colorsArg = '128'] = args;
  const output = fs.realpathSync(directory);
  const config = readRender(output);
  const width = positive(widthArg, 'width', true);
  const gifFps = positive(fpsArg, 'fps', true);
  const colors = positive(colorsArg, 'colors', true);
  requireValue(width % 2 === 0, 'width must be even');
  requireValue(gifFps <= config.fps, 'fps must not exceed the captured frame rate');
  requireValue(colors >= 2 && colors <= 256, 'colors must be between 2 and 256');
  const framesDir = requireFrames(output, config);
  const gif = path.join(output, 'video.gif');
  const report = path.join(output, 'verification-gif.json');
  const partial = path.join(output, 'video.partial.gif');
  requireValue(!fs.existsSync(gif) && !fs.existsSync(report) && !fs.existsSync(partial),
    'gif, report, or partial output already exists; use a fresh directory');
  const height = Math.max(2, Math.round((config.height * width) / config.width / 2) * 2);
  const filter = `fps=${gifFps},scale=${width}:${height}:flags=lanczos,split[s0][s1];` +
    `[s0]palettegen=max_colors=${colors}:stats_mode=diff[p];` +
    `[s1][p]paletteuse=dither=bayer:bayer_scale=3`;
  command('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-xerror', '-n',
    '-framerate', String(config.fps), '-start_number', '0',
    '-i', path.join(framesDir, 'frame-%06d.png'), '-frames:v', String(config.frames),
    '-vf', filter, '-loop', '0', partial]);
  const probe = JSON.parse(command('ffprobe', ['-v', 'error', '-count_frames',
    '-show_streams', '-show_format', '-of', 'json', partial]));
  const stream = probe.streams?.find(s => s.codec_type === 'video');
  const duration = Number(probe.format?.duration);
  const expectedFrames = Math.round((config.frames * gifFps) / config.fps);
  requireValue(probe.streams?.length === 1 && stream?.codec_name === 'gif' &&
    stream.width === width && stream.height === height &&
    Math.abs(Number(stream.nb_read_frames) - expectedFrames) <= 1 &&
    Number.isFinite(duration) && duration > 0 &&
    Math.abs(duration - config.frames / config.fps) <= 1 / gifFps,
  'encoded GIF does not match the requested frame sequence');
  command('ffmpeg', ['-v', 'error', '-xerror', '-i', partial, '-f', 'null', '-']);
  const bytes = fs.statSync(partial).size;
  const limit = 10 * 1024 * 1024;
  requireValue(bytes <= limit,
    `GIF is ${bytes} bytes, over the 10 MB attachment limit; reduce width, fps, or colors, or use MP4`);
  fs.renameSync(partial, gif);
  const result = { gif, source: path.join(output, 'source.html'), ...config,
    gifWidth: width, gifHeight: height, gifFps, colors,
    durationSeconds: duration, bytes, codec: stream.codec_name,
    audio: false, decode: 'passed' };
  writeJSON(report, result);
  return result;
}

try {
  const [action, ...args] = process.argv.slice(2);
  requireValue(action === 'prepare' || action === 'encode' || action === 'encode-gif',
    'usage: video.mjs prepare <source.html> <new-output-dir> <seconds> [fps] [width] [height]\n' +
    '       video.mjs encode <output-dir>\n' +
    '       video.mjs encode-gif <output-dir> [width=640] [fps=12] [colors=128]');
  const result = action === 'prepare' ? prepare(args) : action === 'encode' ? encode(args) : encodeGif(args);
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(`[explain-video] ${error.message}`);
  process.exitCode = 1;
}
