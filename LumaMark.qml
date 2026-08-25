import QtQuick

// The Luma four-pointed star, tinted at runtime. Qt's SVG renderer has no
// currentColor support, so the fill is baked into a data URI bound to the
// tint color — the mark follows the theme like a glyph would.
Image {
  id: root

  property color tint: "white"

  readonly property string pathData: "M133 67C96.282 67 66.5 36.994 66.5 0c0 36.994-29.782 67-66.5 67 36.718 0 66.5 30.006 66.5 67 0-36.994 29.782-67 66.5-67"

  function cssColor(c) {
    return "rgb(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + ")"
  }

  source: "data:image/svg+xml;utf8," + encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 133 134"><path fill="'
    + cssColor(tint) + '" d="' + pathData + '"/></svg>')
  sourceSize.width: Math.max(1, width * 2)
  sourceSize.height: Math.max(1, height * 2)
  fillMode: Image.PreserveAspectFit
}
