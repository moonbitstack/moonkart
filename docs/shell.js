// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
//
// A scroll bar cut into the carton's right wall. The native bar is hidden, so
// this one has to do the whole job: track the scroll position, answer a drag,
// and stay out of the way of a pointer that is only passing through.

(() => {
  const rail = document.querySelector(".rail");
  const thumb = document.querySelector(".rail__thumb");
  if (!rail || !thumb) return;

  const root = document.documentElement;
  const MIN = 54;
  let dragging = false;
  let grab = 0;

  function metrics() {
    const view = root.clientHeight;
    const total = root.scrollHeight;
    const track = rail.clientHeight;
    const span = total - view;
    const size = Math.max(MIN, Math.round((view / total) * track));
    return { view, total, track, span, size, travel: track - size };
  }

  function place() {
    const m = metrics();
    if (m.span <= 0) {
      rail.hidden = true;
      root.classList.remove("at-top");
      return;
    }
    rail.hidden = false;
    thumb.style.height = m.size + "px";
    const progress = Math.min(1, Math.max(0, root.scrollTop / m.span));
    thumb.style.transform = "translateY(" + Math.round(progress * m.travel) + "px)";
    root.classList.toggle("at-top", root.scrollTop < 4);
    root.classList.toggle("at-end", root.scrollTop > m.span - 4);
  }

  function to(y) {
    const m = metrics();
    if (m.span <= 0) return;
    const t = Math.min(1, Math.max(0, (y - grab) / m.travel));
    root.scrollTop = t * m.span;
  }

  thumb.addEventListener("pointerdown", (e) => {
    dragging = true;
    grab = e.clientY - thumb.getBoundingClientRect().top;
    thumb.setPointerCapture(e.pointerId);
    root.classList.add("scrolling");
    e.preventDefault();
  });

  thumb.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const railTop = rail.getBoundingClientRect().top;
    to(e.clientY - railTop);
  });

  const drop = (e) => {
    if (!dragging) return;
    dragging = false;
    root.classList.remove("scrolling");
    if (e.pointerId !== undefined && thumb.hasPointerCapture?.(e.pointerId)) {
      thumb.releasePointerCapture(e.pointerId);
    }
  };
  thumb.addEventListener("pointerup", drop);
  thumb.addEventListener("pointercancel", drop);

  rail.addEventListener("pointerdown", (e) => {
    if (e.target === thumb) return;
    const m = metrics();
    const top = rail.getBoundingClientRect().top;
    const target = root.scrollTop + (e.clientY - top < thumb.offsetTop ? -m.view : m.view);
    root.scrollTo({ top: target, behavior: "smooth" });
  });

  addEventListener("scroll", place, { passive: true });
  addEventListener("resize", place);
  if (document.fonts) document.fonts.ready.then(place);
  place();
})();
