import Foundation

// InspectorScript: the vanilla-JS inspector injected into the Studio preview's
// ISOLATED content world (the WKUserScript in .world(name: "gruxInspector") set up
// by the studio-core preview view, per the UI architecture contract section 4.5).
// It gives the user click-to-select over the generated design without the page's own
// JS ever seeing it, and it feeds the surgical-edit flow: the selector it posts is
// exactly what SurgicalEditEngine.locate consumes.
//
// What it does, all defensively wrapped so a broken generated page cannot throw
// out of the inspector:
//   - hover: draws a 2px accent outline using a SINGLE absolutely positioned
//     overlay div, never by mutating the hovered element's own styles (so it
//     leaves no trace and cannot disturb the layout it is measuring).
//   - click: posts { selector, rect, computedStyles (color, background, fontSize,
//     fontFamily), textContent trimmed to 200 } to
//     window.webkit.messageHandlers.gruxInspect. The selector prefers an id, then
//     a tag.class chain up to four levels, with an nth-child fallback for a
//     segment that has no classes, matching SurgicalEditEngine's locator shapes.
//   - applyRecolor(brandHexes): snap-to-brand. Walks every element and swaps its
//     text and background color to the NEAREST color in the provided brand-token
//     hex array, so a one-tap "make it on-brand" recolor is possible.
//   - clearInspect(): hides the overlay and undoes every recolor.
//
// The Swift side calls window.__gruxInspector.applyRecolor(...) / clearInspect()
// via evaluateJavaScript in the SAME isolated world.
//
// House rule: zero em/en dashes anywhere, including these JS strings.

enum InspectorScript {

    // The isolated-world inspector. Raw string so the regex backslashes stay
    // literal (a plain Swift string would read "\(" as interpolation).
    static let script: String = #"""
    (function(){
      try {
        if (window.__gruxInspectorInstalled) { return; }
        window.__gruxInspectorInstalled = true;

        var ACCENT = '#7C5CFF';
        var overlay = null;
        var active = true;

        function ensureOverlay(){
          if (overlay) { return overlay; }
          overlay = document.createElement('div');
          overlay.setAttribute('data-grux-overlay', '1');
          var s = overlay.style;
          s.position = 'fixed';
          s.pointerEvents = 'none';
          s.zIndex = '2147483647';
          s.border = '2px solid ' + ACCENT;
          s.borderRadius = '3px';
          s.boxShadow = '0 0 0 2px rgba(124,92,255,0.25)';
          s.transition = 'all 60ms ease';
          s.display = 'none';
          (document.body || document.documentElement).appendChild(overlay);
          return overlay;
        }

        function positionOverlay(el){
          try {
            var r = el.getBoundingClientRect();
            var o = ensureOverlay();
            o.style.display = 'block';
            o.style.left = r.left + 'px';
            o.style.top = r.top + 'px';
            o.style.width = r.width + 'px';
            o.style.height = r.height + 'px';
          } catch (e) {}
        }

        function hideOverlay(){ if (overlay) { overlay.style.display = 'none'; } }

        function isOwn(el){
          return !el || el === overlay || (el.getAttribute && el.getAttribute('data-grux-overlay'));
        }

        function cssEscape(s){
          try { if (window.CSS && CSS.escape) { return CSS.escape(s); } } catch (e) {}
          return String(s).replace(/[^a-zA-Z0-9_-]/g, '');
        }

        function nthChild(el){
          try {
            var i = 1; var sib = el;
            while (sib.previousElementSibling){ sib = sib.previousElementSibling; i++; }
            return i;
          } catch (e) { return 1; }
        }

        // Prefer an id; else a tag.class chain up to four levels; nth-child
        // disambiguates a segment with no classes. Matches the locator shapes.
        function buildSelector(el){
          try {
            if (el.id) { return '#' + cssEscape(el.id); }
            var parts = [];
            var node = el;
            var depth = 0;
            while (node && node.nodeType === 1 && depth < 4) {
              if (node.id) { parts.unshift('#' + cssEscape(node.id)); break; }
              var tag = node.tagName ? node.tagName.toLowerCase() : 'div';
              var seg = tag;
              if (node.classList && node.classList.length) {
                var cls = [];
                for (var i = 0; i < node.classList.length && i < 3; i++){ cls.push(cssEscape(node.classList[i])); }
                seg = tag + '.' + cls.join('.');
              } else {
                seg = tag + ':nth-child(' + nthChild(node) + ')';
              }
              parts.unshift(seg);
              node = node.parentElement;
              depth++;
            }
            return parts.join(' > ');
          } catch (e) { return (el && el.tagName ? el.tagName.toLowerCase() : '*'); }
        }

        function styleSubset(el){
          var out = { color: '', background: '', fontSize: '', fontFamily: '' };
          try {
            var cs = window.getComputedStyle(el);
            out.color = cs.color || '';
            out.background = cs.backgroundColor || '';
            out.fontSize = cs.fontSize || '';
            out.fontFamily = cs.fontFamily || '';
          } catch (e) {}
          return out;
        }

        function post(payload){
          try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gruxInspect) {
              window.webkit.messageHandlers.gruxInspect.postMessage(payload);
            }
          } catch (e) {}
        }

        function onOver(ev){
          if (!active) { return; }
          var el = ev.target;
          if (isOwn(el)) { return; }
          positionOverlay(el);
        }
        function onOut(ev){ if (!active) { return; } hideOverlay(); }

        function onClick(ev){
          if (!active) { return; }
          var el = ev.target;
          if (isOwn(el)) { return; }
          try { ev.preventDefault(); ev.stopPropagation(); } catch (e) {}
          var rect = {};
          try { var r = el.getBoundingClientRect(); rect = { x: r.left, y: r.top, width: r.width, height: r.height }; } catch (e) {}
          var text = '';
          try { text = (el.textContent || '').trim().slice(0, 200); } catch (e) {}
          post({
            selector: buildSelector(el),
            rect: rect,
            computedStyles: styleSubset(el),
            textContent: text
          });
        }

        document.addEventListener('mouseover', onOver, true);
        document.addEventListener('mouseout', onOut, true);
        document.addEventListener('click', onClick, true);

        // Color helpers for snap-to-brand recolor.
        function parseColor(str){
          try {
            str = String(str).trim();
            if (str.charAt(0) === '#') {
              var hex = str.slice(1);
              if (hex.length === 3) { hex = hex.charAt(0)+hex.charAt(0)+hex.charAt(1)+hex.charAt(1)+hex.charAt(2)+hex.charAt(2); }
              if (hex.length >= 6) {
                return [parseInt(hex.slice(0,2),16), parseInt(hex.slice(2,4),16), parseInt(hex.slice(4,6),16)];
              }
            }
            var m = str.match(/rgba?\(([^)]+)\)/);
            if (m) {
              var p = m[1].split(',');
              return [parseInt(p[0],10), parseInt(p[1],10), parseInt(p[2],10)];
            }
          } catch (e) {}
          return null;
        }
        function dist(a, b){
          var dr=a[0]-b[0], dg=a[1]-b[1], db=a[2]-b[2];
          return dr*dr + dg*dg + db*db;
        }
        function nearest(rgb, palette){
          var best = null; var bestD = Infinity;
          for (var i=0;i<palette.length;i++){
            var pr = parseColor(palette[i]);
            if (!pr) { continue; }
            var d = dist(rgb, pr);
            if (d < bestD){ bestD = d; best = palette[i]; }
          }
          return best;
        }

