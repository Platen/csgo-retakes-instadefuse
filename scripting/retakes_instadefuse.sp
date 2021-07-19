#include <sourcemod>
#include <sdktools>
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

#define MESSAGE_PREFIX "[\x04InstantDefuse\x01]"

bool g_RetakesInstadefuseEnabled = false;
ConVar g_h_sm_retakes_instadefuse_enabled = null;

ConVar hEndIfTooLate = null;
ConVar hDefuseIfTime = null;
ConVar hTimeForNoInstadefuseIfCloseSuc = null;
ConVar hTimeForNoInstadefuseIfCloseUnsuc = null;
ConVar hInfernoDuration = null;
ConVar hInfernoDistance = null;
Handle hTimer_MolotovThreatEnd = null;

Handle fw_OnInstantDefusePre = null;
Handle fw_OnInstantDefusePost = null;

bool g_RetakesEnabled = false;
Handle g_h_retakes_enabled = null;

float g_c4PlantTime = 0.0;
bool g_bAlreadyComplete = false;
bool g_bWouldMakeIt = false;

public Plugin myinfo =
{
	name = "[Retakes] Instant Defuse",
	author = "B3none",
	description = "Allows a CT to instantly defuse the bomb when all Ts are dead and nothing can prevent the defusal.",
	version = "1.4.0",
	url = "https://github.com/b3none"
}

public void OnPluginStart()
{
	LoadTranslations("instadefuse.phrases");

	g_h_sm_retakes_instadefuse_enabled = CreateConVar("sm_instadefuse_enabled", "0", "Should instant defuse be enabled?");
	HookConVarChange(g_h_sm_retakes_instadefuse_enabled, InstadefuseEnabledChanged);

	HookEvent("bomb_begindefuse", Event_BombBeginDefuse, EventHookMode_Post);
	HookEvent("bomb_planted", Event_BombPlanted, EventHookMode_Pre);
	HookEvent("molotov_detonate", Event_MolotovDetonate);
	HookEvent("hegrenade_detonate", Event_AttemptInstantDefuse, EventHookMode_Post);

	HookEvent("player_death", Event_AttemptInstantDefuse, EventHookMode_PostNoCopy);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	hInfernoDuration = CreateConVar("sm_instadefuse_inferno_duration", "7.0", "If Valve ever changed the duration of molotov, this cvar should change with it.");
	hInfernoDistance = CreateConVar("sm_instadefuse_inferno_distance", "225.0", "If Valve ever changed the maximum distance spread of molotov, this cvar should change with it.");
	hEndIfTooLate = CreateConVar("sm_instadefuse_end_if_too_late", "1", "End the round if too late.");
	hDefuseIfTime = CreateConVar("sm_instadefuse_if_time", "1", "Instant defuse if there is time to do so.");
	hTimeForNoInstadefuseIfCloseSuc = CreateConVar("sm_instadefuse_if_too_close_suc", "0.0", "No instant defuse if this amount of time in seconds is left for a sucessful defuse.", _, true, 0.0);
	hTimeForNoInstadefuseIfCloseUnsuc = CreateConVar("sm_instadefuse_if_too_close_unsuc", "0.0", "No instant defuse if this amount of time in seconds is missing for a sucessful defuse.", _, true, 0.0);

	/** Create/Execute retakes cvars **/
	AutoExecConfig(true, "retakes_instadefuse", "sourcemod/retakes");

	// Added the forwards to allow other plugins to call this one.
	fw_OnInstantDefusePre = CreateGlobalForward("InstantDefuse_OnInstantDefusePre", ET_Event, Param_Cell, Param_Cell);
	fw_OnInstantDefusePost = CreateGlobalForward("InstantDefuse_OnInstantDefusePost", ET_Ignore, Param_Cell, Param_Cell);
}

public void OnAllPluginsLoaded() {
	g_h_retakes_enabled = FindConVar("sm_retakes_enabled");
	if (g_h_retakes_enabled != null)
	{
		HookConVarChange(g_h_retakes_enabled, RetakesEnabledChanged);
	}
}

public void OnConfigsExecuted()
{
	g_RetakesInstadefuseEnabled = GetConVarBool(g_h_sm_retakes_instadefuse_enabled);

	if (g_h_retakes_enabled != null)
	{
		g_RetakesEnabled = GetConVarBool(g_h_retakes_enabled);
	}
}

public int InstadefuseEnabledChanged(Handle cvar, const char[] oldValue, const char[] newValue) {
	g_RetakesInstadefuseEnabled = !StrEqual(newValue, "0");
}

public int RetakesEnabledChanged(Handle cvar, const char[] oldValue, const char[] newValue) {
	g_RetakesEnabled = !StrEqual(newValue, "0");
}

