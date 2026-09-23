------------------------------------------------------------
-- FUNKEYS : F1 / F2 / F3 reprises par Hammerspoon
--
-- Nécessaire quand macOS est réglé sur
-- "Utiliser F1, F2… comme touches de fonction standard"
-- (réglage indispensable pour que F4/F5 arrivent à Hammerspoon).
--
-- F1 : luminosité -
-- F2 : luminosité +
-- F3 : vue éclatée (Mission Control)
--
-- Indépendant de MEMCHROMEPAGES et de capture.lua.
------------------------------------------------------------


local BRIGHTNESS_STEP = 6    -- % par appui (macOS : ~6 %)


local function brightnessBy(delta)

    local cur = hs.brightness.get()

    if cur == nil then
        hs.alert.show("Luminosité non pilotable sur cet écran", 1)
        return
    end

    local new = math.max(0, math.min(100, cur + delta))

    hs.brightness.set(new)

    hs.alert.closeAll()
    hs.alert.show(
        "☀ " .. new .. " %",
        { textSize = 20, radius = 12, padding = 14 },
        hs.screen.mainScreen(),
        0.6
    )
end


hs.hotkey.bind({}, "F1", function() brightnessBy(-BRIGHTNESS_STEP) end,
    nil, function() brightnessBy(-BRIGHTNESS_STEP) end)   -- répétition si maintenu

hs.hotkey.bind({}, "F2", function() brightnessBy(BRIGHTNESS_STEP) end,
    nil, function() brightnessBy(BRIGHTNESS_STEP) end)

hs.hotkey.bind({}, "F3", function()
    hs.execute("open -b com.apple.exposelauncher")
end)


print("[FUNKEYS] F1 = luminosité - | F2 = luminosité + | F3 = vue éclatée")
