#!/usr/bin/env bash
# mark.sh - draw before/after evidence marks on a page and capture a cropped PNG.
#
#   mark.sh before <target> <label>   red dashed box on the problem area
#   mark.sh after  <target> <label>   green dashed box on the changed area
#   mark.sh shot   <out.png> [margin] screenshot marks + margin, then remove them
#   mark.sh clear                     remove every mark and shot helper
#
# <target> is a snapshot ref (e123) or a unique CSS selector. Every call goes
# through pw.sh next to this script, so the session, the browser, the private
# artifact directory, and the umask stay the same as for `pw.sh open`.
#
# Environment:
#   PW_SESSION    playwright-cli session name (pw.sh default: playwright)
#   MARK_MARGIN   crop margin in CSS px (default: 120)
set -euo pipefail
umask 077

SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$SELF")" >/dev/null 2>&1 && pwd)"
PW="$SCRIPT_DIR/pw.sh"
SESSION="${PW_SESSION:-playwright}"
MARGIN="${MARK_MARGIN:-120}"
BEFORE_COLOR="#d6262b"
AFTER_COLOR="#1a8a3a"
TOKEN="$(date +%s)-$$-${RANDOM:-0}"

usage() {
  cat >&2 <<'EOF'
usage:
  mark.sh before <target> <label>    mark the problem area (red)
  mark.sh after  <target> <label>    mark the changed area (green)
  mark.sh shot   <out.png> [margin]  save marks + margin, then remove the marks
  mark.sh clear                      remove every mark and shot helper

environment: PW_SESSION (default: playwright), MARK_MARGIN (default: 120)
EOF
  exit 2
}

die() { printf 'mark.sh: %s\n' "$1" >&2; exit 1; }
bad() { printf 'mark.sh: %s\n' "$1" >&2; exit 2; }

# Every playwright-cli call goes through pw.sh: same cwd, same session, banner
# stripping, browser pinning, and the private artifact directory.
pw() { PW_SESSION="$SESSION" "$PW" "$@"; }

# jget <json> <filter>
jget() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# eval_json <js> [target] -> prints the JSON value the page returned, if any.
eval_json() {
  local js="$1" target="${2:-}" raw inner
  if [ -n "$target" ]; then
    raw="$(pw eval "$js" "$target" 2>/dev/null)" || raw=""
  else
    raw="$(pw eval "$js" 2>/dev/null)" || raw=""
  fi
  [ -n "$raw" ] || return 0
  inner="$(printf '%s\n' "$raw" | sed -n '/^### Result/,/^### /p' | sed '1d;/^### /d' | jq -r . 2>/dev/null)" || inner=""
  printf '%s' "$inner"
}

# png_dims <file> -> "<width> <height>", or a non-zero exit when the file is
# not a readable PNG. A zero exit from the CLI is not proof that an image was
# written.
png_dims() {
  local file="$1" sig w h tail_hex
  [ -f "$file" ] || return 1
  [ -s "$file" ] || return 1
  sig="$(od -An -tx1 -N8 "$file" 2>/dev/null | tr -d ' \n')" || return 1
  [ "$sig" = "89504e470d0a1a0a" ] || return 1
  w="$(od -An -tu1 -j16 -N4 "$file" 2>/dev/null | awk '{printf "%d", $1*16777216+$2*65536+$3*256+$4}')" || return 1
  h="$(od -An -tu1 -j20 -N4 "$file" 2>/dev/null | awk '{printf "%d", $1*16777216+$2*65536+$3*256+$4}')" || return 1
  case "$w$h" in ''|*[!0-9]*) return 1 ;; esac
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
  # A PNG that stops mid-file still starts with a valid signature and IHDR, so
  # also require the IEND chunk at the end.
  tail_hex="$(tail -c 12 "$file" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')" || return 1
  [ "$tail_hex" = "0000000049454e44ae426082" ] || return 1
  printf '%s %s\n' "$w" "$h"
}