        // Snap every element's text and background color to the nearest brand token
        // in the provided hex array. Inline styles are marked so clearInspect undoes them.
        function applyRecolor(brandHexes){
          try {
            if (!brandHexes || !brandHexes.length) { return; }
            var all = document.querySelectorAll('body *');
            for (var i=0;i<all.length;i++){
              var el = all[i];
              if (isOwn(el)) { continue; }
              try {
                var cs = window.getComputedStyle(el);
                var fg = parseColor(cs.color);
                if (fg) { var nfg = nearest(fg, brandHexes); if (nfg) { el.style.color = nfg; el.setAttribute('data-grux-recolored','1'); } }
                var bgStr = cs.backgroundColor;
                if (bgStr && bgStr.indexOf('rgba(0, 0, 0, 0)') === -1 && bgStr !== 'transparent') {
                  var bg = parseColor(bgStr);
                  if (bg) { var nbg = nearest(bg, brandHexes); if (nbg) { el.style.backgroundColor = nbg; el.setAttribute('data-grux-recolored','1'); } }
                }
              } catch (e) {}
            }
          } catch (e) {}
        }

        function clearInspect(){
          try {
            active = false;
            hideOverlay();
            var recolored = document.querySelectorAll('[data-grux-recolored]');
            for (var i=0;i<recolored.length;i++){
              recolored[i].style.color = '';
              recolored[i].style.backgroundColor = '';
              recolored[i].removeAttribute('data-grux-recolored');
            }
          } catch (e) {}
        }

        function setActive(v){ active = !!v; if (!active) { hideOverlay(); } }

        window.__gruxInspector = {
          applyRecolor: applyRecolor,
          clearInspect: clearInspect,
          setActive: setActive
        };
      } catch (e) {}
    })();
    """#
}
