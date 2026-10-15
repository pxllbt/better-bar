.pragma library

/**
 * Keybind list shaping for Better Bar's native keybind manager.
 *
 * The backend (Omarchy's `keybinds_manager.py`) is the source of truth for
 * Hyprland's bindings.lua parsing, writing, backups and conflicts. This module
 * is not a second implementation of that: it turns the backend's model into the
 * uniform row shape the Better Bar surface binds to, so the UI can stay native
 * without hiding any of that work behind a plugin window.
 *
 * Everything here is pure so it can be tested in Node without a Wayland session
 * or a running shell.
 */

var modifierOrder = ["SUPER", "CTRL", "ALT", "SHIFT", "ALTGR"];

function modifierAlias(part) {
    switch (part) {
    case "SUPER":
    case "WIN":
    case "META":
    case "MOD":
    case "CMD":
        return "SUPER";
    case "CONTROL":
        return "CTRL";
    case "OPTION":
        return "ALT";
    default:
        return part;
    }
}

function normalizeKey(key) {
    var raw = String(key === undefined || key === null ? "" : key).trim();
    if (raw.length === 0)
        return "";

    var parts = raw.split("+").map(function (part) {
        return modifierAlias(part.trim().toUpperCase().replace(/\s+/g, " "));
    }).filter(function (part) {
        return part.length > 0;
    });
    if (parts.length === 0)
        return "";

    // Modifiers keep a stable order, but the main key always stays last. That
    // makes `super+ctrl+space` and `ctrl+super+space` the same chord in the list
    // instead of looking like two different bindings.
    var mods = [];
    var others = [];
    for (var i = 0; i < parts.length; i++) {
        if (modifierOrder.indexOf(parts[i]) !== -1)
            mods.push(parts[i]);
        else
            others.push(parts[i]);
    }
    mods.sort(function (a, b) {
        return modifierOrder.indexOf(a) - modifierOrder.indexOf(b);
    });
    return mods.concat(others).join(" + ");
}

function asObject(value) {
    if (value && typeof value === "object")
        return value;
    if (typeof value === "string" && value.trim().length > 0) {
        try {
            var parsed = JSON.parse(value);
            if (parsed && typeof parsed === "object")
                return parsed;
        } catch (e) {}
    }
    return {};
}

function activeRow(raw) {
    var src = raw || {};
    var status = String(src.status || (src.source === "user" ? "custom" : "default"));
    return {
        kind: "active",
        key: normalizeKey(src.raw_key || src.key),
        description: String(src.description || src.name || src.key || "Unnamed binding"),
        action: String(src.action || src.command || src.dispatcher_command || ""),
        category: String(src.category || "General"),
        status: status,
        source: String(src.source || "default"),
        default_key: normalizeKey(src.default_key || src.key),
        default_action: String(src.default_action || src.action || ""),
        conflict: !!src.is_conflict
    };
}

function conflictRow(raw) {
    var src = raw || {};
    var bindings = [];
    var list = src.bindings || [];
    for (var i = 0; i < list.length; i++) {
        var b = list[i] || {};
        bindings.push({
            description: String(b.description || b.name || "Unnamed action"),
            action: String(b.action || b.command || ""),
            status: String(b.status || "default"),
            source: String(b.source || "default")
        });
    }
    return {
        kind: "conflict",
        key: normalizeKey(src.key),
        description: "Conflict on one chord",
        action: bindings.length + " bound actions",
        category: "Conflicts",
        status: "conflict",
        source: "user",
        bindings: bindings
    };
}

function catalogRow(raw) {
    var src = raw || {};
    return {
        kind: "catalog",
        key: normalizeKey(src.default_key || src.current_key),
        id: String(src.id || ""),
        description: String(src.name || src.id || "Catalog action"),
        action: String(src.command || src.action || ""),
        category: String(src.category || "General"),
        status: "catalog",
        source: "catalog",
        bound: src.is_bound === true,
        current_key: normalizeKey(src.current_key || "")
    };
}

function compareRows(a, b) {
    var an = String(a.description || "").toLowerCase();
    var bn = String(b.description || "").toLowerCase();
    if (an < bn) return -1;
    if (an > bn) return 1;
    var ak = String(a.key || "").toLowerCase();
    var bk = String(b.key || "").toLowerCase();
    if (ak < bk) return -1;
    if (ak > bk) return 1;
    return 0;
}