MARK_JS="$(cat <<'JS'
/* mark.sh:mark */
(el) => {
  const fail = (code) => JSON.stringify({ ok: false, code: code });
  if (!el || el.ownerDocument.defaultView !== window.top) return fail('iframe');
  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  const r = el.getBoundingClientRect();
  if (!r.width && !r.height) return fail('hidden');

  // Draw inside the nearest top-layer element: a mark in <body> would be
  // painted under the dialog backdrop, and a mark placed in the dialog would be
  // painted under a popover opened inside that dialog.
  const host = (() => {
    let node = el;
    for (;;) {
      const found = [];
      try { const d = node.closest('dialog[open]'); if (d) found.push(d); } catch (e) {}
      try { const p = node.closest('[popover]:popover-open'); if (p) found.push(p); } catch (e) {}
      if (found.length === 1) return found[0];
      if (found.length > 1) {
        // Nested top-layer elements: the inner one paints on top.
        const a = found[0], b = found[1];
        if (a.contains(b)) return b;
        if (b.contains(a)) return a;
        return b;
      }
      const root = node.getRootNode && node.getRootNode();
      node = root && root.host ? root.host : null;
      if (!node) break;
    }
    const root = el.getRootNode();
    return root && root.host ? root : document.body;
  })();

  const Z = '2147483647';
  const box = document.createElement('div');
  box.setAttribute('data-evidence-mark', '');
  Object.assign(box.style, {
    position: 'fixed', left: '0px', top: '0px', width: '0px', height: '0px',
    border: '2px dashed __COLOR__', borderRadius: '8px', boxSizing: 'border-box',
    pointerEvents: 'none', zIndex: Z, margin: '0', padding: '0', background: 'transparent',
  });
  const tag = document.createElement('div');
  tag.setAttribute('data-evidence-mark', '');
  tag.textContent = __LABEL__;
  Object.assign(tag.style, {
    position: 'fixed', left: '0px', top: '0px', background: '__COLOR__', color: '#fff',
    font: '700 12px/1 system-ui, -apple-system, "Segoe UI", sans-serif', padding: '4px 7px',
    borderRadius: '4px', whiteSpace: 'nowrap', pointerEvents: 'none', zIndex: Z, margin: '0',
  });
  host.append(box, tag);

  // A box parked at (0,0) measures the origin of the mark's containing block.
  // With a transform, filter, or contain on an ancestor that is the host, the
  // origin is not the viewport, and the mark must stay inside the host.
  const o = box.getBoundingClientRect();
  const ox = Math.abs(o.left) < 0.5 ? 0 : o.left;
  const oy = Math.abs(o.top) < 0.5 ? 0 : o.top;
  const vw = document.documentElement.clientWidth;
  const vh = document.documentElement.clientHeight;
  let lim = { left: 0, top: 0, right: vw, bottom: vh };
  if ((ox || oy) && host.getBoundingClientRect) {
    const h = host.getBoundingClientRect();
    const hl = h.left + (host.clientLeft || 0);
    const ht = h.top + (host.clientTop || 0);
    lim = {
      left: Math.max(0, hl), top: Math.max(0, ht),
      right: Math.min(vw, hl + (host.clientWidth || 0)),
      bottom: Math.min(vh, ht + (host.clientHeight || 0)),
    };
  }

  const pad = 4;
  const L = Math.max(r.left - pad, lim.left + 1);
  const T = Math.max(r.top - pad, lim.top + 1);
  const R = Math.min(r.right + pad, lim.right - 1);
  const B = Math.min(r.bottom + pad, lim.bottom - 1);
  if (R - L < 8 || B - T < 8) { box.remove(); tag.remove(); return fail('outside'); }

  Object.assign(box.style, {
    left: (L - ox) + 'px', top: (T - oy) + 'px', width: (R - L) + 'px', height: (B - T) + 'px',
  });

  // Label above the right corner; below the box when the top is clipped; inside
  // the box when the bottom is clipped too.
  const t = tag.getBoundingClientRect();
  let top = T - t.height + 4;
  if (top < lim.top + 2) top = B - 4;
  if (top + t.height > lim.bottom - 2) top = T + 4;
  const left = Math.min(Math.max(lim.left + 2, R - t.width - 6), lim.right - t.width - 2);
  tag.style.left = (left - ox) + 'px';
  tag.style.top = (top - oy) + 'px';

  if (box.checkVisibility && !box.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) {
    box.remove(); tag.remove(); return fail('not-visible');
  }
  return JSON.stringify({ ok: true, w: Math.round(r.width), h: Math.round(r.height) });
}
JS
)"

