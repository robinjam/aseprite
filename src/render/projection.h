// Aseprite Render Library
// Copyright (c) 2016 David Capello
//
// This file is released under the terms of the MIT license.
// Read LICENSE.txt for more information.

#ifndef RENDER_PROJECTION_H_INCLUDED
#define RENDER_PROJECTION_H_INCLUDED
#pragma once

#include "doc/pixel_ratio.h"
#include "render/zoom.h"

namespace render {

  class Projection {
  public:
    Projection()
      : m_pixelRatio(1, 1),
        m_zoom(1, 1) {
    }

    Projection(const doc::PixelRatio& pixelRatio,
               const Zoom& zoom)
      : m_pixelRatio(pixelRatio),
        m_zoom(zoom) {
    }

    const doc::PixelRatio& pixelRatio() const { return m_pixelRatio; }
    const Zoom& zoom() const { return m_zoom; }

    void setPixelRatio(const doc::PixelRatio& pixelRatio) { m_pixelRatio = pixelRatio; }
    void setZoom(const Zoom& zoom) { m_zoom = zoom; }

    double scaleX() const { return m_zoom.scale() * m_pixelRatio.w; }
    double scaleY() const { return m_zoom.scale() * m_pixelRatio.h; }

    template<typename T>
    T applyX(T x) const { return m_zoom.apply(x * m_pixelRatio.w); }

    template<typename T>
    T applyY(T y) const { return m_zoom.apply(y * m_pixelRatio.h); }

    template<typename T>
    T removeX(T x) const { return m_zoom.remove(x) / m_pixelRatio.w; }

    template<typename T>
    T removeY(T y) const { return m_zoom.remove(y) / m_pixelRatio.h; }

    gfx::Rect apply(const gfx::Rect& r) const {
      int u = applyX(r.x);
      int v = applyY(r.y);
      return gfx::Rect(u, v,
                       applyX(r.x+r.w) - u,
                       applyY(r.y+r.h) - v);
    }

    gfx::RectF apply(const gfx::RectF& r) const {
      double u = applyX(r.x);
      double v = applyY(r.y);
      return gfx::RectF(u, v,
                        applyX(r.x+r.w) - u,
                        applyY(r.y+r.h) - v);
    }

    gfx::Rect remove(const gfx::Rect& r) const {
      int u = removeX(r.x);
      int v = removeY(r.y);
      return gfx::Rect(u, v,
                       removeX(r.x+r.w) - u,
                       removeY(r.y+r.h) - v);
    }

    gfx::RectF remove(const gfx::RectF& r) const {
      double u = removeX(r.x);
      double v = removeY(r.y);
      return gfx::RectF(u, v,
                        removeX(r.x+r.w) - u,
                        removeY(r.y+r.h) - v);
    }

  private:
    doc::PixelRatio m_pixelRatio;
    Zoom m_zoom;
  };

} // namespace render

#endif