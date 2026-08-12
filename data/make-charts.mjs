#!/usr/bin/env node
// Renders the raw measurement logs as static inline SVG for the case-study
// pages. Static because andruxa.dev runs a strict CSP (`default-src 'self'`,
// no unsafe-inline scripts) — a charting library would need an external origin
// or inline JS, and both are hard stops on that site.
//
// Colours are CSS custom properties from the site theme, so the charts follow
// the page rather than hardcoding hex values.
//
//   node make-charts.mjs            writes ./charts/*.svg
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, 'charts');
mkdirSync(out, { recursive: true });

const read = (f) => readFileSync(join(here, f), 'utf8').split('\n').filter(Boolean);

/**
 * Merge runs of identical colour into one rect. Lossless — every sample is
 * still represented, at the same x position — but a 638-sample strip becomes
 * a handful of rects instead of 638, which took one chart from 55 KB to under
 * 2 KB. Page weight matters: these are inlined and the site gates on
 * Lighthouse >= 0.95.
 */
function runs(colours) {
  const out = [];
  for (let i = 0; i < colours.length; i++) {
    const last = out[out.length - 1];
    if (last && last.fill === colours[i]) last.len++;
    else out.push({ start: i, len: 1, fill: colours[i] });
  }
  return out;
}

/** Bar of samples over time: green where 200, red where not. */
function timeline({ samples, width = 720, height = 96, title, desc, marks = [] }) {
  const n = samples.length;
  const barW = width / n;
  const bars = runs(samples.map((ok) =>
    ok ? 'var(--status-green, #5ad17e)' : 'var(--danger, #f97373)'))
    .map(({ start, len, fill }) =>
      `<rect x="${(start * barW).toFixed(2)}" y="0" width="${(len * barW + 0.4).toFixed(2)}" height="56" fill="${fill}"/>`)
    .join('');

  const markers = marks
    .map(({ at, label }) => {
      const x = (at * barW).toFixed(2);
      const anchor = at / n > 0.75 ? 'end' : at / n < 0.08 ? 'start' : 'middle';
      return `<line x1="${x}" y1="-6" x2="${x}" y2="62" stroke="var(--text, #eef1f4)" stroke-width="1.5" stroke-dasharray="3 3"/>
      <text x="${x}" y="78" text-anchor="${anchor}" font-size="11" font-family="ui-monospace, monospace" fill="var(--text, #eef1f4)">${label}</text>`;
    })
    .join('');

  // Slugify: an id must not contain whitespace. Using the title raw produced
  // `id="t-Blue-green cutover"`, which html-validate rejects (valid-id,
  // attribute-allowed-values) — 12 errors caught by the site's own gate.
  const id = title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

  return `<svg viewBox="0 -12 ${width} ${height}" width="100%" role="img" aria-labelledby="t-${id} d-${id}" xmlns="http://www.w3.org/2000/svg">
  <title id="t-${id}">${title}</title>
  <desc id="d-${id}">${desc}</desc>
  <g>${bars}</g>
  ${markers}
</svg>`;
}

// ---------------------------------------------------------------- S4 ------
// Three scenarios on one fleet. The point is the contrast, so they share a
// renderer and sit on the page as three stacked strips.
const cutover = read('s4-cutover.log').map((l) => l.startsWith('200'));
const refresh = read('s4-rolling-refresh.log').map((l) => l.startsWith('200'));
const kill = read('s4-abrupt-termination.log').map((l) => l.trim() === '200');

const killFirstBad = kill.findIndex((ok) => !ok);
const killLastBad = kill.length - 1 - [...kill].reverse().findIndex((ok) => !ok);

writeFileSync(join(out, 's4-cutover.svg'), timeline({
  samples: cutover, title: 'Blue-green cutover',
  desc: `${cutover.length} requests across a listener swap, all HTTP 200. Zero requests lost.`,
  marks: [{ at: 4, label: 'switch issued' }],
}));

writeFileSync(join(out, 's4-rolling-refresh.svg'), timeline({
  samples: refresh, title: 'Rolling instance refresh',
  desc: `${refresh.length} requests across a 430-second instance refresh, all HTTP 200. Both v1.0 and v1.1 served during the roll.`,
}));