function parseModel(rawModel) {
    var src = asObject(rawModel);
    var active = [];
    var catalog = [];
    var conflicts = [];

    var activeSrc = src.active || [];
    for (var i = 0; i < activeSrc.length; i++)
        active.push(activeRow(activeSrc[i]));

    var catalogSrc = src.catalog || [];
    for (var j = 0; j < catalogSrc.length; j++)
        catalog.push(catalogRow(catalogSrc[j]));

    var conflictSrc = src.conflicts || [];
    for (var k = 0; k < conflictSrc.length; k++)
        conflicts.push(conflictRow(conflictSrc[k]));

    active.sort(compareRows);
    catalog.sort(compareRows);

    return {
        active: active,
        catalog: catalog,
        conflicts: conflicts,
        totals: {
            total_active: active.length,
            total_modified: active.filter(isOverride).length,
            total_conflicts: conflicts.length,
            total_catalog: catalog.length
        }
    };
}

function isOverride(row) {
    return row.source === "user" || row.status === "custom" || row.status === "modified";
}

function rowsFor(rawModel, tab) {
    var model = parseModel(rawModel);
    var which = String(tab || "active");
    if (which === "modified")
        return model.active.filter(isOverride);
    if (which === "conflicts")
        return model.conflicts;
    if (which === "catalog")
        return model.catalog;
    return model.active;
}

function matches(row, query) {
    var q = String(query || "").trim().toLowerCase();
    if (q.length === 0)
        return true;
    // A typed chord may miss the spaces that normalizeKey adds, so match the
    // normalized form as well as the raw strings.
    var normalized = normalizeKey(q).toLowerCase();
    if (normalized.length > 0 && normalizeKey(row.key).toLowerCase().indexOf(normalized) !== -1)
        return true;

    var haystacks = [row.key, row.description, row.action, row.category, row.id, row.status];
    for (var i = 0; i < haystacks.length; i++) {
        if (String(haystacks[i] || "").toLowerCase().indexOf(q) !== -1)
            return true;
    }
    return false;
}

function canReset(row) {
    if (!row || row.kind === "conflict" || row.kind === "catalog")
        return false;
    return isOverride(row);
}

function canDisable(row) {
    return !!row && row.kind === "active" && row.status !== "disabled";
}

function canEnable(row) {
    return !!row && row.kind === "active" && row.status === "disabled";
}

var specialKeyNames = ({
    "Key_Return": "RETURN",
    "Key_Enter": "RETURN",
    "Key_Space": "SPACE",
    "Key_Tab": "TAB",
    "Key_Backspace": "BACKSPACE",
    "Key_Delete": "DELETE",
    "Key_Insert": "INSERT",
    "Key_Home": "HOME",
    "Key_End": "END",
    "Key_PageUp": "PAGEUP",
    "Key_PageDown": "PAGEDOWN",
    "Key_Escape": "ESCAPE",
    "Key_Up": "UP",
    "Key_Down": "DOWN",
    "Key_Left": "LEFT",
    "Key_Right": "RIGHT",
    "Key_Print": "PRINT",
    "Key_Menu": "MENU",
    "Key_Help": "HELP"
});

function isModifierOnlyKey(key) {
    var name = String(key || "");
    return name === "Key_Control"
        || name === "Key_Shift"
        || name === "Key_Alt"
        || name === "Key_AltGr"
        || name === "Key_Meta"
        || name === "Key_Super_L"
        || name === "Key_Super_R"
        || name === "Key_Caps_Lock"
        || name === "Key_Num_Lock"
        || name === "Key_Scroll_Lock";
}

function keyName(key, text) {
    var name = String(key || "");
    if (name.length === 0 && String(text || "").trim().length > 0)
        name = "Key_" + String(text).trim().toUpperCase();
    if (specialKeyNames[name])
        return specialKeyNames[name];

    var fn = /^Key_F([1-9]|1[0-9]|2[0-4])$/.exec(name);
    if (fn)
        return "F" + fn[1];

    var printable = String(text || "").trim();
    if (printable.length > 0)
        return printable.toUpperCase();

    if (name.indexOf("Key_") === 0)
        return name.substring(4).toUpperCase();
    return name.toUpperCase();
}

function keyFromEvent(ctrl, alt, shift, superKey, key, text) {
    if (isModifierOnlyKey(key))
        return "";
    var name = keyName(key, text);
    if (!name || name === "UNKNOWN")
        return "";
    var mods = [];
    if (superKey)
        mods.push("SUPER");
    if (ctrl)
        mods.push("CTRL");
    if (alt)
        mods.push("ALT");
    if (shift)
        mods.push("SHIFT");
    return normalizeKey(mods.concat(name).join("+"));
}
