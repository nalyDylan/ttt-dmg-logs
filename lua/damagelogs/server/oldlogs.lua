util.AddNetworkString("DL_AskLogsList")
util.AddNetworkString("DL_AskOldLog")
util.AddNetworkString("DL_SendOldLog")
util.AddNetworkString("DL_SendLogsList")
util.AddNetworkString("DL_AskOldLogRounds")
util.AddNetworkString("DL_SendOldLogRounds")
Damagelog.previous_reports = {}


require("mysqloo")
include("damagelogs/config/mysqloo.lua")
Damagelog.MySQL_Error = nil
file.Delete("damagelog/mysql_error.txt")
local info = Damagelog.MySQL_Informations
Damagelog.database = mysqloo.connect(info.ip, info.username, info.password, info.database, info.port)

Damagelog.database.onConnected = function(self)

    Damagelog.MySQL_Connected = true
    local create_table1 = self:query([[
        CREATE TABLE IF NOT EXISTS damagelog_autoslay (
        ply varchar(32) NOT NULL UNIQUE,
        admins tinytext NOT NULL,
        slays SMALLINT UNSIGNED NOT NULL,
        reason tinytext NOT NULL,
        time BIGINT UNSIGNED NOT NULL);

        CREATE TABLE IF NOT EXISTS damagelog_names (
        steamid varchar(32) NOT NULL UNIQUE,
        name varchar(255) NOT NULL
        );

        CREATE TABLE IF NOT EXISTS damagelog_oldlogs_v3 (
    	id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    	date DATETIME NOT NULL,
    	map TINYTEXT NOT NULL,
    	round TINYINT NOT NULL,
    	damagelog BLOB NOT NULL,
    	PRIMARY KEY (id));
        
        CREATE TABLE IF NOT EXISTS damagelog_weapons (
    	class varchar(255) NOT NULL,
    	name varchar(255) NOT NULL,
    	PRIMARY KEY (class));
    ]])
    create_table1:start()
    local list = self:query("SELECT MIN(date) as min, MAX(date) as max FROM damagelog_oldlogs_v3;")
    list.onSuccess = function(query)
        local data = query:getData()

        if not data[1] then
            return
        end

        Damagelog.OlderDate = data[1]["min"]
        Damagelog.LatestDate = data[1]["max"]
    end
    list:start()

    Damagelog.OldLogsDays = {}

    Damagelog.database.onConnectionFailed = function(self, err)
        file.Write("damagelog/mysql_error.txt", err)
        Damagelog.MySQL_Error = err
    end
    Damagelog.database:connect()


    if file.Exists("damagelog/damagelog_lastroundmap.txt", "DATA") then
        Damagelog.last_round_map = tonumber(file.Read("damagelog/damagelog_lastroundmap.txt", "DATA"))
        file.Delete("damagelog/damagelog_lastroundmap.txt")
    end

    hook.Add("TTTEndRound", "Damagelog_EndRound", function()
        if Damagelog.DamageTable and Damagelog.ShootTables and Damagelog.ShootTables[Damagelog.CurrentRound] then
            local logs = {
                DamageTable = Damagelog.DamageTable,
                ShootTable = Damagelog.ShootTables[Damagelog.CurrentRound],
                Roles = Damagelog.Roles[Damagelog.CurrentRound]
            }

            logs = util.TableToJSON(logs)
            local t = os.time()

            if Damagelog.MySQL_Connected then
                Damagelog.queries.InsertOldLogs:setNumber(1, t)
                Damagelog.queries.InsertOldLogs:setNumber(2, Damagelog.CurrentRound)
                Damagelog.queries.InsertOldLogs:setString(3, game.GetMap())
                Damagelog.queries.InsertOldLogs:setString(4, logs)
                Damagelog.queries.InsertOldLogs:start()
            end
            file.Write("damagelog/damagelog_lastroundmap.txt", tostring(t))
        end
    end)

