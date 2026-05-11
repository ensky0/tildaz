//! Font configuration limits shared by config parsing and platform font backends.

/// Maximum number of explicit font families in the rendering chain:
/// primary `font.family` + `font.glyph_fallback` entries.
pub const MAX_CHAIN: usize = 8;
