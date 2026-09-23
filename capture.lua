------------------------------------------------------------
-- CAPTURE F4 / F5  —  version "2 gestes"
--
-- F4 : souris posée sur une fenêtre (sans clic) → F4
--      → 📸 la fenêtre est activée, capturée dans le
--        presse-papiers et sauvée dans CAPTURE_DIR
--      → 📋 suit le curseur : clique dans le champ du chat
--      → Cmd+V puis Enter automatique
--
-- F5 : sélection d'une zone à la souris → même chose,
--      mais SANS Enter (tu envoies toi-même)
--
-- Esc annule à tout moment. Sans clic après WAIT_TIMEOUT s,
-- l'attente s'arrête d'elle-même (rien n'est collé).
--
-- Indépendant de MEMCHROMEPAGES (F15..F19).
-- Prérequis : Hammerspoon autorisé dans
--   Réglages Système → Confidentialité → Enregistrement de l'écran
------------------------------------------------------------


local CAP_DEBUG = true

-- Dossier de sauvegarde des captures
local CAPTURE_DIR = os.getenv("HOME") .. "/Pictures/Monosnap"

local PASTE_DELAY  = 0.25   -- après ton clic, avant Cmd+V
local ENTER_DELAY  = 0.6    -- après Cmd+V, avant Enter (F4)
local WAIT_TIMEOUT = 20     -- secondes d'attente max de ton clic
local FOCUS_DELAY  = 0.3    -- fenêtre activée → capture


hs.fs.mkdir(CAPTURE_DIR)


local function capLog(text)
    if CAP_DEBUG then
        print("[CAPTURE] " .. tostring(text))
    end
end


------------------------------------------------------------
-- BADGE COLLE AU CURSEUR
------------------------------------------------------------

local badge      = nil
local badgeTimer = nil


local function badgeHide()

    if badgeTimer then
        badgeTimer:stop()
        badgeTimer = nil
    end

    if badge then
        badge:delete()
        badge = nil
    end
end


local function badgeShow(symbol, follow)

    badgeHide()

    local pos = hs.mouse.absolutePosition()

    badge = hs.canvas.new({ x = pos.x + 14, y = pos.y + 14, w = 44, h = 44 })

    badge[1] = {
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0, green = 0, blue = 0, alpha = 0.75 }
    }

    badge[2] = {
        type = "text",
        text = symbol,
        textSize = 26,
        textAlignment = "center",
        frame = { x = 0, y = 4, w = 44, h = 40 }
    }

    badge:level(hs.canvas.windowLevels.screenSaver)
    badge:behavior({ "canJoinAllSpaces", "stationary" })
    badge:show()

    if follow then
        badgeTimer = hs.timer.doEvery(0.03, function()
            if not badge then return end
            local p = hs.mouse.absolutePosition()
            badge:topLeft({ x = p.x + 14, y = p.y + 14 })
        end)
    end
end


------------------------------------------------------------
-- FENETRE SOUS LA SOURIS
------------------------------------------------------------

local function windowUnderMouse()

    local pos = hs.geometry.new(hs.mouse.absolutePosition())

    for _, w in ipairs(hs.window.orderedWindows()) do

        local app = w:application()

        if app and app:name() ~= "Hammerspoon"
            and w:isStandard()
            and pos:inside(w:frame())
        then
            return w
        end
    end

    return nil
end


------------------------------------------------------------
-- NOM DE FICHIER
------------------------------------------------------------

local function newCapturePath()
    return CAPTURE_DIR .. "/Capture " .. os.date("%Y-%m-%d %H-%M-%S") .. ".png"
end


------------------------------------------------------------
-- ATTENTE DU CLIC → COLLAGE
------------------------------------------------------------

local waiting      = false
local clickTap     = nil
local escTap       = nil
local timeoutTimer = nil


local function stopWaiting()

    waiting = false

    if clickTap then clickTap:stop() ; clickTap = nil end
    if escTap   then escTap:stop()   ; escTap   = nil end

    if timeoutTimer then
        timeoutTimer:stop()
        timeoutTimer = nil
    end

    badgeHide()
end


