util.AddNetworkString("DL_SlayMessage")
util.AddNetworkString("DL_AutoSlay")
util.AddNetworkString("DL_AutoslaysLeft")
util.AddNetworkString("DL_PlayerLeft")
util.AddNetworkString("DL_SendJails")
local mode = Damagelog.ULX_AutoslayMode
local sql = Damagelog.database
if mode ~= 1 and mode ~= 2 then
		return
end

local aslay = mode == 1


Damagelog.queries = {
	NameUpdate = sql:prepare("INSERT INTO `damagelog_names` (`steamid`, `name`) VALUES(?, ?) ON DUPLICATE KEY UPDATE `name` = ?;"),
	SelectName = sql:prepare("SELECT `name` FROM `damagelog_names` WHERE `steamid` = ? LIMIT 1;"),
	SelectAutoSlays = sql:prepare("SELECT IFNULL((SELECT `slays` FROM `damagelog_autoslay` WHERE `ply` = ?), '0');"),
	SelectAutoSlayAll = sql:prepare("SELECT * FROM `damagelog_autoslay` WHERE ply=? LIMIT 1"),
	DeleteAutoSlay = sql:prepare("DELETE FROM `damagelog_autoslay` WHERE `ply` = ?;"),
	UpdateAutoSlay = sql:prepare("UPDATE `damagelog_autoslay` SET `admins` = ?, `slays` = ?, `reason` = ?, `time` = ? WHERE `ply` = ? LIMIT 1;"),
	InsertAutoSlay = sql:prepare("INSERT INTO `damagelog_autoslay` (`admins`, `ply`, `slays`, `reason`, `time`) VALUES (?, ?, ?, ?, ?);"),
	DecrementAutoSlay = sql:prepare("UPDATE damagelog_autoslay SET slays = slays - 1 WHERE ply = ?;"),
	GetName = sql:prepare("SELECT IFNULL((SELECT `name` FROM `damagelog_names` WHERE `steamid` = ? LIMIT 1), \"<error>\");")
}

local function fullUpdate(ply, steamid)
	local ids = {}
	local c
	for _, v in ipairs(player.GetHumans()) do
		if v ~= ply then
			table.insert(ids, {v:UserID(), v.AutoslaysLeft or 0})
		else
			queries.SelectAutoSlays:setString(1, steamid)
			queries.SelectAutoSlays:start()
			c = tonumber(queries.SelectAutoSlays:getData() or 0)
			ply.AutoslaysLeft = c
			table.insert(ids, {v:UserID(), c})
		end
	end
	--at some point I should probably just make this a single net message
	for _,v in ipairs(ids) do
		--reducing this to 16 bits per player instead of an entire entity + 32 bit UInt
		--2^12 is 4096, if your server has been on this long you're having bigger issues
		net.Start("DL_AutoslaysLeft")
		net.WriteUInt(v[1], 12)
		net.WriteUInt(v[2], 4)
		net.Send(ply)
	end
end
local function damagelogNames(ply, steamid)
	--send new players a list of data to seed from
	fullUpdate(ply, steamid)

	--update the players name in the database for logging reasons
	local name = ply:Nick()
	Damagelog.queries.NameUpdate:setString(1, steamid)
	Damagelog.queries.NameUpdate:setString(2, name)
	Damagelog.queries.NameUpdate:setString(3, name)
	Damagelog.queries.NameUpdate:start()

end
hook.Add("PlayerAuthed", "DamagelogNames", damagelogNames)

function Damagelog:GetName(steamid)
	local ply = player.GetBySteamID(steamid)
	if ply then return ply end

	self.queries.SelectName:setString(1, steamid)
	self.queries.SelectName:start()
	return self.queries.SelectName:getData()
end

function Damagelog.SlayMessage(ply, message)
	net.Start("DL_SlayMessage")
	net.WriteString(message)
	net.Send(ply)
end

function Damagelog:CreateSlayList(tbl)
	if #tbl == 1 then
		return self:GetName(tbl[1])
	else
		local result = ""
		for i = 1, #tbl do
			if i == #tbl then
				result = result .. " and " .. self:GetName(tbl[i])
			elseif i == 1 then
				result = self:GetName(tbl[i])
			else
				result = result .. ", " .. self:GetName(tbl[i])
			end
		end
		return result
	end
end