public void OnMapStart()
{
	hTimer_MolotovThreatEnd = null;
}

public Action Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
	g_bAlreadyComplete = false;
	g_bWouldMakeIt = false;

	if (hTimer_MolotovThreatEnd != null)
	{
		delete hTimer_MolotovThreatEnd;
	}
}

public Action Event_BombPlanted(Handle event, const char[] name, bool dontBroadcast)
{
	g_c4PlantTime = GetGameTime();
}

public Action Event_BombBeginDefuse(Handle event, const char[] name, bool dontBroadcast)
{
	if (!g_RetakesInstadefuseEnabled  ||  !g_RetakesEnabled)
	{
		return Plugin_Handled;
	}

	if (g_bAlreadyComplete)
	{
		return Plugin_Handled;
	}

	RequestFrame(Event_BombBeginDefusePlusFrame, GetEventInt(event, "userid"));

	return Plugin_Continue;
}

public void Event_BombBeginDefusePlusFrame(int userId)
{
	g_bWouldMakeIt = false;

	int client = GetClientOfUserId(userId);

	if (IsValidClient(client))
	{
		AttemptInstantDefuse(client);
	}
}

void AttemptInstantDefuse(int client, int exemptNade = 0)
{
	if (!g_RetakesInstadefuseEnabled  ||  !g_RetakesEnabled)
	{
		return;
	}

	if (g_bAlreadyComplete || !GetEntProp(client, Prop_Send, "m_bIsDefusing") || HasAlivePlayer(CS_TEAM_T))
	{
		return;
	}

	int StartEnt = MaxClients + 1;

	int c4 = FindEntityByClassname(StartEnt, "planted_c4");

	if (c4 == -1)
	{
		return;
	}

	bool hasDefuseKit = HasDefuseKit(client);
	bool existsDefuseKit = hasDefuseKit || ExistsDefuseKit();
	bool possiblyMakeIt = g_bWouldMakeIt;
	bool isClose = false;
	float c4TimeLeft = GetConVarFloat(FindConVar("mp_c4timer")) - (GetGameTime() - g_c4PlantTime);

	if (!g_bWouldMakeIt)
	{
		float offsetSuc = GetConVarFloat(hTimeForNoInstadefuseIfCloseSuc);
		float offsetUnsuc = GetConVarFloat(hTimeForNoInstadefuseIfCloseUnsuc);
		float timeNeeded = (hasDefuseKit? 5.0 : 10.0);
		float minTimeNeeded = (existsDefuseKit? 5.0 : 10.0);
		g_bWouldMakeIt = (c4TimeLeft >= timeNeeded);
		possiblyMakeIt = (c4TimeLeft >= minTimeNeeded);
		isClose = (c4TimeLeft >= timeNeeded - offsetUnsuc) && (c4TimeLeft <= timeNeeded + offsetSuc);
	}

	if (isClose || (!g_bWouldMakeIt && possiblyMakeIt)) {
		for (int i = 0; i <= MaxClients; i++)
		{
			if (IsValidClient(i))
			{
				PrintToChat(i, "%T", "InstaDefuseClose", i, MESSAGE_PREFIX);
			}
		}

		return;
	}
	else if (GetConVarBool(hEndIfTooLate) && !possiblyMakeIt)
	{
		if (!OnInstantDefusePre(client, c4))
		{
			return;
		}

		for (int i = 0; i <= MaxClients; i++)
		{
			if (IsValidClient(i))
			{
				PrintToChat(i, "%T", "InstaDefuseUnsuccessful", i, MESSAGE_PREFIX, c4TimeLeft);
			}
		}

		g_bAlreadyComplete = true;

		// Force Terrorist win because they do not have enough time to defuse the bomb.
		EndRound(CS_TEAM_T);

		return;
	}
	else if (!GetConVarBool(hDefuseIfTime) || GetEntityFlags(client) && !FL_ONGROUND)
	{
		return;
	}

	int ent;
	if ((ent = FindEntityByClassname(StartEnt, "hegrenade_projectile")) != -1 || (ent = FindEntityByClassname(StartEnt, "molotov_projectile")) != -1)
	{
		if (ent != exemptNade)
		{
			for (int i = 0; i <= MaxClients; i++)
			{
				if (IsValidClient(i))
				{
					PrintToChat(i, "%T", "LiveNadeSomewhere", i, MESSAGE_PREFIX);
				}
			}

			return;
		}
	}
	else if (hTimer_MolotovThreatEnd != null)
	{
		for (int i = 0; i <= MaxClients; i++)
		{
			if (IsValidClient(i))
			{
				PrintToChat(i, "%T", "MolotovTooClose", i, MESSAGE_PREFIX);
			}
		}

		return;
	}

	if (!OnInstantDefusePre(client, c4))
	{
		return;
	}

	for (int i = 0; i <= MaxClients; i++)
	{
		if (IsValidClient(i))
		{
			PrintToChat(i, "%T", "InstaDefuseSuccessful", i, MESSAGE_PREFIX, c4TimeLeft);
		}
	}

	g_bAlreadyComplete = true;

	EndRound(CS_TEAM_CT);

	OnInstantDefusePost(client, c4);
}