SHOT_JS="$(cat <<'JS'
/* mark.sh:shot */
() => {
  const fail = (code) => JSON.stringify({ ok: false, code: code });
  // Marks can sit in the document, in an open shadow root, or in a dialog.
  const roots = [document];
  const walk = (root) => {
    root.querySelectorAll('*').forEach((n) => {
      if (n.shadowRoot) { roots.push(n.shadowRoot); walk(n.shadowRoot); }
    });
  };
  walk(document);
  const marks = [];
  roots.forEach((r) => marks.push(...r.querySelectorAll('[data-evidence-mark]')));
  if (!marks.length) return fail('no-marks');
  roots.forEach((r) => r.querySelectorAll('[data-evidence-shot]').forEach((n) => n.remove()));

  const rs = marks.map((n) => n.getBoundingClientRect());
  const m = __MARGIN__;
  const vw = document.documentElement.clientWidth;
  const vh = document.documentElement.clientHeight;
  let l = Math.max(0, Math.min(...rs.map((x) => x.left)) - m);
  let t = Math.max(0, Math.min(...rs.map((x) => x.top)) - m);
  let r = Math.min(vw, Math.max(...rs.map((x) => x.right)) + m);
  let b = Math.min(vh, Math.max(...rs.map((x) => x.bottom)) + m);

  // The helper always lives in <body> and spans the union of every mark, so
  // marks placed in different hosts (page, dialog, popover) end up in one
  // capture. An element screenshot records the rendered pixels of its box,
  // including top-layer content painted above it.
  const host = document.body || document.documentElement;
  const d = document.createElement('div');
  d.setAttribute('data-evidence-shot', __TOKEN__);
  Object.assign(d.style, {
    all: 'initial', position: 'fixed', left: '0px', top: '0px', width: '0px', height: '0px',
    background: 'transparent', pointerEvents: 'none', zIndex: '1', margin: '0', padding: '0', border: '0',
  });
  host.append(d);

  // A body-level helper is positioned from the viewport, unless an ancestor
  // creates a containing block for fixed elements (for example a transformed
  // body). Measure the origin and place the helper relative to it. The body's
  // layout size does not limit the capture: a top-layer dialog can be larger
  // than a body whose children are all fixed, so clamp to the viewport only.
  const o = d.getBoundingClientRect();
  const ox = Math.abs(o.left) < 0.5 ? 0 : o.left;
  const oy = Math.abs(o.top) < 0.5 ? 0 : o.top;
  if (r - l < 1 || b - t < 1) { d.remove(); return fail('outside'); }
  Object.assign(d.style, {
    left: (l - ox) + 'px', top: (t - oy) + 'px',
    width: (r - l) + 'px', height: (b - t) + 'px',
  });
  return JSON.stringify({ ok: true, l: l, t: t, w: r - l, h: b - t, token: __TOKEN__ });
}
JS
)"

DROP_SHOT_JS="$(cat <<'JS'
/* mark.sh:drop-shot */
() => {
  const roots = [document];
  const walk = (root) => {
    root.querySelectorAll('*').forEach((n) => {
      if (n.shadowRoot) { roots.push(n.shadowRoot); walk(n.shadowRoot); }
    });
  };
  walk(document);
  roots.forEach((r) => r.querySelectorAll('[data-evidence-shot]').forEach((n) => n.remove()));
  return JSON.stringify({ ok: true });
}
JS
)"

CLEAR_JS="$(cat <<'JS'
/* mark.sh:clear */
() => {
  const roots = [document];
  const walk = (root) => {
    root.querySelectorAll('*').forEach((n) => {
      if (n.shadowRoot) { roots.push(n.shadowRoot); walk(n.shadowRoot); }
    });
  };
  walk(document);
  let cleared = 0;
  roots.forEach((r) => r.querySelectorAll('[data-evidence-mark],[data-evidence-shot]').forEach((n) => { n.remove(); cleared += 1; }));
  return JSON.stringify({ ok: true, cleared: cleared });
}
JS
)"

# replace_literal <text> <needle> <replacement>
# Literal replacement: bash pattern substitution treats & in the replacement
# specially, so labels like "A&B" would be mangled.
replace_literal() {
  local hay="$1" needle="$2" repl="$3" out='' head
  while :; do
    case "$hay" in
      *"$needle"*)
        head="${hay%%"$needle"*}"
        out="$out$head$repl"
        hay="${hay#*"$needle"}"
        ;;
      *) break ;;
    esac
  done
  printf '%s%s' "$out" "$hay"
}

render() { # render <template> [KEY=VALUE...]
  local out="$1"; shift
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"
    out="$(replace_literal "$out" "__${key}__" "$val")"
  done
  printf '%s' "$out"
}

label_json() { printf '%s' "$1" | jq -Rs .; }

