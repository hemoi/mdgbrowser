# SwiftTerm provenance

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Revision: `e0784f4291dcdae078b86f6182f32697b4a51c8d`
- Retrieved: 2026-07-10
- License: MIT; see `LICENSE`.

This snapshot includes CJK full-width glyph centering, CoreGraphics
scroll/rendering fixes, and correct left-button mouse reporting. A local patch
based on upstream commit `05361a42f0de3336e6ac2e6a37b966760e395691`
preserves the previous Korean syllable when a final consonant is reinterpreted
before a following vowel (for example, `핫` + `ㅔ` becomes `하세`). The upstream
commit was reverted from `main` as a wrong-branch change and issue #563 remains
open, so the pure transformation has dedicated app tests here.

SwiftTerm is built as a Swift 5 static framework from the vendored Swift
sources. `Shaders.metal` is intentionally not placed in an Xcode resources
build phase because Metal rendering is optional, disabled by default, and the
standalone Metal toolchain is not present on every development machine. The app
uses SwiftTerm's CoreGraphics renderer.
