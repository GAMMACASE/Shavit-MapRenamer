#include "sourcemod"
#include "shavit"

#pragma dynamic 131072

#define SNAME "[MapRenamer] "

public Plugin myinfo =
{
	name = "[shavit] MapRenamer",
	author = "GAMMA CASE",
	description = "Allows to rename maps in db and all replay files.",
	version = "1.0.1",
	url = "https://steamcommunity.com/id/_GAMMACASE_/"
};

Database gDB;
char gTables[][] = { "maptiers", "mapzones", "playertimes" };

public void OnPluginStart()
{
	RegAdminCmd("sm_renamemap", SM_Renamemap, ADMFLAG_ROOT, "Renames map in a database and all replay files if there's any.");
}

public void Shavit_OnDatabaseLoaded()
{
	gDB = Shavit_GetDatabase();
	if(!gDB)
		SetFailState(SNAME..."Null database handle returned.");
}

public Action SM_Renamemap(int client, int args)
{
	if(args != 2)
	{
		ReplyToCommand(client, SNAME..."Usage: sm_renamemap <mapname> <newmapname> (Note: This will remove all data for new map and replace it with old one)");
		return Plugin_Handled;
	}
	
	if(!gDB || Shavit_GetStyleCount() == -1)
	{
		ReplyToCommand(client, SNAME..."Plugin is waiting for shavit to retrieve data...");
		return Plugin_Handled;
	}
	
	char map[PLATFORM_MAX_PATH], newmap[PLATFORM_MAX_PATH];
	GetCmdArg(1, map, sizeof(map));
	GetCmdArg(2, newmap, sizeof(newmap));
	
	Transaction trx = new Transaction();
	char query[128];
	
	for(int i = 0; i < sizeof(gTables) * 2; i++)
	{
		gDB.Format(query, sizeof(query), "SELECT EXISTS(SELECT * FROM `%s` WHERE map = '%s' LIMIT 1)", gTables[i % sizeof(gTables)], i / sizeof(gTables) ? newmap : map);
		trx.AddQuery(query);
	}
	
	DataPack dp = new DataPack();
	dp.WriteCell(client == 0 ? client : GetClientUserId(client));
	dp.WriteString(map);
	dp.WriteString(newmap);
	gDB.Execute(trx, MapLookup_Success, Transaction_Error, dp);
	
	return Plugin_Handled;
}

public void MapLookup_Success(Database db, DataPack dp, int numQueries, DBResultSet[] results, any[] queryData)
{
	dp.Reset();
	
	bool found;
	int mapstates[2];
	int userid = dp.ReadCell();
	int client = userid == 0 ? userid : GetClientOfUserId(userid);
	char map[PLATFORM_MAX_PATH], newmap[PLATFORM_MAX_PATH];
	
	dp.ReadString(map, sizeof(map));
	dp.ReadString(newmap, sizeof(newmap));
	
	for(int i = 0; i < numQueries; i++)
	{
		if(results[i])
		{
			results[i].FetchRow();
			found = !!results[i].FetchInt(0);
			if(found)
				mapstates[i / sizeof(gTables)] |= 1 << (i % sizeof(gTables));
			else if(i < sizeof(gTables))
				ReplyToCommand(client, SNAME..."Wasn't able to find any entry in '%s' table about \"%s\" map.", gTables[i], map);
		}
		else
			ThrowError(SNAME..."Something terribly wrong happend, this shouldn't be the case!");
	}
	
	if(mapstates[0] == 0)
	{
		ReplyToCommand(client, SNAME..."Can't find anything for map \"%s\", exiting...", map);
		return;
	}
	
	Transaction trx = new Transaction();
	
	PrepareNewMap(trx, userid, newmap, mapstates[1]);
	PrepareToRenameOldMap(trx, userid, map, newmap, mapstates[0]);
	
	gDB.Execute(trx, MapRename_Success, Transaction_Error, dp);
}

public void Transaction_Error(Database db, DataPack dp, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int client = userid == 0 ? userid : GetClientOfUserId(userid);
	ReplyToCommand(client, SNAME..."SQL Query failed (reason: \"%s\", code: %i)", error, failIndex);
}

