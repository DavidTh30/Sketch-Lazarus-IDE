unit UMain;

{ Window of the camera sketch.

  Frame loop (idle handler, 60 Hz):
    Update   - animation (orbit, explode spring, lens zoom, shutter sequence)
    Build    - the scene becomes a sorted display list (main thread)
    Raster   - all cores draw the list band by band (URenderPool)
    HUD      - text, buttons and the title block (main thread, BGRABitmap)
    Present  - the frame is uploaded as one BGRA texture and drawn as a quad
               with OpenGL; SwapBuffers waits for the vertical blank.
               The swap interval is refresh / 60, so a 120 or 144 Hz screen
               still shows a steady 60 Hz. Without OpenGL (or with vsync off)
               frames are painted with GDI on a 60 Hz timer grid.

  Mouse: drag = orbit, wheel = lens zoom 24-70 mm, Ctrl+wheel or right drag = distance.
  Keys:  Space shutter, E explode, W x-ray, A auto orbit, L labels, R redraw,
         V vsync, [ ] shutter speed, Up/Down ISO, Left/Right aperture,
         F11 fullscreen, Esc leave fullscreen, F12 developer window (udevform.pas).

  Command line: --shot <file.png> <seconds> [explode|x] [threads] [yaw] [pitch]
                --devtest <folder>   drive the developer window and exports, then quit }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math, Forms, Controls, Graphics, ExtCtrls, LCLType, GL, OpenGLContext,
  Process, BGRABitmap, BGRABitmapTypes, USketchScene, URenderPool, UAudio, UExport;

type
  TButtonId = (bShutter, bExplode, bWire, bOrbit, bLabels, bRedraw, bVSync, bDev);

const
  HistLen = 240;                     // frames kept for the developer graphs

type

  THudButton = record
    R: TRectF;
    Caption, Key: string;
    Hover, Down: boolean;
  end;

  { TMainForm }

  TMainForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    FGL: TOpenGLControl;
    FView: TPaintBox;
    FOutput: TControl;
    FUseGL, FGLReady, FVSync, FVSyncApplied, FVSyncSupported: boolean;
    FTexture: GLuint;
    FTexW, FTexH: integer;
    FRefreshHz, FSwapInterval: integer;

    FScene: TCameraScene;
    FPool: TRenderPool;
    FFrame, FPaper, FMeasure: TBGRABitmap;
    FTextCache: TStringList;
    FStats: array[0..6] of string;
    FPaperW, FPaperH: integer;

    FButtons: array[TButtonId] of THudButton;
    FDragging, FRightDrag: boolean;
    FLastX, FLastY: integer;
    FMouse: TPointF;

    FFreq: int64;
    FLastTick, FNextFrame: double;
    FFrames: integer;
    FFpsTime, FFps: double;
    FBuildMs, FRasterMs, FHudMs, FWaitMs, FCpuMs: double;
    FFullScreen: boolean;
    FOldBounds: TRect;
    FOldState: TWindowState;
    FShotFlash: single;
    FLastShots: integer;

    // developer window
    Dev: TForm;
    Audio: TAudio;
    HoverObj: integer;               // object list row under the mouse: part, or 100 + layer
    ShowHud, ShowFlash: boolean;
    GLVendor, GLRenderer, GLVersion: string;
    HistFrame, HistCpu, HistRaster: array[0..HistLen - 1] of single;
    HistPos: integer;
    FPrevFrameT: double;
    // still capture, done on the next frame
    FCapPath: string;
    FCapScale: integer;
    FCapHud: boolean;
    // recording
    Recording: boolean;
    FRecMp4: boolean;
    FRecFrames: TFPList;
    FRecWriter: TFfmpegWriter;
    FRecPath: string;
    FRecFps, FRecW, FRecH: integer;
    FRecHud: boolean;
    FRecStart, FRecEnd, FRecNext: double;

    procedure RequestStill(const Path: string; Scale: integer; WithHud: boolean);
    procedure StartRecording(Mp4: boolean; Seconds, Fps: integer; Scale: single; WithHud: boolean;
      const FfmpegHint: string);
    procedure StopRecording;
    function RecordStatus: string;
    procedure CaptureFrames;
    function ReproCommand: string;
    procedure DrawHover;
    procedure ToggleDev;
    procedure DevTestStep;
  public
    FTestStep: integer;
    FTestT: double;

    function NowMs: double;
    procedure AppIdle(Sender: TObject; var Done: boolean);
    procedure DoFrame;
    procedure EnsurePaper(W, H: integer);
    procedure DrawPaperSheet;
    procedure DrawHud;
    procedure DrawLabels;
    procedure LayoutButtons;
    procedure PressButton(B: TButtonId);
    procedure Present;
    procedure PresentGL;
    procedure UseGDI(const Reason: string);
    procedure GLPaint(Sender: TObject);
    procedure ViewPaint(Sender: TObject);
    procedure OutMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure OutMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure OutMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure OutMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: integer;
      MousePos: TPoint; var Handled: boolean);
    procedure ToggleFullScreen;
    function OutputName: string;
    function TextSprite(const S: string; Size: integer; Bold: boolean; C: TBGRAPixel): TBGRABitmap;
    function Txt(X, Y: single; const S: string; Size: integer; Bold: boolean; C: TBGRAPixel;
      AAlign: TAlignment = taLeftJustify): single;
    function TextW(const S: string; Size: integer; Bold: boolean): single;
    function TextH(Size: integer): single;
  end;

var
  MainForm: TMainForm;

implementation

uses
  ULog, UDevForm;

{$R *.lfm}