clear_marks() {
  local res cleared
  res="$(eval_json "$CLEAR_JS")"
  if [ -z "$res" ]; then
    local msg
    msg="$(pw eval "$CLEAR_JS" 2>&1)" || true
    case "$msg" in
      *"is not open"*)
        printf 'nothing to clear: the session is not open\n'
        return 0 ;;
    esac
    printf 'mark.sh: could not clear marks (check PW_SESSION and the cwd used for pw.sh open)\n' >&2
    return 1
  fi
  cleared="$(jget "$res" '.cleared // 0')"
  printf 'cleared: %s\n' "${cleared:-0}"
}

case "${1:-}" in
  before|after)
    kind="$1"
    target="${2:-}"; label="${3:-}"
    [ -n "$target" ] || usage
    [ -n "$label" ] || usage
    length="$(printf '%s' "$label" | jq -Rr 'length')"
    case "$length" in ''|*[!0-9]*) die "could not read the label length" ;; esac
    if [ "$length" -lt 1 ] || [ "$length" -gt 8 ]; then
      bad "the label must be 1-8 characters (got $length)"
    fi
    if [ "$kind" = before ]; then color="$BEFORE_COLOR"; else color="$AFTER_COLOR"; fi
    js="$(render "$MARK_JS" "LABEL=$(label_json "$label")" "COLOR=$color")"
    res="$(eval_json "$js" "$target")"
    if [ -z "$res" ]; then
      printf '%s\n' "mark.sh: could not mark (no result). Check the target ref/selector, PW_SESSION, and the cwd used for pw.sh open." >&2
      exit 1
    fi
    if [ "$(jget "$res" '.ok')" != "true" ]; then
      code="$(jget "$res" '.code')"
      case "$code" in
        iframe) die "cannot mark inside an iframe; mark the iframe element itself" ;;
        hidden) die "cannot mark a zero-size element; make it visible first" ;;
        outside) die "the element is outside the viewport (or outside its dialog); bring it into view first" ;;
        not-visible) die "the mark is not visible (closed shadow root or clipped); capture an unmarked screenshot and record why" ;;
        *) die "could not mark the target (not found, not unique, or the mark did not render)" ;;
      esac
    fi
    printf 'marked: %sx%s\n' "$(jget "$res" '.w')" "$(jget "$res" '.h')" ;;
  shot)
    out="${2:-}"; margin="${3:-$MARGIN}"
    [ -n "$out" ] || usage
    case "$margin" in ''|*[!0-9]*) usage ;; esac
    case "$out" in
      /*) ;;
      *) bad "the output path must be absolute (put it under PW_ARTIFACT_DIR)" ;;
    esac
    case "$out" in
      *.png) ;;
      *) bad "the output must be a .png file" ;;
    esac
    [ -f "$PW" ] || die "pw.sh is missing next to mark.sh: $PW"
    mkdir -p "$(dirname "$out")"

    rect="$(eval_json "$(render "$SHOT_JS" "MARGIN=$margin" "TOKEN=$(label_json "$TOKEN")")")"
    if [ -z "$rect" ] || [ "$(jget "$rect" '.ok')" != "true" ]; then
      code="$(jget "$rect" '.code')"
      case "$code" in
        no-marks) die "no marks. Run before/after first." ;;
        outside) die "the marks are outside the viewport; scroll back before marking" ;;
        *) die "could not read the marks. Check PW_SESSION and the cwd used for pw.sh open." ;;
      esac
    fi
    token="$(jget "$rect" '.token')"
    selector="[data-evidence-shot=\"$token\"]"

    if ! pw screenshot "$selector" --filename="$out" >/dev/null 2>&1; then
      eval_json "$DROP_SHOT_JS" >/dev/null 2>&1 || true
      printf 'mark.sh: the screenshot failed. Marks are kept; fix the cause and run shot again, or run clear.\n' >&2
      exit 1
    fi
    if ! dims="$(png_dims "$out")"; then
      printf 'mark.sh: the screenshot did not produce a readable PNG. Marks are kept; fix the cause and run shot again, or run clear.\n' >&2
      exit 1
    fi
    chmod 600 "$out" 2>/dev/null || true
    bytes="$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out" 2>/dev/null || printf '?')"
    clear_marks >/dev/null 2>&1 || printf 'mark.sh: warning: the marks were not removed; run mark.sh clear\n' >&2
    printf 'saved: %s %s bytes=%s\n' "$out" "$dims" "$bytes" ;;
  clear)
    clear_marks ;;
  *) usage ;;
esac