function Damagelog:FormatTime(t)
	if t < 0 then
		-- 24 * 3600
		-- 24 * 3600 * 7
		-- 24 * 3600 * 30
		return "Forever"
	else
		return string.NiceTime(t)
	end
end

local function NetworkSlays(steamid, number)
	for _, v in ipairs(player.GetHumans()) do
		if v:SteamID() == steamid then
			v.AutoslaysLeft = number
			net.Start("DL_AutoslaysLeft")
			net.WriteEntity(v)
			net.WriteUInt(number, 32)
			net.Broadcast()

			return
		end
	end
end

function Damagelog:SetSlays(admin, steamid, slays, reason, target)
	if reason == "" then
		reason = Damagelog.Autoslay_DefaultReason
	end

	if slays == 0 then
		self.queries.DeleteAutoSlay:setString(1, steamid)
		self.queries.DeleteAutoSlay:start()

		if target then
			ulx.fancyLogAdmin(admin, aslay and "#A removed the autoslays of #T." or "#A removed the autojails of #T.", target)
		else
			ulx.fancyLogAdmin(admin, aslay and "#A removed the autoslays of #s." or "#A removed the jails of #s.", steamid)
		end

		NetworkSlays(steamid, 0)
	else
		self.queries.SelectAutoSlayAll:setString(1, steamid)
		local data = self.queries.SelectAutoSlayAll:getData()

		if data then
			local adminid

			if IsValid(admin) and type(admin) == "Player" then
				adminid = admin:SteamID()
			else
				adminid = "Console"
			end

			local old_slays = tonumber(data.slays)
			local old_steamids = util.JSONToTable(data.admins) or {}
			local new_steamids = table.Copy(old_steamids)

			if not table.HasValue(new_steamids, adminid) then
				table.insert(new_steamids, adminid)
			end

			if old_slays == slays then
				local list = self:CreateSlayList(old_steamids)
				local msg

				if target then
					if aslay then
						msg = "#T was already autoslain "
					else
						msg = "#T was already autojailed "
					end

					ulx.fancyLogAdmin(admin, msg .. slays .. " time(s) by #A for #s.", target, list, reason)
				else
					if aslay then
						msg = "#s was already autoslain "
					else
						msg = "#s was already autojailed "
					end

					ulx.fancyLogAdmin(admin, msg .. slays .. " time(s) by #A for #s.", steamid, list, reason)
				end
			else
				local difference = slays - old_slays
				self.queries.UpdateAutoSlay:setString(1, new_admins)
				self.queries.UpdateAutoSlay:setNumber(2, slays)
				self.queries.UpdateAutoSlay:setString(3, reason)
				self.queries.UpdateAutoSlay:setString(4, tostring(os.time()))
				self.queries.UpdateAutoSlay:setString(5, steamid)
				self.queries.UpdateAutoSlay:start()
				local list = self:CreateSlayList(old_steamids)
				local msg

				if target then
					if aslay then
						msg = " autoslays to #T (#s). He was previously autoslain "
					else
						msg = " autojails to #T (#s). He was previously autojailed "
					end

					ulx.fancyLogAdmin(admin, "#A " .. (difference > 0 and "added " or "removed ") .. math.abs(difference) .. msg .. old_slays .. " time(s) by #s.", target, reason, list)
				else
					if aslay then
						msg = " autoslays to #s (#s). He was previously autoslain "
					else
						msg = " autojails to #s (#s). He was previously autojailed "
					end

					ulx.fancyLogAdmin(admin, "#A " .. (difference > 0 and "added " or "removed ") .. math.abs(difference) .. msg .. old_slays .. " time(s) by #s.", steamid, reason, list)
				end

				NetworkSlays(steamid, slays)
			end
		else
			local admins

			if IsValid(admin) and type(admin) == "Player" then
				admins = util.TableToJSON({admin:SteamID()})
			else
				admins = util.TableToJSON({"Console"})
			end

			self.queries.InsertAutoSlay:setString(1, admins)
			self.queries.InsertAutoSlay:setString(2, steamid)
			self.queries.InsertAutoSlay:setNumber(3, slays)
			self.queries.InsertAutoSlay:setString(4, reason)
			self.queries.InsertAutoSlay:setString(5, tostring(os.time()))
			self.queries.InsertAutoSlay:start()

			local msg

			if target then
				if aslay then
					msg = " autoslays to #T (#s)"
				else
					msg = " autojails to #T (#s)"
				end

				ulx.fancyLogAdmin(admin, "#A added " .. slays .. msg, target, reason)
			else
				if aslay then
					msg = " autoslays to #s (#s)"
				else
					msg = " autojails to #s (#s)"
				end

				ulx.fancyLogAdmin(admin, "#A added " .. slays .. msg, steamid, reason)
			end

			NetworkSlays(steamid, slays)
		end
	end
