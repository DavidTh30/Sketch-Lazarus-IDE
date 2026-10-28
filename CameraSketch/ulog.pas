unit ULog;

{ Application log: timestamped lines with a category, kept in memory (last
  MaxLines) for the developer window. Thread safe: workers and the encoder
  threads may log too. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

procedure Log(const Category, Msg: string);
procedure LogFmt(const Category, Fmt: string; const Args: array of const);
// Lines added after the caller's Seen counter; returns the new counter.
function LogFetch(Seen: int64; Dest: TStrings): int64;
function LogTail(Count: integer): string;
procedure LogClear;
function LogCount: int64;

implementation

const
  MaxLines = 4000;

var
  Lock: TRTLCriticalSection;
  Lines: TStringList;
  Total: int64;                      // lines ever logged; Lines holds the last MaxLines

procedure Log(const Category, Msg: string);
begin
  EnterCriticalSection(Lock);
  try
    Lines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  [' + Category + ']  ' + Msg);
    if Lines.Count > MaxLines then Lines.Delete(0);
    Inc(Total);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure LogFmt(const Category, Fmt: string; const Args: array of const);
begin
  Log(Category, Format(Fmt, Args));
end;

function LogFetch(Seen: int64; Dest: TStrings): int64;
var
  i, First: integer;
begin
  EnterCriticalSection(Lock);
  try
    First := Lines.Count - (Total - Seen);
    if First < 0 then First := 0;
    for i := First to Lines.Count - 1 do Dest.Add(Lines[i]);
    Result := Total;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function LogTail(Count: integer): string;
var
  i: integer;
begin
  Result := '';
  EnterCriticalSection(Lock);
  try
    for i := Lines.Count - Count to Lines.Count - 1 do
      if i >= 0 then Result := Result + Lines[i] + LineEnding;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure LogClear;
begin
  EnterCriticalSection(Lock);
  try
    Lines.Clear;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function LogCount: int64;
begin
  Result := Total;
end;

initialization
  InitCriticalSection(Lock);
  Lines := TStringList.Create;

finalization
  Lines.Free;
  DoneCriticalSection(Lock);
end.
