unit UExport;

{ Saving recordings without stalling the 60 Hz loop.

  GIF       frames are kept in memory while recording, then a background
            thread quantises and writes them (TBGRAAnimatedGif).
  MP4       frames go into a queue; a writer thread pipes them as raw BGRA
            into ffmpeg (libx264), so a slow encoder never blocks the frame
            loop. ffmpeg must be installed (PATH, program folder or winget).
  PNG seq.  fallback when ffmpeg is missing: numbered PNGs written in the
            background plus make_mp4.bat with the ffmpeg command line. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Process, FileUtil, BGRABitmap, BGRABitmapTypes, BGRAAnimatedGif,
  BGRAPalette, BGRAColorQuantization;

type
  TExportKind = (ekGif, ekPngSeq, ekStill);

  { TExportThread }

  TExportThread = class(TThread)
  private
    FKind: TExportKind;
    FFrames: TFPList;
    FPath: string;
    FDelayMs, FFps: integer;
    FProc: TProcess;
    FResult: string;
    procedure Done;
  protected
    procedure Execute; override;
  public
    // takes ownership of AFrames (TBGRABitmap) and AProc
    constructor Create(AKind: TExportKind; AFrames: TFPList; const APath: string; AFps: integer;
      AProc: TProcess);
  end;

  { TFfmpegWriter }

  TFfmpegWriter = class(TThread)
  private
    FProc: TProcess;
    FPath: string;
    FQueue: TThreadList;
    FWake: PRTLEvent;
    FFinish: boolean;
    FWritten, FDropped: integer;
    FResult: string;
    procedure Done;
  protected
    procedure Execute; override;
  public
    constructor Create(AProc: TProcess; const APath: string);
    destructor Destroy; override;
    procedure Push(Frame: TBGRABitmap);   // takes ownership; drops the frame when the queue is full
    procedure Finish;                     // no more frames: flush, close ffmpeg, free itself
    property Dropped: integer read FDropped;
  end;

var
  ExportBusy: boolean;               // main thread only
  ExportStatus: string;              // main thread only (set through Synchronize)

function ExportDir: string;
function FindFfmpeg(const Hint: string): string;
function StartFfmpeg(const Exe, OutFile: string; W, H, Fps: integer): TProcess;
procedure WriteFfmpegFrame(Proc: TProcess; Bmp: TBGRABitmap);
function TimeStampName(const Prefix, Ext: string): string;

implementation

uses
  ULog;

function ExportDir: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'exports' + PathDelim;
  ForceDirectories(Result);
end;

function TimeStampName(const Prefix, Ext: string): string;
begin
  Result := ExportDir + Prefix + FormatDateTime('yyyymmdd_hhnnss', Now) + Ext;
end;

// %LOCALAPPDATA%\Microsoft\WinGet: Links\ffmpeg.exe, or Packages\*FFmpeg*\<build>\bin\ffmpeg.exe
function FindWingetFfmpeg: string;
var
  Root, Dir: string;
  Pkg, Build: TSearchRec;
begin
  Root := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) + 'Microsoft\WinGet\';
  Result := Root + 'Links\ffmpeg.exe';
  if FileExists(Result) then Exit;
  Result := '';
  if FindFirst(Root + 'Packages\*FFmpeg*', faDirectory, Pkg) = 0 then
  try
    repeat
      Dir := Root + 'Packages\' + Pkg.Name + '\';
      if FindFirst(Dir + '*', faDirectory, Build) = 0 then
      try
        repeat
          if (Build.Name <> '.') and (Build.Name <> '..') and
            FileExists(Dir + Build.Name + '\bin\ffmpeg.exe') then
            Exit(Dir + Build.Name + '\bin\ffmpeg.exe');
        until FindNext(Build) <> 0;
      finally
        FindClose(Build);
      end;
    until FindNext(Pkg) <> 0;
  finally
    FindClose(Pkg);
  end;
end;

function FindFfmpeg(const Hint: string): string;
const
  Guesses: array[0..3] of string = ('C:\ffmpeg\bin\ffmpeg.exe', 'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
    'C:\ProgramData\chocolatey\bin\ffmpeg.exe', 'C:\tools\ffmpeg\bin\ffmpeg.exe');