const
  Ink: TBGRAPixel = (blue: 40; green: 34; red: 34; alpha: 230);
  InkSoft: TBGRAPixel = (blue: 70; green: 62; red: 60; alpha: 170);
  InkBlue: TBGRAPixel = (blue: 140; green: 92; red: 60; alpha: 210);
  InkRed: TBGRAPixel = (blue: 40; green: 50; red: 175; alpha: 230);
  Margin = 14;
  TitleW = 380;
  TitleH = 118;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
{$IFDEF WINDOWS}
var
  DC: HDC;
{$ENDIF}
begin
  Caption := 'LZ-1 Camera Sketch  -  BGRABitmap on all cores, OpenGL vsync 60 Hz';
  Color := clBlack;
  {$IFDEF WINDOWS}
  QueryPerformanceFrequency(FFreq);
  {$ENDIF}
  Randomize;
  FScene := TCameraScene.Create;
  FPool := TRenderPool.Create(StrToIntDef(ParamStr(5), 0));
  FFrame := TBGRABitmap.Create(16, 16);
  FPaper := TBGRABitmap.Create(16, 16);
  FMeasure := TBGRABitmap.Create(4, 4);
  FMeasure.FontName := 'Bahnschrift';
  FMeasure.FontQuality := fqFineAntialiasing;
  FTextCache := TStringList.Create;
  FTextCache.Sorted := True;
  FTextCache.CaseSensitive := True;
  FTextCache.OwnsObjects := True;

  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Visible := False;
  FView.OnPaint := @ViewPaint;
  FView.OnMouseDown := @OutMouseDown;
  FView.OnMouseMove := @OutMouseMove;
  FView.OnMouseUp := @OutMouseUp;
  FView.OnMouseWheel := @OutMouseWheel;
  FOutput := FView;

  FVSync := True;
  FUseGL := True;
  try
    FGL := TOpenGLControl.Create(Self);
    FGL.Parent := Self;
    FGL.Align := alClient;
    FGL.AutoResizeViewport := False;
    FGL.DepthBits := 0;
    FGL.DoubleBuffered := True;
    FGL.OnPaint := @GLPaint;
    FGL.OnMouseDown := @OutMouseDown;
    FGL.OnMouseMove := @OutMouseMove;
    FGL.OnMouseUp := @OutMouseUp;
    FGL.OnMouseWheel := @OutMouseWheel;
    FOutput := FGL;
  except
    on E: Exception do UseGDI(E.Message);
  end;

  FRefreshHz := 60;
  {$IFDEF WINDOWS}
  DC := GetDC(0);
  FRefreshHz := GetDeviceCaps(DC, VREFRESH);
  ReleaseDC(0, DC);
  if FRefreshHz <= 1 then FRefreshHz := 60;
  timeBeginPeriod(1);
  {$ENDIF}
  // lock to 60 Hz: on a 120/144 Hz screen wait 2 vertical blanks per frame
  FSwapInterval := Max(1, Round(FRefreshHz / 60));

  FButtons[bShutter].Caption := 'SHUTTER';  FButtons[bShutter].Key := 'SPACE';
  FButtons[bExplode].Caption := 'EXPLODE';  FButtons[bExplode].Key := 'E';
  FButtons[bWire].Caption := 'X-RAY';       FButtons[bWire].Key := 'W';
  FButtons[bOrbit].Caption := 'ORBIT';      FButtons[bOrbit].Key := 'A';
  FButtons[bLabels].Caption := 'LABELS';    FButtons[bLabels].Key := 'L';
  FButtons[bRedraw].Caption := 'REDRAW';    FButtons[bRedraw].Key := 'R';
  FButtons[bVSync].Caption := 'VSYNC';      FButtons[bVSync].Key := 'V';
  FButtons[bDev].Caption := 'DEV';          FButtons[bDev].Key := 'F12';

  Audio := TAudio.Create;
  HoverObj := -1;
  ShowHud := True;
  ShowFlash := True;
  LogFmt('app', 'start: %d render threads, refresh %d Hz, swap interval %d, %s',
    [FPool.ThreadCount, FRefreshHz, FSwapInterval, BoolToStr(FUseGL, 'OpenGL', 'GDI')]);

  if (ParamStr(1) = '--shot') and (ParamStr(4) = 'explode') then FScene.ExplodeOn := True;
  if (ParamStr(1) = '--shot') and (ParamStr(6) <> '') then
  begin
    FScene.Yaw := StrToFloatDef(ParamStr(6), FScene.Yaw);
    FScene.Pitch := StrToFloatDef(ParamStr(7), FScene.Pitch);
    FScene.AutoOrbit := False;
  end;

  FLastTick := NowMs;
  FNextFrame := FLastTick;
  FFpsTime := FLastTick;
  Application.AddOnIdleHandler(@AppIdle);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  {$IFDEF WINDOWS}
  timeEndPeriod(1);
  {$ENDIF}
  if Recording then StopRecording;
  Audio.Free;
  FPool.Free;
  FScene.Free;
  FFrame.Free;
  FPaper.Free;
  FMeasure.Free;
  FTextCache.Free;
end;

function TMainForm.NowMs: double;
{$IFDEF WINDOWS}
var
  C: int64;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  QueryPerformanceCounter(C);
  // double(C): with a bare 1000.0 (a single constant) FPC computes this in single precision,
  // which rounds the timestamp to 64 ms steps after a few days of uptime
  Result := double(C) * 1000 / FFreq;
  {$ELSE}
  Result := GetTickCount64;
  {$ENDIF}
end;

function TMainForm.OutputName: string;
begin
  if not FUseGL then
    Result := 'GDI 60 Hz timer'
  else if FVSync and FVSyncSupported then
    Result := Format('OpenGL vsync %d Hz / %d', [FRefreshHz, FSwapInterval])
  else if FVSync then
    Result := 'OpenGL (no vsync ext)'
  else
    Result := 'OpenGL, vsync off';
end;

{ ------------------------------------------------------------ frame loop }

procedure TMainForm.AppIdle(Sender: TObject; var Done: boolean);
var
  T: double;
begin
  Done := False;
  if WindowState = wsMinimized then
  begin
    Sleep(10);
    Exit;
  end;
  if FUseGL and FVSync and FVSyncSupported then
  begin
    DoFrame;                         // SwapBuffers paces us
    Exit;
  end;
  T := NowMs;
  if T < FNextFrame then
  begin
    if FNextFrame - T > 1.5 then Sleep(1);
    Exit;
  end;
  FNextFrame := FNextFrame + 1000 / 60;
  if FNextFrame < T then FNextFrame := T + 1000 / 60;
  DoFrame;
end;

procedure TMainForm.DoFrame;
var
  T0, T1, T2, T3, Fl: double;
  W, H: integer;
  NoHud: boolean;
