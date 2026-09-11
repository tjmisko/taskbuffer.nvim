local wezterm = require("wezterm")

return {
    color_scheme = "Catppuccin Mocha",
    font = wezterm.font_with_fallback({ "JetBrains Mono", "monospace" }),
    font_size = 20,
    initial_cols = 110,
    initial_rows = 34,
    enable_tab_bar = false,
    window_background_opacity = 1,
    window_padding = { left = 24, right = 24, top = 16, bottom = 16 },
    default_cursor_style = "SteadyBlock",
    audible_bell = "Disabled",
    check_for_updates = false,
}