var
  G: string;
begin
  if (Hint <> '') and FileExists(Hint) then Exit(Hint);
  Result := ExtractFilePath(ParamStr(0)) + 'ffmpeg.exe';
  if FileExists(Result) then Exit;
  Result := FindDefaultExecutablePath('ffmpeg.exe');
  if Result <> '' then Exit;
  for G in Guesses do
    if FileExists(G) then Exit(G);
  // winget installs: a program started before the install (the IDE, say) still has the old PATH
  Result := FindWingetFfmpeg;
end;

function StartFfmpeg(const Exe, OutFile: string; W, H, Fps: integer): TProcess;
var
  Preset: string;
begin
  // 60 fps at full size needs the fastest preset to keep up in real time
  if Fps >= 50 then Preset := 'ultrafast' else Preset := 'veryfast';
  Result := TProcess.Create(nil);
  Result.Executable := Exe;
  // quiet: ffmpeg's stderr goes to a pipe nobody reads, so it must not fill it
  Result.Parameters.AddStrings(['-hide_banner', '-loglevel', 'error', '-nostats', '-y',
    '-f', 'rawvideo', '-pix_fmt', 'bgra', '-s', Format('%dx%d', [W, H]), '-r', IntToStr(Fps),
    '-i', '-', '-c:v', 'libx264', '-preset', Preset, '-crf', '18', '-pix_fmt', 'yuv420p', OutFile]);
  Result.Options := [poUsePipes, poNoConsole];
  Result.Execute;
end;

procedure WriteFfmpegFrame(Proc: TProcess; Bmp: TBGRABitmap);
var
  y: integer;
begin
  // rows top to bottom whatever the bitmap's line order
  for y := 0 to Bmp.Height - 1 do
    Proc.Input.WriteBuffer(Bmp.ScanLine[y]^, Bmp.Width * SizeOf(TBGRAPixel));
end;

{ TFfmpegWriter }

const
  MaxQueued = 90;                    // 1.5 s at 60 fps; beyond that the encoder is hopelessly behind

constructor TFfmpegWriter.Create(AProc: TProcess; const APath: string);
begin
  FProc := AProc;
  FPath := APath;
  FQueue := TThreadList.Create;
  FWake := RTLEventCreate;
  FreeOnTerminate := True;
  inherited Create(False);
end;

destructor TFfmpegWriter.Destroy;
begin
  FQueue.Free;
  RTLEventDestroy(FWake);
  FProc.Free;
  inherited Destroy;
end;

procedure TFfmpegWriter.Push(Frame: TBGRABitmap);
var
  L: TList;
begin
  L := FQueue.LockList;
  try
    if L.Count >= MaxQueued then
    begin
      Frame.Free;
      Inc(FDropped);
    end
    else
      L.Add(Frame);
  finally
    FQueue.UnlockList;
  end;
  RTLEventSetEvent(FWake);
end;

procedure TFfmpegWriter.Finish;
begin
  ExportBusy := True;
  FFinish := True;
  RTLEventSetEvent(FWake);
end;

procedure TFfmpegWriter.Done;
begin
  ExportBusy := False;
  ExportStatus := FResult;
end;

procedure TFfmpegWriter.Execute;
var
  L: TList;
  B: TBGRABitmap;
  Failed: boolean;
  i: integer;
begin
  Failed := False;
  repeat
    B := nil;
    L := FQueue.LockList;
    try
      if L.Count > 0 then
      begin
        B := TBGRABitmap(L[0]);
        L.Delete(0);
      end;
    finally
      FQueue.UnlockList;
    end;
    if B <> nil then
    begin
      if not Failed then
        try
          WriteFfmpegFrame(FProc, B);
          Inc(FWritten);
        except
          on E: Exception do
          begin
            Failed := True;
            FResult := 'ffmpeg pipe failed: ' + E.Message;
          end;
        end;
      B.Free;
    end
    else if FFinish then
      Break
    else
      RTLEventWaitFor(FWake, 50);
  until False;
  // anything left after a failure
  L := FQueue.LockList;
  try
    for i := 0 to L.Count - 1 do TBGRABitmap(L[i]).Free;
    L.Clear;
  finally
    FQueue.UnlockList;
  end;
  try
    FProc.CloseInput;
    FProc.WaitOnExit;
  except
  end;
  if not Failed then
  begin
    if FProc.ExitStatus = 0 then
    begin
      FResult := Format('MP4 saved: %s (%d frames)', [FPath, FWritten]);
      if FDropped > 0 then FResult := FResult + Format(', %d dropped: encoder too slow', [FDropped]);
    end
    else
      FResult := Format('ffmpeg failed (exit code %d) for %s', [FProc.ExitStatus, FPath]);
  end;
  Log('export', FResult);
  Synchronize(@Done);