begin
  T0 := NowMs;
  FScene.Update(Min(0.05, (T0 - FLastTick) / 1000));
  FLastTick := T0;
  // sounds raised by the animation
  if FScene.SoundEvents and seAutofocus <> 0 then Audio.Play(sndAutofocus);
  if FScene.SoundEvents and seShutter <> 0 then
  begin
    Audio.Play(sndShutter);
    LogFmt('camera', 'exposure No. %d at %s f/%s ISO %d %d mm', [FScene.Shots, ShutterNames[FScene.ShutterIdx],
      FormatFloat('0.#', FStops[FScene.ApertureIdx]), IsoValues[FScene.IsoIdx], FScene.FocalMm]);
  end;
  FScene.SoundEvents := 0;
  if FScene.Shots <> FLastShots then
  begin
    FLastShots := FScene.Shots;
    FShotFlash := 1;
  end;
  FShotFlash := Max(0, FShotFlash - 0.02);

  W := Max(64, FOutput.Width);
  H := Max(64, FOutput.Height);
  if (FCapPath <> '') and (FCapScale > 1) then
  begin
    // high resolution still: this one frame is drawn bigger (GL just shows it scaled down)
    W := W * FCapScale;
    H := H * FCapScale;
  end;
  EnsurePaper(W, H);
  if (FFrame.Width <> W) or (FFrame.Height <> H) then FFrame.SetSize(W, H);
  LayoutButtons;

  FScene.Build(W, H);
  T1 := NowMs;
  DrawLabels;
  NoHud := not ShowHud or ((FCapPath <> '') and not FCapHud) or (Recording and not FRecHud);
  if not NoHud then DrawHud;
  if (HoverObj >= 0) and (FCapPath = '') and not Recording then DrawHover;
  T2 := NowMs;
  if ShowFlash then Fl := FScene.Flash else Fl := 0;
  FPool.RenderFrame(FFrame, FPaper, FScene, Fl);
  T3 := NowMs;
  CaptureFrames;
  FBuildMs := FBuildMs * 0.9 + (T1 - T0) * 0.1;
  FHudMs := FHudMs * 0.9 + (T2 - T1) * 0.1;
  FRasterMs := FRasterMs * 0.9 + (T3 - T2) * 0.1;
  Present;
  FCpuMs := FCpuMs * 0.9 + (NowMs - T0 - FWaitMs) * 0.1;

  // --shot <file.png> <seconds> [explode]: save one frame and quit (for docs and checks)
  if (ParamStr(1) = '--shot') and (FScene.Time >= StrToFloatDef(ParamStr(3), 5)) then
  begin
    FFrame.SaveToFile(ParamStr(2));
    with TStringList.Create do
    try
      Add(Format('fps=%.1f cpu=%.2f build=%.2f raster=%.2f hud=%.2f wait=%.2f threads=%d prims=%d',
        [FFps, FCpuMs, FBuildMs, FRasterMs, FHudMs, FWaitMs, FPool.ThreadCount, FScene.Count]));
      Add(LogTail(300));
      SaveToFile(ChangeFileExt(ParamStr(2), '.txt'));
    finally
      Free;
    end;
    Application.Terminate;
  end;

  if ParamStr(1) = '--devtest' then DevTestStep;

  // history for the developer graphs
  HistFrame[HistPos] := T0 - FPrevFrameT;
  HistCpu[HistPos] := NowMs - T0 - FWaitMs;
  HistRaster[HistPos] := T3 - T2;
  HistPos := (HistPos + 1) mod HistLen;
  if (FPrevFrameT > 0) and (T0 - FPrevFrameT > 50) and (FScene.Time > 0.5) then
    LogFmt('perf', 'slow frame: %.1f ms since the previous one', [T0 - FPrevFrameT]);
  FPrevFrameT := T0;

  Inc(FFrames);
  if T0 - FFpsTime >= 500 then
  begin
    FFps := FFrames * 1000 / (T0 - FFpsTime);
    if Trunc(T0 / 2000) <> Trunc(FFpsTime / 2000) then LogFmt('perf', 'fps %.1f', [FFps]);
    FFrames := 0;
    FStats[0] := FormatFloat('0.0', FFps);
    FStats[1] := FormatFloat('0.00', FCpuMs);
    FStats[2] := FormatFloat('0.00', FRasterMs);
    FStats[3] := IntToStr(FPool.ThreadCount);
    FStats[4] := IntToStr(FScene.Count);
    FStats[5] := FormatFloat('0.00', FBuildMs);
    FStats[6] := FormatFloat('0.00', FHudMs);
    FFpsTime := T0;
  end;
end;

{ ------------------------------------------------------------ paper }

procedure TMainForm.EnsurePaper(W, H: integer);
begin
  if (FPaperW = W) and (FPaperH = H) then Exit;
  FPaperW := W;
  FPaperH := H;
  FPaper.SetSize(W, H);
  FPool.BuildPaper(FPaper);           // grain on all cores
  DrawPaperSheet;                     // border, zones, title block lines
  LogFmt('view', 'frame size %dx%d', [W, H]);
end;

// Drawing-sheet furniture that never changes: frame, zone marks, title block grid.
procedure TMainForm.DrawPaperSheet;
var
  W, H, i, n: integer;
  X, Y, TX, TY: single;
begin
  W := FPaper.Width;
  H := FPaper.Height;
  FPaper.FontName := 'Bahnschrift';
  FPaper.FontQuality := fqFineAntialiasing;
  FPaper.FontHeight := 11;
  FPaper.FontStyle := [];
  FPaper.RectangleAntialias(Margin - 6, Margin - 6, W - Margin + 6, H - Margin + 6, InkSoft, 0.8);
  FPaper.RectangleAntialias(Margin, Margin, W - Margin, H - Margin, Ink, 1.6);
  // zones: numbers along top/bottom, letters along the sides
  n := Max(4, W div 170);
  for i := 0 to n do
  begin
    X := Margin + (W - 2 * Margin) * i / n;
    FPaper.DrawLineAntialias(X, Margin - 6, X, Margin, InkSoft, 0.8);
    FPaper.DrawLineAntialias(X, H - Margin, X, H - Margin + 6, InkSoft, 0.8);
    if i < n then
    begin
      X := Margin + (W - 2 * Margin) * (i + 0.5) / n;
      FPaper.TextOut(X, Margin - 7.5, IntToStr(i + 1), InkSoft, taCenter);
      FPaper.TextOut(X, H - Margin - 1, IntToStr(i + 1), InkSoft, taCenter);
    end;
  end;
  n := Max(3, H div 170);
  for i := 0 to n do
  begin
    Y := Margin + (H - 2 * Margin) * i / n;
    FPaper.DrawLineAntialias(Margin - 6, Y, Margin, Y, InkSoft, 0.8);
    FPaper.DrawLineAntialias(W - Margin, Y, W - Margin + 6, Y, InkSoft, 0.8);
    if i < n then
    begin
      Y := Margin + (H - 2 * Margin) * (i + 0.5) / n - 7;
      FPaper.FontHeight := 9;
      FPaper.TextOut(Margin - 3, Y, Chr(Ord('A') + i), InkSoft, taCenter);
      FPaper.TextOut(W - Margin + 3, Y, Chr(Ord('A') + i), InkSoft, taCenter);
    end;
  end;
  FPaper.InvalidateBitmap;