local function waitForClickThenPaste(sendEnter, label)

    waiting = true

    badgeShow("📋", true)

    capLog(label .. " : en attente de ton clic dans le champ cible")

    -- Esc = annuler
    escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)

        if e:getKeyCode() == 53 then
            capLog(label .. " : annulé (Esc)")
            stopWaiting()
            return true
        end

        return false
    end)

    escTap:start()

    -- Clic = coller
    clickTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseUp }, function()

        if not waiting then return false end

        stopWaiting()

        hs.timer.doAfter(PASTE_DELAY, function()

            local app = hs.application.frontmostApplication()

            capLog(
                label .. " : collage dans "
                .. (app and app:name() or "?")
            )

            hs.eventtap.keyStroke({ "cmd" }, "v", 200000, app)

            badgeShow("✅", false)
            hs.timer.doAfter(0.6, badgeHide)

            if sendEnter then
                hs.timer.doAfter(ENTER_DELAY, function()
                    hs.eventtap.keyStroke({}, "return", 200000, app)
                    capLog(label .. " : Enter envoyé")
                end)
            end
        end)

        return false   -- le clic passe normalement à l'application
    end)

    clickTap:start()

    timeoutTimer = hs.timer.doAfter(WAIT_TIMEOUT, function()
        if waiting then
            capLog(label .. " : délai dépassé, rien collé")
            stopWaiting()
        end
    end)
end


------------------------------------------------------------
-- MISE EN PRESSE-PAPIERS + SAUVEGARDE
------------------------------------------------------------

local function publishImage(image, label)

    if not image then
        capLog(label .. " : aucune image")
        hs.alert.show(label .. " — capture impossible", 2)
        return false
    end

    local path = newCapturePath()

    if not image:saveToFile(path) then
        capLog(label .. " : échec sauvegarde " .. path)
    else
        capLog(label .. " : sauvé " .. path)
    end

    hs.pasteboard.writeObjects(image)

    return true
end


------------------------------------------------------------
-- F4 : FENETRE SOUS LA SOURIS
------------------------------------------------------------

local function captureWindowUnderMouse()

    if waiting then stopWaiting() end

    hs.alert.closeAll()
    hs.alert.show("⏳ F4 …", { textSize = 18, radius = 10, padding = 12 }, hs.screen.mainScreen(), 1)

    local win = windowUnderMouse()

    if not win then
        hs.alert.show("F4 — aucune fenêtre sous la souris", 1.5)
        capLog("F4 : aucune fenêtre sous la souris")
        return
    end

    local app = win:application()

    capLog(
        "F4 : fenêtre = " .. (app and app:name() or "?")
        .. " / " .. (win:title() or "")
    )

    badgeShow("📸", false)

    win:focus()

    hs.timer.doAfter(FOCUS_DELAY, function()

        local image = win:snapshot()

        if not image then
            -- repli : screencapture par identifiant de fenêtre
            local path = newCapturePath()
            hs.execute(
                '/usr/sbin/screencapture -o -x -l ' .. tostring(win:id())
                .. ' "' .. path .. '"'
            )
            image = hs.image.imageFromPath(path)
            if image then hs.pasteboard.writeObjects(image) end
            if not image then
                badgeHide()
                hs.alert.show(
                    "F4 — capture refusée\nAutorise Hammerspoon dans\n"
                    .. "Confidentialité → Enregistrement de l'écran", 4
                )
                capLog("F4 : snapshot nil et repli screencapture KO")
                return
            end
            capLog("F4 : sauvé (repli) " .. path)
        elseif not publishImage(image, "F4") then
            badgeHide()
            return
        end

        waitForClickThenPaste(true, "F4")
    end)
end


------------------------------------------------------------
-- F5 : ZONE A LA SOURIS
------------------------------------------------------------

local function captureArea()

    if waiting then stopWaiting() end

    local path = newCapturePath()

    capLog("F5 : sélection de zone")

    local task = hs.task.new(
        "/usr/sbin/screencapture",
        function(exitCode)

            local image = hs.image.imageFromPath(path)

            if exitCode ~= 0 or not image then
                capLog("F5 : annulé ou aucune image")
                return
            end

            capLog("F5 : sauvé " .. path)

            hs.pasteboard.writeObjects(image)

            waitForClickThenPaste(false, "F5")
        end,
        { "-i", "-x", path }
    )

    if not task or not task:start() then
        hs.alert.show("F5 — impossible de lancer screencapture", 3)
    end
end


------------------------------------------------------------
-- RACCOURCIS
------------------------------------------------------------

hs.hotkey.bind({}, "F4", captureWindowUnderMouse)
hs.hotkey.bind({}, "F5", captureArea)


print("[CAPTURE] F4 = fenêtre sous la souris → clic → coller → Enter | F5 = zone → clic → coller")
