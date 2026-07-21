-- Locale: tiny i18n layer with a persisted language choice (English / Spanish).
--
-- Usage:
--   local Locale = require('src.locale')
--   Locale.t("menu.play")                 -> "PLAY" / "JUGAR"
--   Locale.t("common.trophies", 42)       -> "42 trophies" / "42 trofeos"
--   Locale.set("es")                       -> switch + persist to locale.json
--
-- Strings are looked up at draw time by every screen, so toggling the language
-- from the settings menu updates the whole UI live. Missing keys fall back to
-- English, then to the raw key (so gaps are obvious rather than silent).

local json = require('lib.json')

local FILE = "locale.json"

local Locale = { lang = "en" }

local STRINGS = {
    en = {
        -- ── common ──────────────────────────────────────────────────────────
        ["common.trophies"]       = "%d trophies",
        ["common.level"]          = "Level %d",
        ["common.cancel"]         = "Cancel",
        ["common.back"]           = "< Back",
        ["common.vs"]             = "vs",
        ["common.you"]            = "you",
        ["common.no_internet"]    = "No internet connection",
        ["common.tap_retry"]      = "Tap to retry",
        ["common.connecting"]     = "Connecting...",
        ["common.authenticating"] = "Authenticating...",
        ["common.disconnected"]   = "Disconnected from server",
        ["common.loading"]        = "Loading...",

        -- ── settings ────────────────────────────────────────────────────────
        ["settings.title"]        = "SETTINGS",
        ["settings.music"]        = "Music",
        ["settings.sfx"]          = "SFX",
        ["settings.god_mode"]     = "God Mode",
        ["settings.language"]     = "Language",
        ["settings.email_backup"] = "Email Backup",
        ["settings.linked"]       = "Linked",
        ["settings.set_up"]       = "Set Up",
        ["settings.saved"]        = "Saved!",
        ["settings.saving"]       = "Saving...",
        ["settings.email"]        = "Email",
        ["settings.password_hint"]= "Password (6+ chars)",
        ["settings.save"]         = "Save",
        ["settings.err_invalid_email"]  = "Invalid email address",
        ["settings.err_short_pw"]       = "Password must be 6+ characters",
        ["settings.err_email_taken"]    = "Email already in use",
        ["settings.err_not_auth"]       = "Not authenticated",
        ["settings.err_not_connected"]  = "Not connected to server",
        ["settings.err_save_failed"]    = "Could not save. Try again.",

        -- ── menu ────────────────────────────────────────────────────────────
        ["menu.play"]             = "PLAY",
        ["menu.sandbox"]          = "SANDBOX",
        ["menu.private_room"]     = "PRIVATE ROOM",
        ["menu.public_room"]      = "PUBLIC ROOM",
        ["menu.enter_code"]       = "Enter room code...",
        ["menu.rules_caption"]    = "RULES",
        ["menu.leaderboard"]      = "Leaderboard",
        ["menu.no_data"]          = "No data available",
        ["menu.err_enter_code"]   = "Enter a room code first",
        ["menu.ticker1"]          = "Welcome to Mus Online.",
        ["menu.ticker2"]          = "Grande, Chica, Pares, Juego — win them all.",
        ["menu.ticker3"]          = "Partners sit across from you.",
        ["menu.ticker4"]          = "Órdago: bet it all on one lance.",
        ["menu.ticker5"]          = "Share a room code to play with friends.",

        -- ── rules popup ─────────────────────────────────────────────────────
        ["rules.title"]           = "Rules",
        ["rules.kings"]           = "Kings",
        ["rules.emotes"]          = "Emotes",
        ["rules.sets"]            = "Sets",
        ["rules.k4"]              = "4 kings",
        ["rules.k8"]              = "8 kings",
        ["rules.emotes_on"]       = "with emotes",
        ["rules.emotes_off"]      = "no emotes",
        ["rules.best_of"]         = "best of %d",

        -- ── name entry ──────────────────────────────────────────────────────
        ["name.connecting"]       = "Connecting to server...",
        ["name.whats_your_name"]  = "What's your name?",
        ["name.welcome"]          = "Welcome, %s!",
        ["name.register_failed"]  = "Registration failed",
        ["name.invalid_login"]    = "Invalid email or password",
        ["name.login_failed"]     = "Login failed",
        ["name.name"]             = "Name",
        ["name.play"]             = "Play!",
        ["name.restore"]          = "Restore Account",
        ["name.email_hint"]       = "your@email.com",
        ["name.password"]         = "Password",
        ["name.password_hint"]    = "password",
        ["name.recover"]          = "Recover",
        ["name.creating"]         = "Creating your profile...",
        ["name.invalid_email"]    = "Invalid email address",
        ["name.enter_password"]   = "Enter your password",
        ["name.restoring"]        = "Restoring account...",

        -- ── loading ─────────────────────────────────────────────────────────
        ["loading.continuing_as"] = "Continuing as %s",

        -- ── preload ─────────────────────────────────────────────────────────
        ["preload.play_offline"]  = "Play OFFLINE vs bots",

        -- ── lobby ───────────────────────────────────────────────────────────
        ["lobby.finding"]         = "Finding match...",
        ["lobby.waiting_friend"]  = "Waiting for friend...",
        ["lobby.match_found"]     = "Match found!",
        ["lobby.opp_disconnected"]= "Opponent disconnected",
        ["lobby.reconnecting"]    = "Reconnecting...",
        ["lobby.error"]           = "Error occurred",
        ["lobby.no_connection"]   = "No connection",
        ["lobby.matchmaking_word"]= "matchmaking",
        ["lobby.matchfound_word"] = "match found!",
        ["lobby.room"]            = "Room: %s",
        ["lobby.players_count"]   = "%d/4 players",
        ["lobby.start_bots"]      = "Start with bots",
        ["lobby.search_range"]    = "%d trophies  ·  searching %d – %d",
        ["lobby.starting"]        = "Starting game...",
        ["lobby.id"]              = "ID: %s",
        ["lobby.wait1"]           = "Finding a worthy opponent...",
        ["lobby.wait2"]           = "Waiting for the ideal match...",
        ["lobby.wait3"]           = "Looking for a duel...",
        ["lobby.wait4"]           = "Sharpening swords before the battle...",
        ["lobby.wait5"]           = "Scouts are searching the realm...",
        ["lobby.wait6"]           = "Summoning a rival commander...",
        ["lobby.wait7"]           = "The arena awaits a challenger...",
        ["lobby.wait8"]           = "Seeking someone brave enough to face you...",

        -- ── game: stages ────────────────────────────────────────────────────
        ["stage.mus"]             = "MUS",
        ["stage.discard"]         = "DISCARD",
        ["stage.grande"]          = "GRANDE",
        ["stage.chica"]           = "CHICA",
        ["stage.pares"]           = "PARES",
        ["stage.juego"]           = "JUEGO",
        ["stage.punto"]           = "PUNTO",

        -- ── game: actions ───────────────────────────────────────────────────
        ["action.mus"]            = "Mus",
        ["action.no_mus"]         = "No mus",
        ["action.paso"]           = "Pass",
        ["action.envido"]         = "Envido",
        ["action.ordago"]         = "¡ÓRDAGO!",
        ["action.quiero"]         = "Accept",
        ["action.no_quiero"]      = "Decline",
        ["action.discard"]        = "Discard",

        -- ── game: table / feed ──────────────────────────────────────────────
        ["game.you"]              = "You",
        ["game.seat"]             = "Seat %d",
        ["game.us"]               = "Us",
        ["game.them"]             = "Them",
        ["game.mano_tag"]         = " (mano)",
        ["game.hand_start"]       = "Hand %d — %s is mano",
        ["game.feed_mus"]         = "%s: mus",
        ["game.feed_no_mus"]      = "%s: no mus!",
        ["game.feed_discard"]     = "%s discards %d",
        ["game.word_pares"]       = "pares",
        ["game.word_juego"]       = "juego",
        ["game.nobody_has"]       = "Nobody has %s",
        ["game.declared"]         = "%s: %s",
        ["game.feed_envido"]      = "%s: envido %d (pot %d)",
        ["game.feed_ordago"]      = "%s: ¡ÓRDAGO!",
        ["game.feed_bet"]         = "%s: %s",
        ["game.phase_declined"]   = "%s: declined",
        ["game.phase_accepted"]   = "%s: accepted, %d",
        ["game.score"]            = "%s +%d (%s)",
        ["game.reconnected"]      = "Reconnected",
        ["game.now_bot"]          = "%s is now a bot",
        ["game.disconnected"]     = "%s disconnected",
        ["game.player_back"]      = "%s is back",
        ["game.timed_out"]        = "Time's up",
        ["game.conn_lost"]        = "Connection lost...",
        ["game.set_won"]          = "SET WON",
        ["game.set_lost"]         = "SET LOST",
        ["game.next_set"]         = "Next set...",
        ["game.score_us"]         = "Us %d",
        ["game.score_them"]       = "Them %d",
        ["game.sets_tally"]       = "sets %d–%d  (best of %d)",
        ["game.ordago_live"]      = "¡ÓRDAGO ON THE TABLE!",
        ["game.pot"]              = "pot: %d",
        ["game.your_turn"]        = "your turn",
        ["game.their_turn"]       = "%s's turn",
        ["game.seconds"]          = "%ds",
        ["game.btn_discard"]      = "Discard %d",
        ["game.btn_raise"]        = "Raise 2",
        ["game.btn_envido"]       = "Envido 2",
        ["game.leave_confirm"]    = "Leave? Tap again",
        ["game.you_win"]          = "YOU WIN!",
        ["game.you_lose"]         = "YOU LOSE",
        ["game.by_ordago"]        = "by órdago",
        ["game.trophy_delta"]     = "%s%d trophies",
        ["game.tap_menu"]         = "Tap to return to menu",
    },

    es = {
        -- ── common ──────────────────────────────────────────────────────────
        ["common.trophies"]       = "%d trofeos",
        ["common.level"]          = "Nivel %d",
        ["common.cancel"]         = "Cancelar",
        ["common.back"]           = "< Atrás",
        ["common.vs"]             = "vs",
        ["common.you"]            = "tú",
        ["common.no_internet"]    = "Sin conexión a internet",
        ["common.tap_retry"]      = "Toca para reintentar",
        ["common.connecting"]     = "Conectando...",
        ["common.authenticating"] = "Autenticando...",
        ["common.disconnected"]   = "Desconectado del servidor",
        ["common.loading"]        = "Cargando...",

        -- ── settings ────────────────────────────────────────────────────────
        ["settings.title"]        = "AJUSTES",
        ["settings.music"]        = "Música",
        ["settings.sfx"]          = "Sonidos",
        ["settings.god_mode"]     = "God Mode",
        ["settings.language"]     = "Idioma",
        ["settings.email_backup"] = "Copia por email",
        ["settings.linked"]       = "Vinculado",
        ["settings.set_up"]       = "Configurar",
        ["settings.saved"]        = "¡Guardado!",
        ["settings.saving"]       = "Guardando...",
        ["settings.email"]        = "Email",
        ["settings.password_hint"]= "Contraseña (6+ car.)",
        ["settings.save"]         = "Guardar",
        ["settings.err_invalid_email"]  = "Email no válido",
        ["settings.err_short_pw"]       = "La contraseña debe tener 6+ caracteres",
        ["settings.err_email_taken"]    = "Ese email ya está en uso",
        ["settings.err_not_auth"]       = "No autenticado",
        ["settings.err_not_connected"]  = "Sin conexión al servidor",
        ["settings.err_save_failed"]    = "No se pudo guardar. Inténtalo de nuevo.",

        -- ── menu ────────────────────────────────────────────────────────────
        ["menu.play"]             = "JUGAR",
        ["menu.sandbox"]          = "PRÁCTICA",
        ["menu.private_room"]     = "SALA PRIVADA",
        ["menu.public_room"]      = "SALA PÚBLICA",
        ["menu.enter_code"]       = "Código de sala...",
        ["menu.rules_caption"]    = "REGLAS",
        ["menu.leaderboard"]      = "Clasificación",
        ["menu.no_data"]          = "Sin datos",
        ["menu.err_enter_code"]   = "Escribe un código primero",
        ["menu.ticker1"]          = "Bienvenido a Mus Online.",
        ["menu.ticker2"]          = "Grande, Chica, Pares, Juego — gánalos todos.",
        ["menu.ticker3"]          = "Tu compañero se sienta enfrente.",
        ["menu.ticker4"]          = "Órdago: apuéstalo todo a un lance.",
        ["menu.ticker5"]          = "Comparte un código de sala para jugar con amigos.",

        -- ── rules popup ─────────────────────────────────────────────────────
        ["rules.title"]           = "Reglas",
        ["rules.kings"]           = "Reyes",
        ["rules.emotes"]          = "Emotes",
        ["rules.sets"]            = "Sets",
        ["rules.k4"]              = "4 reyes",
        ["rules.k8"]              = "8 reyes",
        ["rules.emotes_on"]       = "con emotes",
        ["rules.emotes_off"]      = "sin emotes",
        ["rules.best_of"]         = "al mejor de %d",

        -- ── name entry ──────────────────────────────────────────────────────
        ["name.connecting"]       = "Conectando al servidor...",
        ["name.whats_your_name"]  = "¿Cómo te llamas?",
        ["name.welcome"]          = "¡Bienvenido, %s!",
        ["name.register_failed"]  = "Registro fallido",
        ["name.invalid_login"]    = "Email o contraseña no válidos",
        ["name.login_failed"]     = "Inicio de sesión fallido",
        ["name.name"]             = "Nombre",
        ["name.play"]             = "¡Jugar!",
        ["name.restore"]          = "Recuperar cuenta",
        ["name.email_hint"]       = "tu@email.com",
        ["name.password"]         = "Contraseña",
        ["name.password_hint"]    = "contraseña",
        ["name.recover"]          = "Recuperar",
        ["name.creating"]         = "Creando tu perfil...",
        ["name.invalid_email"]    = "Email no válido",
        ["name.enter_password"]   = "Escribe tu contraseña",
        ["name.restoring"]        = "Recuperando cuenta...",

        -- ── loading ─────────────────────────────────────────────────────────
        ["loading.continuing_as"] = "Continuando como %s",

        -- ── preload ─────────────────────────────────────────────────────────
        ["preload.play_offline"]  = "Jugar OFFLINE contra bots",

        -- ── lobby ───────────────────────────────────────────────────────────
        ["lobby.finding"]         = "Buscando partida...",
        ["lobby.waiting_friend"]  = "Esperando a un amigo...",
        ["lobby.match_found"]     = "¡Partida encontrada!",
        ["lobby.opp_disconnected"]= "Rival desconectado",
        ["lobby.reconnecting"]    = "Reconectando...",
        ["lobby.error"]           = "Ha ocurrido un error",
        ["lobby.no_connection"]   = "Sin conexión",
        ["lobby.matchmaking_word"]= "emparejando",
        ["lobby.matchfound_word"] = "¡partida!",
        ["lobby.room"]            = "Sala: %s",
        ["lobby.players_count"]   = "%d/4 jugadores",
        ["lobby.start_bots"]      = "Empezar con bots",
        ["lobby.search_range"]    = "%d trofeos  ·  buscando %d – %d",
        ["lobby.starting"]        = "Empezando partida...",
        ["lobby.id"]              = "ID: %s",
        ["lobby.wait1"]           = "Buscando un rival digno...",
        ["lobby.wait2"]           = "Esperando la partida ideal...",
        ["lobby.wait3"]           = "Buscando un duelo...",
        ["lobby.wait4"]           = "Afilando las espadas antes de la batalla...",
        ["lobby.wait5"]           = "Los exploradores rastrean el reino...",
        ["lobby.wait6"]           = "Invocando a un comandante rival...",
        ["lobby.wait7"]           = "La arena espera a un retador...",
        ["lobby.wait8"]           = "Buscando a alguien lo bastante valiente...",

        -- ── game: stages ────────────────────────────────────────────────────
        ["stage.mus"]             = "MUS",
        ["stage.discard"]         = "DESCARTE",
        ["stage.grande"]          = "GRANDE",
        ["stage.chica"]           = "CHICA",
        ["stage.pares"]           = "PARES",
        ["stage.juego"]           = "JUEGO",
        ["stage.punto"]           = "PUNTO",

        -- ── game: actions ───────────────────────────────────────────────────
        ["action.mus"]            = "Mus",
        ["action.no_mus"]         = "No hay mus",
        ["action.paso"]           = "Paso",
        ["action.envido"]         = "Envido",
        ["action.ordago"]         = "¡ÓRDAGO!",
        ["action.quiero"]         = "Quiero",
        ["action.no_quiero"]      = "No quiero",
        ["action.discard"]        = "Descartar",

        -- ── game: table / feed ──────────────────────────────────────────────
        ["game.you"]              = "Tú",
        ["game.seat"]             = "Asiento %d",
        ["game.us"]               = "Nosotros",
        ["game.them"]             = "Ellos",
        ["game.mano_tag"]         = " (mano)",
        ["game.hand_start"]       = "Mano %d — es mano %s",
        ["game.feed_mus"]         = "%s: mus",
        ["game.feed_no_mus"]      = "%s: ¡no hay mus!",
        ["game.feed_discard"]     = "%s descarta %d",
        ["game.word_pares"]       = "pares",
        ["game.word_juego"]       = "juego",
        ["game.nobody_has"]       = "Nadie tiene %s",
        ["game.declared"]         = "%s: %s",
        ["game.feed_envido"]      = "%s: envido %d (bote %d)",
        ["game.feed_ordago"]      = "%s: ¡ÓRDAGO!",
        ["game.feed_bet"]         = "%s: %s",
        ["game.phase_declined"]   = "%s: no querido",
        ["game.phase_accepted"]   = "%s: querido, %d",
        ["game.score"]            = "%s +%d (%s)",
        ["game.reconnected"]      = "Reconectado",
        ["game.now_bot"]          = "%s ahora es un bot",
        ["game.disconnected"]     = "%s se ha desconectado",
        ["game.player_back"]      = "%s ha vuelto",
        ["game.timed_out"]        = "Se te acabó el tiempo",
        ["game.conn_lost"]        = "Conexión perdida...",
        ["game.set_won"]          = "SET GANADO",
        ["game.set_lost"]         = "SET PERDIDO",
        ["game.next_set"]         = "Siguiente set...",
        ["game.score_us"]         = "Nosotros %d",
        ["game.score_them"]       = "Ellos %d",
        ["game.sets_tally"]       = "sets %d–%d  (al mejor de %d)",
        ["game.ordago_live"]      = "¡ÓRDAGO EN JUEGO!",
        ["game.pot"]              = "bote: %d",
        ["game.your_turn"]        = "tu turno",
        ["game.their_turn"]       = "turno de %s",
        ["game.seconds"]          = "%ds",
        ["game.btn_discard"]      = "Descartar %d",
        ["game.btn_raise"]        = "Subir 2",
        ["game.btn_envido"]       = "Envido 2",
        ["game.leave_confirm"]    = "¿Salir? Toca otra vez",
        ["game.you_win"]          = "¡HABÉIS GANADO!",
        ["game.you_lose"]         = "HABÉIS PERDIDO",
        ["game.by_ordago"]        = "por órdago",
        ["game.trophy_delta"]     = "%s%d trofeos",
        ["game.tap_menu"]         = "Toca para volver al menú",
    },
}

-- ── persistence ─────────────────────────────────────────────────────────────

function Locale.load()
    local raw = love.filesystem.read(FILE)
    if not raw then return end
    local ok, t = pcall(json.decode, raw)
    if ok and type(t) == "table" and STRINGS[t.lang] then
        Locale.lang = t.lang
    end
end

function Locale.save()
    local ok, data = pcall(json.encode, { lang = Locale.lang })
    if ok then love.filesystem.write(FILE, data) end
end

function Locale.set(lang)
    if not STRINGS[lang] or lang == Locale.lang then return end
    Locale.lang = lang
    Locale.save()
end

function Locale.get() return Locale.lang end

-- ── lookup ──────────────────────────────────────────────────────────────────
-- t(key, ...) returns the translated string. Extra args are applied with
-- string.format, so keys carrying %s/%d placeholders interpolate cleanly.
function Locale.t(key, ...)
    local tbl = STRINGS[Locale.lang] or STRINGS.en
    local str = tbl[key] or STRINGS.en[key] or key
    if select("#", ...) > 0 then
        local ok, out = pcall(string.format, str, ...)
        if ok then return out end
    end
    return str
end

-- love.filesystem is available whenever this module is required inside Love2D.
if love and love.filesystem then Locale.load() end

return Locale