net.Receive("DL_AskLogsList", function(_, ply)
    net.Start("DL_SendLogsList")

    if Damagelog.OlderDate and Damagelog.LatestDate then
        net.WriteUInt(1, 1)
        net.WriteTable(Damagelog.OldLogsDays)
        net.WriteUInt(Damagelog.OlderDate, 32)
        net.WriteUInt(Damagelog.LatestDate, 32)
    else
        net.WriteUInt(0, 1)
    end

    net.Send(ply)
end)

local function SendLogs(ply, compressed, cancel)
    net.Start("DL_SendOldLog")

    if cancel then
        net.WriteUInt(0, 1)
    else
        net.WriteUInt(1, 1)
        net.WriteUInt(#compressed, 32)
        net.WriteData(compressed, #compressed)
    end

    net.Send(ply)
end

net.Receive("DL_AskOldLogRounds", function(_, ply)
    local id = net.ReadUInt(32)
    local year = net.ReadUInt(32)
    local month = string.format("%02d", net.ReadUInt(32))
    local day = string.format("%02d", net.ReadUInt(32))
    local isnewlog = net.ReadBool()
    local _date = "20" .. year .. "-" .. month .. "-" .. day -- TODO: not the best way if someone uses this in 2100 too ;)

    if Damagelog.Use_MySQL and Damagelog.MySQL_Connected then
        local query_str = "SELECT date,map,round FROM damagelog_oldlogs_v3 WHERE date BETWEEN UNIX_TIMESTAMP(\"" .. _date .. " 00:00:00\") AND UNIX_TIMESTAMP(\"" .. _date .. " 23:59:59\") ORDER BY date ASC;"
        local query = Damagelog.database:query(query_str)

        query.onSuccess = function(self)
            if not IsValid(ply) then
                return
            end

            local data = self:getData()
            net.Start("DL_SendOldLogRounds")
            net.WriteUInt(id, 32)
            net.WriteTable(data)
            net.WriteBool(isnewlog)
            net.Send(ply)
        end

        query:start()
    else
        local query_str = "SELECT date,map,round FROM damagelog_oldlogs_v3 WHERE date BETWEEN strftime(\"%s\", \"" .. _date .. " 00:00:00\") AND strftime(\"%s\", \"" .. _date .. " 23:59:59\") ORDER BY date ASC;"
        local result = sql.Query(query_str)

        if not result then
            result = {}
        end

        net.Start("DL_SendOldLogRounds")
        net.WriteUInt(id, 32)
        net.WriteTable(result)
        net.WriteBool(isnewlog)
        net.Send(ply)
    end
end)

net.Receive("DL_AskOldLog", function(_, ply)
    if IsValid(ply) and ply:IsPlayer() and (not ply.lastLogs or (CurTime() - ply.lastLogs) > 2) then
        local _time = net.ReadUInt(32)

        if Damagelog.Use_MySQL and Damagelog.MySQL_Connected then
            local query = Damagelog.database:query("SELECT UNCOMPRESS(damagelog) FROM damagelog_oldlogs_v3 WHERE date = " .. _time .. ";")

            query.onSuccess = function(self)
                local data = self:getData()
                net.Start("DL_SendOldLog")

                if data[1] and data[1]["UNCOMPRESS(damagelog)"] then
                    local compressed = util.Compress(data[1]["UNCOMPRESS(damagelog)"])
                    SendLogs(ply, compressed, false)
                else
                    SendLogs(ply, nil, true)
                end

                net.Send(ply)
            end

            query:start()
        elseif not Damagelog.Use_MySQL then
            local query = sql.QueryValue("SELECT damagelog FROM damagelog_oldlogs_v3 WHERE date = " .. _time)
            net.Start("DL_SendOldLog")

            if query then
                SendLogs(ply, util.Compress(query), false)
            else
                SendLogs(ply, nil, true)
            end
        end
    end

    ply.lastLogs = CurTime()
end)