end;

{ TExportThread }

constructor TExportThread.Create(AKind: TExportKind; AFrames: TFPList; const APath: string; AFps: integer;
  AProc: TProcess);
begin
  FKind := AKind;
  FFrames := AFrames;
  FPath := APath;
  FFps := AFps;
  FDelayMs := Round(1000 / Max(1, AFps));
  FProc := AProc;
  FreeOnTerminate := True;
  ExportBusy := True;
  inherited Create(False);
end;

procedure TExportThread.Done;
begin
  ExportBusy := False;
  ExportStatus := FResult;
end;

procedure TExportThread.Execute;
var
  Gif: TBGRAAnimatedGif;
  i: integer;
  B: TBGRABitmap;
  Bat: TStringList;
  T0: QWord;
begin
  T0 := GetTickCount64;
  try
    case FKind of
      ekGif:
        begin
          Gif := TBGRAAnimatedGif.Create;
          try
            B := TBGRABitmap(FFrames[0]);
            Gif.SetSize(B.Width, B.Height);
            Gif.LoopCount := 0;
            for i := 0 to FFrames.Count - 1 do
              Gif.AddFullFrame(TBGRABitmap(FFrames[i]), FDelayMs);
            Gif.SaveToFile(FPath);
          finally
            Gif.Free;
          end;
          FResult := Format('GIF saved: %s (%d frames, %.1f s to encode)',
            [FPath, FFrames.Count, (GetTickCount64 - T0) / 1000]);
        end;
      ekPngSeq:
        begin
          ForceDirectories(FPath);
          for i := 0 to FFrames.Count - 1 do
            TBGRABitmap(FFrames[i]).SaveToFile(IncludeTrailingPathDelimiter(FPath) + Format('frame_%.4d.png', [i + 1]));
          Bat := TStringList.Create;
          try
            Bat.Add('@echo off');
            Bat.Add('rem needs ffmpeg on PATH: https://ffmpeg.org');
            Bat.Add(Format('ffmpeg -y -framerate %d -i frame_%%%%04d.png -c:v libx264 -pix_fmt yuv420p -crf 18 ..\%s.mp4',
              [FFps, ExtractFileName(ExcludeTrailingPathDelimiter(FPath))]));
            Bat.SaveToFile(IncludeTrailingPathDelimiter(FPath) + 'make_mp4.bat');
          finally
            Bat.Free;
          end;
          FResult := Format('ffmpeg not found: %d PNG frames + make_mp4.bat saved in %s', [FFrames.Count, FPath]);
        end;
      ekStill:
        begin
          // PNG or BMP by extension; a 2x PNG takes about a second, so not on the frame loop
          B := TBGRABitmap(FFrames[0]);
          B.SaveToFile(FPath);
          FResult := Format('Saved %s (%dx%d)', [FPath, B.Width, B.Height]);
        end;
    end;
  except
    on E: Exception do FResult := 'Export failed: ' + E.Message;
  end;
  Log('export', FResult);
  if FFrames <> nil then
  begin
    for i := 0 to FFrames.Count - 1 do TBGRABitmap(FFrames[i]).Free;
    FFrames.Free;
  end;
  FProc.Free;
  Synchronize(@Done);
end;

initialization
  // GIF encoding needs a colour quantiser; BGRABitmap leaves the choice to the program
  BGRAColorQuantizerFactory := TBGRAColorQuantizer;
end.