end;

{ ------------------------------------------------------------ HUD (main thread) }

// Rendering text through the LCL font engine is slow, so every distinct
// (text, size, weight, colour) is rendered once into a sprite and reused.
function TMainForm.TextSprite(const S: string; Size: integer; Bold: boolean; C: TBGRAPixel): TBGRABitmap;
var
  Key: string;
  i: integer;
  Sz: TSize;
begin
  Key := Format('%d|%d|%d|%d|%d|', [Size, Ord(Bold), C.red, C.green, C.blue]) + S;
  if FTextCache.Find(Key, i) then Exit(TBGRABitmap(FTextCache.Objects[i]));
  if FTextCache.Count > 600 then FTextCache.Clear;
  FMeasure.FontHeight := Size;
  if Bold then FMeasure.FontStyle := [fsBold] else FMeasure.FontStyle := [];
  Sz := FMeasure.TextSize(S);
  Result := TBGRABitmap.Create(Max(1, Sz.cx + 2), Max(1, Sz.cy), BGRAPixelTransparent);
  Result.FontName := FMeasure.FontName;
  Result.FontQuality := fqFineAntialiasing;
  Result.FontHeight := Size;
  Result.FontStyle := FMeasure.FontStyle;
  C.alpha := 255;
  Result.TextOut(1, 0, S, C);
  FTextCache.AddObject(Key, Result);
end;

function TMainForm.Txt(X, Y: single; const S: string; Size: integer; Bold: boolean; C: TBGRAPixel;
  AAlign: TAlignment): single;
var
  Sp: TBGRABitmap;
begin
  Sp := TextSprite(S, Size, Bold, C);
  Result := Sp.Width;
  case AAlign of
    taCenter: X := X - Sp.Width / 2;
    taRightJustify: X := X - Sp.Width;
  end;
  if C.alpha > 0 then
    FPool.AddSprite(Round(X), Round(Y), Sp, C.alpha);
end;

function TMainForm.TextW(const S: string; Size: integer; Bold: boolean): single;
begin
  Result := TextSprite(S, Size, Bold, Ink).Width;
end;

function TMainForm.TextH(Size: integer): single;
begin
  Result := TextSprite('Ag', Size, False, Ink).Height;
end;

procedure TMainForm.DrawLabels;
var
  i: integer;
  L: TSceneLabel;
  C: TBGRAPixel;
  TW, TH, X, Y: single;
begin
  for i := 0 to FScene.LabelCount - 1 do
  begin
    L := FScene.Labels[i];
    case L.Kind of
      lkDim: if not FScene.LayerOn[okDim] then Continue;
      lkCallout, lkTag: if not FScene.LayerOn[okCallout] then Continue;
      lkTiny: if not FScene.LayerOn[okMarking] then Continue;
    end;
    C := Ink;
    C.alpha := Round(C.alpha * L.Alpha);
    case L.Kind of
      lkDim:
        begin
          TW := TextW(L.Text, 13, False);
          TH := TextH(13);
          FPool.AddFill(L.X - TW / 2 - 5, L.Y - TH / 2 - 1, L.X + TW / 2 + 5, L.Y + TH / 2 + 1, BGRA(246, 244, 236, Round(235 * L.Alpha)));
          FPool.AddRect(L.X - TW / 2 - 5, L.Y - TH / 2 - 1, L.X + TW / 2 + 5, L.Y + TH / 2 + 1, BGRA(46, 52, 66, Round(170 * L.Alpha)), 0.8);
          Txt(L.X, L.Y - TH / 2, L.Text, 13, False, C, taCenter);
        end;
      lkTag:
        begin
          TW := Max(TextW(L.Text, 11, True) + 6, 17);
          TH := 17;
          if L.Align = taLeftJustify then X := L.X else X := L.X - TW;
          Y := L.Y - TH / 2;
          FPool.AddFill(X, Y, X + TW, Y + TH, BGRA(246, 244, 236, Round(240 * L.Alpha)));
          FPool.AddRect(X, Y, X + TW, Y + TH, C, 1);
          Txt(X + TW / 2, Y + (TH - TextH(11)) / 2, L.Text, 11, True, C, taCenter);
        end;
      lkCallout:
        begin
          TH := TextH(12);
          TW := TextW(L.Text, 12, False);
          if L.Align = taLeftJustify then X := L.X else X := L.X - TW;
          FPool.AddFill(X - 3, L.Y - TH / 2, X + TW + 3, L.Y + TH / 2,
            BGRA(244, 242, 234, Round(200 * L.Alpha)));
          Txt(X, L.Y - TH / 2, L.Text, 12, False, C);
        end;
      lkTiny:
        Txt(L.X, L.Y - TextH(9) / 2, L.Text, 9, False, BGRA(30, 30, 38, Round(215 * L.Alpha)), taCenter);
    end;
  end;
end;

procedure TMainForm.LayoutButtons;
var
  B: TButtonId;
  X, Y: single;
begin
  X := Margin + 14;
  Y := FFrame.Height - Margin - 48;
  for B := Low(TButtonId) to High(TButtonId) do
  begin
    FButtons[B].R := RectF(X, Y, X + 92, Y + 34);
    X := X + 100;
  end;
end;

procedure TMainForm.DrawHud;
const
  Captions: array[0..2, 0..3] of string = (
    ('FPS', 'CPU MS', 'RASTER MS', 'THREADS'),
    ('PRIMS', 'BUILD MS', 'HUD MS', 'SIZE'),
    ('OUTPUT', '', 'SHOTS', 'FOCAL'));
