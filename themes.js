// Palettes and config defaults, kept out of island.qml so adding a theme is a
// data change rather than a surgery on the surface.
//
// Every palette answers the same fourteen questions. Six are ground and type --
// one luminance ramp from the bar's near-black up to a title. The other eight
// are the status hues, and they are not decoration: a lane is 5px tall, so two
// neighbouring hues read as one colour. Keep `flow`, `mull` and `signal_` far
// apart on the wheel or the bar stops saying anything.
.pragma library

var defaults = {
    position:   "bottom",   // bottom | top
    monitors:   "all",      // "all", or a list of names: ["DP-1", "eDP-1"]
    theme:      "tokyo-night",
    colors:     {},         // per-key overrides on top of the chosen theme
    laneWidth:  46,
    barHeight:  10,
    panelWidth: 0,          // 0 -> a fraction of the screen it is drawn on
    announceMs: 5000,
    fontSans:   "",         // "" -> the built-in default
    fontMono:   ""
};

var keys = ["ink", "base", "edge", "muted", "text", "bright",
            "signal_", "flow", "mull", "fault", "stall", "quiet", "yes", "no"];

// What each key is for, so the settings window can label the swatches without
// keeping its own copy of the vocabulary.
var labels = {
    ink:     "Bar",
    base:    "Panel",
    edge:    "Hairlines",
    muted:   "Dim type",
    text:    "Body type",
    bright:  "Titles",
    signal_: "Wants you",
    flow:    "Producing",
    mull:    "Thinking",
    fault:   "Error",
    stall:   "At the limit",
    quiet:   "Idle",
    yes:     "Allow",
    no:      "Deny"
};

var presets = {
    "tokyo-night": {
        ink: "#15161e", base: "#1a1b26", edge: "#2f334d", muted: "#565f89",
        text: "#a9b1d6", bright: "#c0caf5",
        signal_: "#ff9e64", flow: "#5ad6ff", mull: "#9d7cd8", fault: "#f7768e",
        stall: "#e0af68", quiet: "#3b4261", yes: "#9ece6a", no: "#f7768e"
    },
    "catppuccin-mocha": {
        ink: "#181825", base: "#1e1e2e", edge: "#313244", muted: "#6c7086",
        text: "#a6adc8", bright: "#cdd6f4",
        signal_: "#fab387", flow: "#89dceb", mull: "#cba6f7", fault: "#f38ba8",
        stall: "#f9e2af", quiet: "#45475a", yes: "#a6e3a1", no: "#f38ba8"
    },
    "gruvbox-dark": {
        ink: "#1d2021", base: "#282828", edge: "#504945", muted: "#928374",
        text: "#bdae93", bright: "#ebdbb2",
        signal_: "#fe8019", flow: "#8ec07c", mull: "#d3869b", fault: "#fb4934",
        stall: "#fabd2f", quiet: "#3c3836", yes: "#b8bb26", no: "#fb4934"
    },
    "nord": {
        ink: "#2e3440", base: "#3b4252", edge: "#4c566a", muted: "#616e88",
        text: "#d8dee9", bright: "#eceff4",
        signal_: "#d08770", flow: "#88c0d0", mull: "#b48ead", fault: "#bf616a",
        stall: "#ebcb8b", quiet: "#434c5e", yes: "#a3be8c", no: "#bf616a"
    },
    "everforest-dark": {
        ink: "#272e33", base: "#2d353b", edge: "#3d484d", muted: "#859289",
        text: "#9da9a0", bright: "#d3c6aa",
        signal_: "#e69875", flow: "#7fbbb3", mull: "#d699b6", fault: "#e67e80",
        stall: "#dbbc7f", quiet: "#343f44", yes: "#a7c080", no: "#e67e80"
    }
};

var themeNames = ["tokyo-night", "catppuccin-mocha", "gruvbox-dark", "nord",
                  "everforest-dark"];

// The config as written, filled in from the defaults. A file with one key in it
// is a valid config; anything it does not mention keeps working.
function settle(cfg) {
    var out = {};
    for (var k in defaults)
        out[k] = defaults[k];
    for (var j in (cfg || {}))
        out[j] = cfg[j];
    return out;
}

// The theme, then whatever the config overrode on top of it. An override for a
// key the theme does not have is ignored rather than added, so a stale config
// cannot inject a colour the surface has no use for.
function palette(cfg) {
    var c = settle(cfg);
    var base = presets[c.theme] || presets["tokyo-night"];
    var out = {};
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        out[k] = (c.colors && c.colors[k]) ? c.colors[k] : base[k];
    }
    return out;
}