void PrepareNewMap(Transaction trx, int userid, const char map[PLATFORM_MAX_PATH], int mapstate)
{
	if(mapstate == 0)
		return;
	
	int client = userid == 0 ? userid : GetClientOfUserId(userid);
	char query[128];
	
	for(int i = 0; i < sizeof(gTables); i++)
	{
		if(mapstate & (1 << i % sizeof(gTables)))
		{
			ReplyToCommand(client, SNAME..."Found new map in '%s' table, deleting...", gTables[i % sizeof(gTables)]);
			gDB.Format(query, sizeof(query), "DELETE FROM `%s` WHERE map = '%s'", gTables[i % sizeof(gTables)], map);
			trx.AddQuery(query);
		}
	}
}

void PrepareToRenameOldMap(Transaction trx, int userid, const char map[PLATFORM_MAX_PATH], const char newmap[PLATFORM_MAX_PATH], int mapstate)
{
	if(mapstate == 0)
		return;
	
	int client = userid == 0 ? userid : GetClientOfUserId(userid);
	char query[128];
	
	for(int i = 0; i < sizeof(gTables); i++)
	{
		if(mapstate & (1 << i % sizeof(gTables)))
		{
			ReplyToCommand(client, SNAME..."Found old map in '%s' table, renaming...", gTables[i % sizeof(gTables)]);
			gDB.Format(query, sizeof(query), "UPDATE `%s` SET map = '%s' WHERE map = '%s'", gTables[i % sizeof(gTables)], newmap, map);
			trx.AddQuery(query);
		}
	}
}

public void MapRename_Success(Database db, DataPack dp, int numQueries, DBResultSet[] results, any[] queryData)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int client = userid == 0 ? userid : GetClientOfUserId(userid);
	char map[PLATFORM_MAX_PATH], newmap[PLATFORM_MAX_PATH];
	
	dp.ReadString(map, sizeof(map));
	dp.ReadString(newmap, sizeof(newmap));
	
	delete dp;
	
	char path[PLATFORM_MAX_PATH], buff[PLATFORM_MAX_PATH], buff2[PLATFORM_MAX_PATH];
	//Didn't found a way to get that folder via natives, and to lazy to parse cfg file myself...
	BuildPath(Path_SM, path, sizeof(path), "data/replaybot");
	
	int styles = Shavit_GetStyleCount();
	for(int i = 0; i < styles; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			Format(buff, sizeof(buff), "_%i", j);
			Format(buff, sizeof(buff), "%s/%i/%s%s.replay", path, i, newmap, (j == 0 ? "" : buff));
			
			if(FileExists(buff))
			{
				ReplyToCommand(client, SNAME..."Found replay file for new map (style: %i, track: %i), deleting...", i, j);
				DeleteFile(buff);
			}
			
			Format(buff2, sizeof(buff2), "_%i", j);
			Format(buff2, sizeof(buff2), "%s/%i/%s%s.replay", path, i, map, (j == 0 ? "" : buff2));
			
			if(FileExists(buff2))
			{
				ReplyToCommand(client, SNAME..."Found replay file for old map (style: %i, track: %i), renaming...", i, j);
				RenameReplay(buff2, buff, newmap);
			}
		}
	}
	
	ReplyToCommand(client, SNAME..."Renaming complete.");
}

void RenameReplay(const char path[PLATFORM_MAX_PATH], const char newpath[PLATFORM_MAX_PATH], const char newmap[PLATFORM_MAX_PATH])
{
	File file = OpenFile(path, "rb");
	
	if(!file)
		ThrowError(SNAME..."Can't open \"%s\" replay file, stopping...", path);
	
	char subver;
	file.ReadInt8(view_as<int>(subver));
	
	if(subver <= '2')
	{
		file.Close();
		RenameFile(newpath, path);
		return;
	}
	else
	{
		File newfile = OpenFile(newpath, "wb");
		
		newfile.WriteInt8(subver);
		
		char buff[PLATFORM_MAX_PATH];
		file.ReadLine(buff, sizeof(buff));
		TrimString(buff);
		newfile.WriteLine(buff);
		
		file.ReadString(buff, sizeof(buff));
		newfile.WriteString(newmap, true);
		
		int curr = file.Position;
		file.Seek(0, SEEK_END);
		int len = file.Position - curr;
		file.Seek(curr, SEEK_SET);
		
		int bytes[131072], num;
		while((len % 4 == 0 || len >= sizeof(bytes)) && (num = file.Read(bytes, sizeof(bytes), 4)) > 0)
		{
			newfile.Write(bytes, num, 4);
			len -= num * 4;
		}
		
		if(!file.EndOfFile())
			while((num = file.Read(bytes, sizeof(bytes), 1)) > 0)
				newfile.Write(bytes, num, 1);
		
		file.Close();
		newfile.Close();
		
		DeleteFile(path);
	}
}