var
  W, H: integer;
  B: TButtonId;
  R: TRectF;
  IsOn: boolean;
  C: TBGRAPixel;
  TX, TY, X, A: single;
  S: string;
  i: integer;

  procedure Cell(Col, Row: integer; const V: string);
  begin
    Txt(TX + TitleW * Col / 4 + 5, TY + 46 + Row * 28, V, 13, False, Ink);
  end;

begin
  W := FFrame.Width;
  H := FFrame.Height;

  // heading, top left
  Txt(Margin + 16, Margin + 12, 'LZ-1  SYSTEM CAMERA', 26, True, Ink);
  Txt(Margin + 18, Margin + 44, Format('PENCIL STUDY  ·  %d PARTS  ·  PERSPECTIVE, NOT TO SCALE',
    [Length(FScene.Parts)]), 12, False, InkSoft);
  FPool.AddLine(Margin + 16, Margin + 62, Margin + 330, Margin + 62, Ink, 1.2);

  // exposure readout, top right
  X := W - Margin - 18;
  Txt(X, Margin + 12, 'SHUTTER        APERTURE        ISO        FOCAL', 11, False, InkSoft, taRightJustify);
  S := Format('%s   f/%s   %d   %dmm', [ShutterNames[FScene.ShutterIdx],
    FormatFloat('0.#', FStops[FScene.ApertureIdx]), IsoValues[FScene.IsoIdx], FScene.FocalMm]);
  Txt(X, Margin + 26, S, 28, True, Ink, taRightJustify);
  C := InkRed;
  C.alpha := Round(120 + 110 * FShotFlash);
  Txt(X, Margin + 62, Format('No. %.4d', [FScene.Shots]), 12, False, C, taRightJustify);
  // focus confirmation brackets while the shutter sequence runs
  if FScene.ShotT >= 0 then
  begin
    A := Min(1, FScene.ShotT * 6) * (1 - Max(0, FScene.ShotT - 0.8) * 3);
    if A > 0 then
    begin
      C := InkRed;
      C.alpha := Round(220 * A);
      R := RectF(W / 2 - 70, H * 0.52 - 50, W / 2 + 70, H * 0.52 + 50);
      for i := 0 to 3 do
      begin
        if i and 1 = 0 then X := R.Left else X := R.Right;
        if i and 2 = 0 then TY := R.Top else TY := R.Bottom;
        FPool.AddLine(X, TY, X + IfThen(i and 1 = 0, 16, -16), TY, C, 2);
        FPool.AddLine(X, TY, X, TY + IfThen(i and 2 = 0, 16, -16), C, 2);
      end;
      Txt(W / 2, R.Bottom + 6, 'AF ●  LOCK', 11, False, C, taCenter);
    end;
  end;

  // buttons, bottom left
  for B := Low(TButtonId) to High(TButtonId) do
  begin
    R := FButtons[B].R;
    case B of
      bExplode: IsOn := FScene.ExplodeOn;
      bWire: IsOn := FScene.Wire;
      bOrbit: IsOn := FScene.AutoOrbit;
      bLabels: IsOn := FScene.ShowLabels;
      bVSync: IsOn := FVSync;
      bShutter: IsOn := FScene.ShotT >= 0;
    else
      IsOn := False;
    end;
    if FButtons[B].Down then R.Offset(0, 1.5);
    FPool.AddFill(R.Left + 3, R.Top + 3, R.Right + 3, R.Bottom + 3, BGRA(40, 40, 48, 40));
    if IsOn then
      FPool.AddFill(R.Left, R.Top, R.Right, R.Bottom, BGRA(52, 52, 62, 235))
    else
      FPool.AddFill(R.Left, R.Top, R.Right, R.Bottom, BGRA(246, 244, 236, 245));
    if FButtons[B].Hover then C := InkBlue else C := Ink;
    FPool.AddRect(R.Left, R.Top, R.Right, R.Bottom, C, IfThen(FButtons[B].Hover, 2, 1.2));
    // pencil overshoot on the corners
    FPool.AddLine(R.Left - 4, R.Top, R.Left + 8, R.Top, C, 0.8);
    FPool.AddLine(R.Right + 4, R.Bottom, R.Right - 8, R.Bottom, C, 0.8);
    if IsOn then C := BGRA(246, 244, 236, 255) else C := Ink;
    Txt((R.Left + R.Right) / 2, R.Top + 3, FButtons[B].Caption, 13, True, C, taCenter);
    C.alpha := 150;
    Txt((R.Left + R.Right) / 2, R.Top + 19, FButtons[B].Key, 10, False, C, taCenter);
  end;
  Txt(Margin + 16, FButtons[bShutter].R.Top - 18,
    'DRAG orbit · WHEEL zoom lens · CTRL+WHEEL / RIGHT DRAG distance · [ ] shutter · ' +
    #$E2#$86#$91#$E2#$86#$93 + ' ISO · ' + #$E2#$86#$90#$E2#$86#$92 + ' aperture · F11 fullscreen · F12 developer',
    11, False, InkSoft);

  // title block: part of the HUD so the drawing never runs over it
  TX := W - Margin - TitleW;
  TY := H - Margin - TitleH;
  FPool.AddFill(TX, TY, W - Margin, H - Margin, BGRA(246, 244, 237, 255));
  FPool.AddRect(TX, TY, W - Margin, H - Margin, Ink, 1.4);
  FPool.AddLine(TX, TY + 34, W - Margin, TY + 34, Ink, 1);
  FPool.AddLine(TX, TY + 62, W - Margin, TY + 62, InkSoft, 0.8);
  FPool.AddLine(TX, TY + 90, W - Margin, TY + 90, InkSoft, 0.8);
  for i := 1 to 3 do
    FPool.AddLine(TX + TitleW * i / 4, TY + 34, TX + TitleW * i / 4, H - Margin, InkSoft, 0.8);
  Txt(TX + 6, TY + 3, 'TITLE', 9, False, InkSoft);
  Txt(W - Margin - 6, TY + 3, 'DWG NO. LZ-1-001', 9, False, InkSoft, taRightJustify);
  for i := 0 to 11 do
    Txt(TX + TitleW * (i mod 4) / 4 + 5, TY + 36 + (i div 4) * 28, Captions[i div 4, i mod 4], 9, False, InkSoft);
  Txt(TX + 6, TY + 14, 'LZ-1 CAMERA  ·  GENERAL ARRANGEMENT', 15, True, Ink);
  // numbers change every frame: they are refreshed twice a second so the text cache stays small
  for i := 0 to 6 do Cell(i mod 4, i div 4, FStats[i]);
  Cell(3, 1, Format('%dx%d', [W, H]));
  Txt(TX + 5, TY + 104, OutputName, 11, False, Ink);
  Cell(2, 2, IntToStr(FScene.Shots));
  Cell(3, 2, IntToStr(FScene.FocalMm) + ' mm');