end

local mdl1 = Model("models/props_building_details/Storefront_Template001a_Bars.mdl")

local jail = {
	{
		pos = Vector(0, 0, -5),
		ang = Angle(90, 0, 0),
		mdl = mdl1
	},
	{
		pos = Vector(0, 0, 97),
		ang = Angle(90, 0, 0),
		mdl = mdl1
	},
	{
		pos = Vector(21, 31, 46),
		ang = Angle(0, 90, 0),
		mdl = mdl1
	},
	{
		pos = Vector(21, -31, 46),
		ang = Angle(0, 90, 0),
		mdl = mdl1
	},
	{
		pos = Vector(-21, 31, 46),
		ang = Angle(0, 90, 0),
		mdl = mdl1
	},
	{
		pos = Vector(-21, -31, 46),
		ang = Angle(0, 90, 0),
		mdl = mdl1
	},
	{
		pos = Vector(-52, 0, 46),
		ang = Angle(0, 0, 0),
		mdl = mdl1
	},
	{
		pos = Vector(52, 0, 46),
		ang = Angle(0, 0, 0),
		mdl = mdl1
	}
}

hook.Add("TTTBeginRound", "Damagelog_AutoSlay", function()
	for _, v in ipairs(player.GetHumans()) do
		if v:IsActive() then
			timer.Simple(1, function()
				v:SetNWBool("PlayedSRound", true)
			end)

			Damagelog.queries.SelectAutoSlayAll:setString(1, v:SteamID())
			local data = Damagelog.queries.SelectAutoSlayAll:getData()

			if data then
				if aslay then
					timer.Simple(0.5, function()
						hook.Run("DL_AslayHook", v)
					end)

					v:Kill()
				else
					local pos = v:GetPos()
					local walls = {}

					for _, info in ipairs(jail) do
						local ent = ents.Create("prop_physics")
						ent:SetModel(info.mdl)
						ent:SetPos(pos + info.pos)
						ent:SetAngles(info.ang)
						ent:Spawn()
						ent:GetPhysicsObject():EnableMotion(false)
						ent:SetCustomCollisionCheck(true)
						ent.jailWall = true
						table.insert(walls, ent)
					end

					timer.Simple(1, function()
						net.Start("DL_SendJails")
						net.WriteUInt(#walls, 32)

						for _, v2 in ipairs(walls) do
							net.WriteEntity(v2)
						end

						local filter = RecipientFilter()
						filter:AddAllPlayers()

						if IsValid(v) then
							filter:RemovePlayer(v)
						end

						net.Send(filter)
					end)

					local function unjail()
						for _, ent in ipairs(walls) do
							if IsValid(ent) then
								ent:Remove()
							end
						end

						if not IsValid(v) then
							return
						end

						v.jail = nil
					end

					v.jail = {
						pos = pos,
						unjail = unjail
					}
				end

				local admins = util.JSONToTable(data.admins) or {}
				local slays = data.slays
				local reason = data.reason
				local _time = data.time
				slays = slays - 1

				if slays <= 0 then
					Damagelog.queries.DeleteAutoSlay:setString(1, v:SteamID())
					Damagelog.queries.DeleteAutoSlay:start()
					NetworkSlays(steamid, 0)
					v.AutoslaysLeft = 0
				else
					Damagelog.queries.DecrementAutoSlay:setString(1, v:SteamID())
					Damagelog.queries.DecrementAutoSlay:start()
					NetworkSlays(steamid, slays - 1)

					if tonumber(v.AutoslaysLeft) then
						v.AutoslaysLeft = v.AutoslaysLeft - 1
					end
				end

				local list = Damagelog:CreateSlayList(admins)
				net.Start("DL_AutoSlay")
				net.WriteEntity(v)
				net.WriteString(list)
				net.WriteString(reason)
				net.WriteString(Damagelog:FormatTime(tonumber(os.time()) - tonumber(_time)))
				net.Broadcast()

				if IsValid(v.server_ragdoll) then
					local ply = player.GetBySteamID(v.server_ragdoll.sid)

					if not IsValid(ply) then
						return
					end

					ply:SetCleanRound(false)
					ply:SetNWBool("body_found", true)

					if not ROLES and ply:GetRole() == ROLE_TRAITOR or ROLES and ply:HasTeamRole(TEAM_TRAITOR) then
						SendConfirmedTraitors(GetInnocentFilter(false))
					end

					CORPSE.SetFound(v.server_ragdoll, true)
					v.server_ragdoll:Remove()
				end
			end
		end
	end
end)

hook.Add("PlayerDisconnected", "Autoslay_Message", function(ply)
	if tonumber(ply.AutoslaysLeft) and ply.AutoslaysLeft > 0 then
		net.Start("DL_PlayerLeft")
		net.WriteString(ply:Nick())
		net.WriteString(ply:SteamID())
		net.WriteUInt(ply.AutoslaysLeft, 32)
		net.Broadcast()
	end
end)

if Damagelog.ULX_Autoslay_ForceRole then
	hook.Add("Initialize", "Autoslay_ForceRole", function()
		if not ROLES then
			local function GetTraitorCount(ply_count)
				local traitor_count = math.floor(ply_count * GetConVar("ttt_traitor_pct"):GetFloat())
				traitor_count = math.Clamp(traitor_count, 1, GetConVar("ttt_traitor_max"):GetInt())

				return traitor_count
			end

			local function GetDetectiveCount(ply_count)
				if ply_count < GetConVar("ttt_detective_min_players"):GetInt() then
					return 0
				end

				local det_count = math.floor(ply_count * GetConVar("ttt_detective_pct"):GetFloat())
				det_count = math.Clamp(det_count, 1, GetConVar("ttt_detective_max"):GetInt())

				return det_count
			end

			function SelectRoles()
				local choices = {}

				local prev_roles = {
					[ROLE_INNOCENT] = {},
					[ROLE_TRAITOR] = {},
					[ROLE_DETECTIVE] = {}
				}

				if not GAMEMODE.LastRole then
					GAMEMODE.LastRole = {}
				end

				for _, v in ipairs(player.GetHumans()) do
					if IsValid(v) and (not v:IsSpec()) and not (v.AutoslaysLeft and tonumber(v.AutoslaysLeft) > 0) then
						local r = GAMEMODE.LastRole[v:SteamID()] or v:GetRole() or ROLE_INNOCENT
						table.insert(prev_roles[r], v)
						table.insert(choices, v)
					end

					v:SetRole(ROLE_INNOCENT)
				end

				local choice_count = #choices
				local traitor_count = GetTraitorCount(choice_count)
				local det_count = GetDetectiveCount(choice_count)

				if choice_count == 0 then
					return
				end

				local ts = 0

				while ts < traitor_count do
					local pick = math.random(1, #choices)
					local pply = choices[pick]

					if IsValid(pply) and ((not table.HasValue(prev_roles[ROLE_TRAITOR], pply)) or (math.random(1, 3) == 2)) then
						pply:SetRole(ROLE_TRAITOR)
						table.remove(choices, pick)
						ts = ts + 1
					end
				end

				local ds = 0
				local min_karma = GetConVar("ttt_detective_karma_min"):GetInt()

				while ds < det_count and #choices >= 1 do
					if #choices <= (det_count - ds) then
						for _, pply in pairs(choices) do
							if IsValid(pply) then
								pply:SetRole(ROLE_DETECTIVE)
							end
						end

						break
					end

					local pick = math.random(1, #choices)
					local pply = choices[pick]

					if IsValid(pply) and (pply:GetBaseKarma() > min_karma and table.HasValue(prev_roles[ROLE_INNOCENT], pply) or math.random(1, 3) == 2) then
						if not pply:GetAvoidDetective() then
							pply:SetRole(ROLE_DETECTIVE)
							ds = ds + 1
						end

						table.remove(choices, pick)
					end
				end

				GAMEMODE.LastRole = {}

				for _, ply in ipairs(player.GetHumans()) do
					ply:SetDefaultCredits()
					GAMEMODE.LastRole[ply:SteamID()] = ply:GetRole()
				end
			end
		end
	end)
end