public Action Event_AttemptInstantDefuse(Handle event, const char[] name, bool dontBroadcast)
{
	if (!g_RetakesInstadefuseEnabled  ||  !g_RetakesEnabled)
	{
		return;
	}

	int defuser = GetDefusingPlayer();

	int ent = 0;

	if (StrContains(name, "detonate") != -1 && defuser != 0)
	{
		ent = GetEventInt(event, "entityid");

		AttemptInstantDefuse(defuser, ent);
	}
}

public Action Event_MolotovDetonate(Handle event, const char[] name, bool dontBroadcast)
{
	if (!g_RetakesInstadefuseEnabled  ||  !g_RetakesEnabled)
	{
		return;
	}

	float Origin[3];
	Origin[0] = GetEventFloat(event, "x");
	Origin[1] = GetEventFloat(event, "y");
	Origin[2] = GetEventFloat(event, "z");

	int c4 = FindEntityByClassname(MaxClients + 1, "planted_c4");

	if (c4 == -1)
	{
		return;
	}

	float C4Origin[3];
	GetEntPropVector(c4, Prop_Data, "m_vecOrigin", C4Origin);

	if (GetVectorDistance(Origin, C4Origin, false) > GetConVarFloat(hInfernoDistance))
	{
		return;
	}

	if (hTimer_MolotovThreatEnd != null)
	{
		delete hTimer_MolotovThreatEnd;
	}

	hTimer_MolotovThreatEnd = CreateTimer(GetConVarFloat(hInfernoDuration), Timer_MolotovThreatEnd, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_MolotovThreatEnd(Handle timer)
{
	if (!g_RetakesInstadefuseEnabled  ||  !g_RetakesEnabled)
	{
		return;
	}

	hTimer_MolotovThreatEnd = null;

	int defuser = GetDefusingPlayer();

	if (defuser != 0)
	{
		AttemptInstantDefuse(defuser);
	}
}

void OnInstantDefusePost(int client, int c4)
{
	Call_StartForward(fw_OnInstantDefusePost);

	Call_PushCell(client);
	Call_PushCell(c4);

	Call_Finish();
}

void EndRound(int team, bool waitFrame = true)
{
	if (!g_RetakesInstadefuseEnabled  ||  !g_RetakesEnabled)
	{
		return;
	}

	if (waitFrame)
	{
		RequestFrame(Frame_EndRound, team);

		return;
	}

	Frame_EndRound(team);
}

void Frame_EndRound(int team)
{
	int RoundEndEntity = CreateEntityByName("game_round_end");

	DispatchSpawn(RoundEndEntity);

	SetVariantFloat(1.0);

	if (team == CS_TEAM_CT)
	{
		AcceptEntityInput(RoundEndEntity, "EndRound_CounterTerroristsWin");
	}
	else if (team == CS_TEAM_T)
	{
		AcceptEntityInput(RoundEndEntity, "EndRound_TerroristsWin");
	}

	AcceptEntityInput(RoundEndEntity, "Kill");
}

stock int GetDefusingPlayer()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_bIsDefusing"))
		{
			return i;
		}
	}

	return 0;
}

stock bool OnInstantDefusePre(int client, int c4)
{
	Action response;

	Call_StartForward(fw_OnInstantDefusePre);
	Call_PushCell(client);
	Call_PushCell(c4);
	Call_Finish(response);

	return !(response != Plugin_Continue && response != Plugin_Changed);
}

bool HasDefuseKit(int client)
{
	bool hasDefuseKit = GetEntProp(client, Prop_Send, "m_bHasDefuser") == 1;
	return hasDefuseKit;
}

bool ExistsDefuseKit()
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && IsPlayerAlive(i) && HasDefuseKit(i))
		{
			return true;
		}
	}

	int ent = -1;
	while((ent = FindEntityByClassname(ent, "item_defuser")) != -1)
	{
		if(IsValidEntity(ent))
		{
			return true;
		}
	}

	return false;
}

stock bool HasAlivePlayer(int team)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && IsPlayerAlive(i) && GetClientTeam(i) == team)
		{
			return true;
		}
	}

	return false;
}

stock bool IsValidClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && IsClientConnected(client) && IsClientAuthorized(client) && !IsFakeClient(client);
}