end;

{ ------------------------------------------------------------ output }

procedure TMainForm.Present;
var
  T: double;
begin
  T := NowMs;
  if FUseGL then
    try
      PresentGL;
    except
      on E: Exception do UseGDI(E.Message);
    end
  else
  begin
    FWaitMs := 0;
    FView.Repaint;
  end;
  if not FUseGL then FWaitMs := 0;
  T := NowMs - T;
end;

procedure TMainForm.UseGDI(const Reason: string);
begin
  FUseGL := False;
  if FGL <> nil then FGL.Visible := False;
  FView.Visible := True;
  FOutput := FView;
  FWaitMs := 0;
  Caption := Caption + '   [GDI: ' + Reason + ']';
end;

procedure TMainForm.PresentGL;
type
  TSwapIntervalProc = function(Interval: longint): LongBool; stdcall;
const
  GL_BGRA = $80E1;
  GL_CLAMP_TO_EDGE = $812F;
var
  SwapInterval: TSwapIntervalProc;
  V0, V1, T: double;
begin
  if not FGL.MakeCurrent then
    raise Exception.Create('cannot make the OpenGL context current');
  if not FGLReady then
  begin
    glGenTextures(1, @FTexture);
    glBindTexture(GL_TEXTURE_2D, FTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    GLVendor := StrPas(PChar(glGetString(GL_VENDOR)));
    GLRenderer := StrPas(PChar(glGetString(GL_RENDERER)));
    GLVersion := StrPas(PChar(glGetString(GL_VERSION)));
    Log('gl', GLRenderer + ' / ' + GLVersion);
    FTexW := 0;
    FGLReady := True;
    FVSyncApplied := not FVSync;
  end;
  if FVSyncApplied <> FVSync then
  begin
    {$IFDEF WINDOWS}
    Pointer(SwapInterval) := wglGetProcAddress('wglSwapIntervalEXT');
    FVSyncSupported := Assigned(SwapInterval);
    if FVSyncSupported then
      SwapInterval(IfThen(FVSync, FSwapInterval, 0));
    {$ENDIF}
    FVSyncApplied := FVSync;
  end;

  glViewport(0, 0, FGL.Width, FGL.Height);
  glBindTexture(GL_TEXTURE_2D, FTexture);
  if (FTexW <> FFrame.Width) or (FTexH <> FFrame.Height) then
  begin
    FTexW := FFrame.Width;
    FTexH := FFrame.Height;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, FTexW, FTexH, 0, GL_BGRA, GL_UNSIGNED_BYTE, FFrame.Data);
  end
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, FTexW, FTexH, GL_BGRA, GL_UNSIGNED_BYTE, FFrame.Data);

  if FFrame.LineOrder = riloBottomToTop then
  begin
    V0 := 0;
    V1 := 1;
  end
  else
  begin
    V0 := 1;
    V1 := 0;
  end;
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glEnable(GL_TEXTURE_2D);
  glColor4f(1, 1, 1, 1);
  glBegin(GL_QUADS);
    glTexCoord2f(0, V0); glVertex2f(-1, -1);
    glTexCoord2f(1, V0); glVertex2f(1, -1);
    glTexCoord2f(1, V1); glVertex2f(1, 1);
    glTexCoord2f(0, V1); glVertex2f(-1, 1);
  glEnd;

  T := NowMs;
  FGL.SwapBuffers;
  glFinish;                          // no frames queued ahead: input stays one frame behind at most
  FWaitMs := FWaitMs * 0.9 + (NowMs - T) * 0.1;
end;

procedure TMainForm.GLPaint(Sender: TObject);
begin
  if FUseGL and (FFrame.Width > 16) then
    try
      PresentGL;
    except
      on E: Exception do UseGDI(E.Message);
    end;
end;

procedure TMainForm.ViewPaint(Sender: TObject);
begin
  FFrame.Draw(FView.Canvas, 0, 0, True);
end;

{ ------------------------------------------------------------ input }

procedure TMainForm.PressButton(B: TButtonId);
begin
  case B of
    bShutter: FScene.FireShutter;
    bExplode: FScene.ExplodeOn := not FScene.ExplodeOn;
    bWire: FScene.Wire := not FScene.Wire;
    bOrbit:
      begin
        FScene.AutoOrbit := not FScene.AutoOrbit;
        FScene.IdleTime := 2.5;
      end;
    bLabels: FScene.ShowLabels := not FScene.ShowLabels;
    bRedraw: FScene.Replay;
    bVSync:
      begin
        FVSync := not FVSync;
        FNextFrame := NowMs;
      end;
    bDev: ToggleDev;
  end;
  if B = bExplode then Audio.Play(sndWhoosh);
  Log('input', FButtons[B].Caption);
end;

procedure TMainForm.OutMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  B: TButtonId;
begin
  for B := Low(TButtonId) to High(TButtonId) do
    if (Button = mbLeft) and FButtons[B].R.Contains(PointF(X, Y)) then
    begin
      FButtons[B].Down := True;
      PressButton(B);
      Exit;
    end;
  FDragging := Button = mbLeft;
  FRightDrag := Button = mbRight;
  FLastX := X;
  FLastY := Y;
  FScene.IdleTime := 0;
end;

procedure TMainForm.OutMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
var
  B: TButtonId;
begin
  FMouse := PointF(X, Y);
  for B := Low(TButtonId) to High(TButtonId) do
    FButtons[B].Hover := FButtons[B].R.Contains(FMouse);
  if FDragging then
  begin
    FScene.Yaw := FScene.Yaw + (X - FLastX) * 0.008;
    FScene.Pitch := EnsureRange(FScene.Pitch + (Y - FLastY) * 0.006, 0.06, 1.25);
    // keep the last motion as inertia for a soft release
    FScene.YawVel := (X - FLastX) * 0.008 * 60 * 0.5;
    FScene.PitchVel := (Y - FLastY) * 0.006 * 60 * 0.5;
    FScene.IdleTime := 0;
  end
  else if FRightDrag then
  begin
    FScene.Distance := EnsureRange(FScene.Distance + (Y - FLastY) * 0.12, 28, 90);
    FScene.IdleTime := 0;
  end;
  FLastX := X;
  FLastY := Y;