writeFileSync(join(out, 's4-abrupt-termination.svg'), timeline({
  samples: kill, title: 'Abrupt termination',
  desc: `${kill.length} requests while an in-service instance was terminated out of band. ${kill.filter((k) => !k).length} failed — 19 HTTP 502 and 7 connection failures.`,
  marks: [
    { at: 29, label: 'terminated' },
    { at: killFirstBad, label: 'first 502' },
    { at: killLastBad, label: 'recovered' },
  ],
}));

// ---------------------------------------------------------------- S9 ------
// Region-coloured, because "which region answered" is the story rather than
// simply pass/fail.
const s9 = read('s9-failover.log')
  .map((l) => l.split(/\s+/))
  .filter((p) => p.length === 3)
  .map(([ts, code, region]) => ({ ts: +ts, code, region }));

// Timings are relative to the moment the break was ISSUED, which the poller
// recorded as a marker line. Measuring from the first 503 instead would
// understate the outage by the ~4s the ALB spent draining.
const breakTs = Number(
  readFileSync(join(here, 's9-failover.log'), 'utf8')
    .split('\n').find((l) => l.includes('BREAKING'))?.split(/\s+/)[0]);

const firstBad = s9.findIndex((s) => s.code !== '200');
const flipAt = s9.findIndex((s) => s.region === 'us-west-2');
const lastBad = s9.length - 1 - [...s9].reverse().findIndex((s) => s.code !== '200');
const backAt = s9.findIndex((s, i) => i > flipAt && s.region === 'us-east-1');
const rel = (i) => s9[i].ts - breakTs;

const w = 720, bw = w / s9.length;
const s9bars = runs(s9.map((s) =>
  s.code !== '200'
    ? 'var(--danger, #f97373)'
    : s.region === 'us-east-1'
      ? 'var(--cloud, #46c5e6)'
      : 'var(--status-green, #5ad17e)'))
  .map(({ start, len, fill }) =>
    `<rect x="${(start * bw).toFixed(2)}" y="0" width="${(len * bw + 0.4).toFixed(2)}" height="56" fill="${fill}"/>`)
  .join('');

const s9marks = [
  { at: firstBad, label: `503s begin +${rel(firstBad)}s` },
  { at: flipAt, label: `us-west-2 +${rel(flipAt)}s` },
  { at: backAt, label: 'failed back' },
].map(({ at, label }) => {
  const x = (at * bw).toFixed(2);
  const anchor = at / s9.length > 0.7 ? 'end' : at / s9.length < 0.1 ? 'start' : 'middle';
  return `<line x1="${x}" y1="-6" x2="${x}" y2="62" stroke="var(--text, #eef1f4)" stroke-width="1.5" stroke-dasharray="3 3"/>
  <text x="${x}" y="78" text-anchor="${anchor}" font-size="11" font-family="ui-monospace, monospace" fill="var(--text, #eef1f4)">${label}</text>`;
}).join('');

writeFileSync(join(out, 's9-failover.svg'), `<svg viewBox="0 -12 ${w} 96" width="100%" role="img" aria-labelledby="t-s9 d-s9" xmlns="http://www.w3.org/2000/svg">
  <title id="t-s9">Global Accelerator failover and failback</title>
  <desc id="d-s9">${s9.length} requests. Blue is us-east-1, green is us-west-2, red is HTTP 503. ${s9.filter(s => s.code !== '200').length} of ${s9.length} failed. Failover completed ${rel(flipAt)} seconds after the break was issued; errors ran from +${rel(firstBad)}s to +${rel(lastBad)}s.</desc>
  <g>${s9bars}</g>
  ${s9marks}
</svg>`);

console.log(`s4-cutover            ${cutover.length} samples, ${cutover.filter(x => !x).length} failed`);
console.log(`s4-rolling-refresh    ${refresh.length} samples, ${refresh.filter(x => !x).length} failed`);
console.log(`s4-abrupt-termination ${kill.length} samples, ${kill.filter(x => !x).length} failed`);
console.log(`s9-failover           ${s9.length} samples, ${s9.filter(s => s.code !== '200').length} failed`);
console.log(`s9 timings (from break issued): first 503 +${rel(firstBad)}s | us-west-2 +${rel(flipAt)}s | last failure +${rel(lastBad)}s`);