end;

procedure TMainForm.OutMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  B: TButtonId;
begin
  for B := Low(TButtonId) to High(TButtonId) do FButtons[B].Down := False;
  if Button = mbLeft then FDragging := False;
  if Button = mbRight then FRightDrag := False;
end;

procedure TMainForm.OutMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: integer;
  MousePos: TPoint; var Handled: boolean);
begin
  if ssCtrl in Shift then
    FScene.Distance := EnsureRange(FScene.Distance - WheelDelta / 120 * 2.5, 28, 90)
  else
  begin
    FScene.ZoomTarget := EnsureRange(FScene.ZoomTarget + WheelDelta / 120 * 0.08, 0, 1);
    Audio.Play(sndTick);
  end;
  Handled := True;
end;

procedure TMainForm.ToggleFullScreen;
begin
  if not FFullScreen then
  begin
    FOldState := WindowState;
    FOldBounds := BoundsRect;
    BorderStyle := bsNone;
    WindowState := wsFullScreen;
    FFullScreen := True;
  end
  else
  begin
    BorderStyle := bsSizeable;
    WindowState := FOldState;
    if FOldState = wsNormal then BoundsRect := FOldBounds;
    FFullScreen := False;
  end;
end;

{ ------------------------------------------------------------ developer window support }

// --devtest <dir>: drive the developer window and the exports, then quit.
procedure TMainForm.DevTestStep;
var
  Dir: string;
  T: double;
begin
  Dir := IncludeTrailingPathDelimiter(ParamStr(2));
  T := FScene.Time;
  case FTestStep of
    0: if T > 1 then
       begin
         ToggleDev;
         HoverObj := 2;
         Inc(FTestStep);
       end;
    1: if (T > 1.6) and not ExportBusy then
       begin
         FFrame.SaveToFile(Dir + 'main_hover.png');
         HoverObj := -1;
         RequestStill(Dir + 'still2x.png', 2, False);
         Inc(FTestStep);
       end;
    2: if (T > 2.2) and not ExportBusy then
       begin
         StartRecording(False, 2, 10, 0.5, False, '');
         Inc(FTestStep);
       end;
    3: if not Recording and not ExportBusy and (T > 4.5) then
       begin
         Log('test', 'GIF result: ' + ExportStatus);
         StartRecording(True, 3, 60, 1, True, '');
         Inc(FTestStep);
       end;
    4: if not Recording and not ExportBusy then
       begin
         Log('test', 'MP4 result: ' + ExportStatus);
         FScene.LayerOn[okGrid] := False;
         FScene.LayerOn[okConstruct] := False;
         FTestT := T;
         Inc(FTestStep);
       end;
    5: if T > FTestT + 0.5 then
       begin
         FFrame.SaveToFile(Dir + 'main_layers_off.png');
         HoverObj := 113;            // not a real row: must be ignored safely
         TDevForm(Dev).SaveTabShots(Dir);
         with TStringList.Create do
         try
           Text := LogTail(400);
           SaveToFile(Dir + 'log.txt');
         finally
           Free;
         end;
         Application.Terminate;
         Inc(FTestStep);
       end;
  end;
end;

procedure TMainForm.ToggleDev;
begin
  if Dev = nil then
  begin
    Dev := TDevForm.Create(Application);
    // next to the main window when there is room, else over its right part
    Dev.Left := Min(Left + Width + 4, Screen.Width - Dev.Width);
    Dev.Top := Top;
  end;
  if Dev.Visible then Dev.Hide else Dev.Show;
end;

// Thin dashed box around the object under the mouse in the developer object list.
procedure TMainForm.DrawHover;
var
  B: TRectF;
  ObjName: string;
  C: TBGRAPixel;

  procedure Dashed(X0, Y0, X1, Y1: single);
  var
    L, T, DX, DY: single;
  begin
    DX := X1 - X0;
    DY := Y1 - Y0;
    L := Sqrt(DX * DX + DY * DY);
    if L < 1 then Exit;
    T := 0;
    while T < L do
    begin
      FPool.AddLine(X0 + DX * T / L, Y0 + DY * T / L, X0 + DX * Min(L, T + 5) / L, Y0 + DY * Min(L, T + 5) / L, C, 1);
      T := T + 9;
    end;
  end;

begin
  if HoverObj < 100 then
  begin
    if HoverObj > High(FScene.PartStats) then Exit;
    B := FScene.PartStats[HoverObj].Box;
    ObjName := FScene.Parts[HoverObj].Name;
  end
  else
  begin
    if HoverObj - 100 >= KindCount then Exit;
    B := FScene.KindStats[HoverObj - 100].Box;
    ObjName := KindNames[HoverObj - 100];
  end;
  if B.Right < B.Left then Exit;      // nothing of it is drawn
  B := RectF(B.Left - 6, B.Top - 6, B.Right + 6, B.Bottom + 6);
  C := BGRA(40, 90, 200, 220);
  Dashed(B.Left, B.Top, B.Right, B.Top);
  Dashed(B.Right, B.Top, B.Right, B.Bottom);
  Dashed(B.Right, B.Bottom, B.Left, B.Bottom);
  Dashed(B.Left, B.Bottom, B.Left, B.Top);
  Txt(B.Left, B.Top - 16, ObjName, 11, False, C);
end;

function TMainForm.ReproCommand: string;
var
  Fs: TFormatSettings;
begin
  Fs := DefaultFormatSettings;
  Fs.DecimalSeparator := '.';
  Result := Format('CameraSketch.exe --shot shot.png 6 %s 0 %s %s',
    [BoolToStr(FScene.ExplodeOn, 'explode', 'x'), FormatFloat('0.000', FScene.Yaw, Fs),
     FormatFloat('0.000', FScene.Pitch, Fs)]);
end;

procedure TMainForm.RequestStill(const Path: string; Scale: integer; WithHud: boolean);
begin
  FCapPath := Path;
  FCapScale := Max(1, Scale);
  FCapHud := WithHud;
end;

procedure TMainForm.StartRecording(Mp4: boolean; Seconds, Fps: integer; Scale: single; WithHud: boolean;
  const FfmpegHint: string);
var
  Exe: string;
begin
  if Recording or ExportBusy then Exit;
  FRecMp4 := Mp4;
  FRecFps := Max(1, Fps);
  FRecHud := WithHud;
  // fixed output size for the whole clip; even numbers for the video encoder
  FRecW := Max(16, Round(FOutput.Width * Scale)) and not 1;
  FRecH := Max(16, Round(FOutput.Height * Scale)) and not 1;
  FRecWriter := nil;
  FRecFrames := nil;
  if Mp4 then
  begin
    Exe := FindFfmpeg(FfmpegHint);
    if Exe <> '' then
    begin
      FRecPath := TimeStampName('clip_', '.mp4');
      try
        FRecWriter := TFfmpegWriter.Create(StartFfmpeg(Exe, FRecPath, FRecW, FRecH, FRecFps), FRecPath);
        Log('export', 'ffmpeg: ' + Exe);
      except
        on E: Exception do
        begin
          Log('export', 'cannot start ffmpeg: ' + E.Message);
          FRecWriter := nil;
        end;
      end;
    end;
    if FRecWriter = nil then
    begin
      FRecPath := ChangeFileExt(TimeStampName('clip_', '.x'), '');      // folder for the PNG sequence
      FRecFrames := TFPList.Create;
    end;
  end
  else
  begin
    FRecPath := TimeStampName('clip_', '.gif');
    FRecFrames := TFPList.Create;
  end;
  FRecStart := NowMs;
  FRecEnd := FRecStart + Seconds * 1000;
  FRecNext := FRecStart;
  Recording := True;
  LogFmt('export', 'recording %s %d s at %d fps, %dx%d -> %s', [BoolToStr(Mp4, 'MP4', 'GIF'), Seconds, FRecFps,
    FRecW, FRecH, FRecPath]);
end;

procedure TMainForm.CaptureFrames;
var
  L: TFPList;
  B, Extra: TBGRABitmap;
  T: double;
  N: integer;
begin
  if FCapPath <> '' then
  begin
    if not ExportBusy then
    begin
      L := TFPList.Create;
      L.Add(FFrame.Duplicate);
      TExportThread.Create(ekStill, L, FCapPath, 1, nil);
    end
    else
      Log('export', 'still skipped: an export is still being written');
    FCapPath := '';
  end;
  if not Recording then Exit;
  T := NowMs;
  if T >= FRecNext then
  begin
    if (FFrame.Width = FRecW) and (FFrame.Height = FRecH) then
      B := FFrame.Duplicate as TBGRABitmap
    else
      B := FFrame.Resample(FRecW, FRecH, rmFineResample) as TBGRABitmap;
    // one clip frame per 1/fps of real time: a late loop frame fills the slots it
    // missed, so the clip lasts as long as the recording did
    N := 0;
    while (T >= FRecNext) and (N < 8) do
    begin
      FRecNext := FRecNext + 1000 / FRecFps;
      Inc(N);
      if (T >= FRecNext) and (N < 8) then Extra := B.Duplicate as TBGRABitmap else Extra := B;
      if FRecWriter <> nil then FRecWriter.Push(Extra) else FRecFrames.Add(Extra);
    end;
    if T >= FRecNext then FRecNext := T + 1000 / FRecFps;    // hopelessly behind: resync
  end;
  if T >= FRecEnd then StopRecording;
end;

procedure TMainForm.StopRecording;
begin
  if not Recording then Exit;
  Recording := False;
  if FRecWriter <> nil then
    FRecWriter.Finish
  else if (FRecFrames <> nil) and (FRecFrames.Count > 0) then
  begin
    if FRecMp4 then
      TExportThread.Create(ekPngSeq, FRecFrames, FRecPath, FRecFps, nil)
    else
      TExportThread.Create(ekGif, FRecFrames, FRecPath, FRecFps, nil);
  end
  else
    FreeAndNil(FRecFrames);
  FRecWriter := nil;
  FRecFrames := nil;
  Log('export', 'recording stopped, encoding in the background');
end;

function TMainForm.RecordStatus: string;
var
  N: integer;
begin
  if FRecFrames <> nil then N := FRecFrames.Count else N := Round((NowMs - FRecStart) / 1000 * FRecFps);
  Result := Format('Recording %.1f / %.1f s, %d frames, %dx%d', [(NowMs - FRecStart) / 1000,
    (FRecEnd - FRecStart) / 1000, N, FRecW, FRecH]);
end;

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_SPACE: PressButton(bShutter);
    VK_E: PressButton(bExplode);
    VK_W: PressButton(bWire);
    VK_A: PressButton(bOrbit);
    VK_L: PressButton(bLabels);
    VK_R: PressButton(bRedraw);
    VK_V: PressButton(bVSync);
    VK_OEM_4, VK_OEM_6, VK_UP, VK_DOWN, VK_RIGHT, VK_LEFT:
      begin
        case Key of
          VK_OEM_4: FScene.ShutterIdx := Max(0, FScene.ShutterIdx - 1);
          VK_OEM_6: FScene.ShutterIdx := Min(High(ShutterNames), FScene.ShutterIdx + 1);
          VK_UP: FScene.IsoIdx := Min(High(IsoValues), FScene.IsoIdx + 1);
          VK_DOWN: FScene.IsoIdx := Max(0, FScene.IsoIdx - 1);
          VK_RIGHT: FScene.ApertureIdx := Min(High(FStops), FScene.ApertureIdx + 1);
          VK_LEFT: FScene.ApertureIdx := Max(0, FScene.ApertureIdx - 1);
        end;
        Audio.Play(sndDial);
        LogFmt('input', 'exposure set to %s f/%s ISO %d', [ShutterNames[FScene.ShutterIdx],
          FormatFloat('0.#', FStops[FScene.ApertureIdx]), IsoValues[FScene.IsoIdx]]);
      end;
    VK_F12: ToggleDev;
    VK_F11: ToggleFullScreen;
    VK_ESCAPE: if FFullScreen then ToggleFullScreen;
  else
    Exit;
  end;
  Key := 0;
end;

end.
