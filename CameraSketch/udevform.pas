unit UDevForm;

{ Developer window (F12 or the DEV button), a separate non-modal window:

  Overview   live tiles, frame-time graph, work per render thread
  Details    every value worth knowing (scene, view, timing, GL, pool, caches)
  Claude     write a note, attach state / objects / log / screenshot, and copy
             or save a Markdown report to paste into Claude Code
  Export     PNG / BMP stills (1x or 2x), GIF / MP4 recordings
  Layers     switch each drawing layer on and off
  Objects    every part and annotation layer with its graphics state; hover a
             row to outline the object with a thin dashed box in the main
             view; rows copy as text (Ctrl+C, right click, Copy all)
  Physics    live tuning of the animation springs and rates
  Audio      synthesised sound effects: on/off, volume, test
  Log        everything the program reports, filter, copy, save }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, ComCtrls, StdCtrls, ExtCtrls, Menus, Clipbrd,
  LCLType, LCLIntf, Spin, Dialogs, BGRABitmap, BGRABitmapTypes;

type
  TPhysRow = record
    Name: string;
    Value: PSingle;
    Min, Max, Def: single;
    Track: TTrackBar;
    Lbl: TLabel;
  end;

  { TDevForm }

  TDevForm = class(TForm)
  private
    FPages: TPageControl;
    FTimer: TTimer;
    FTick: integer;
    // overview
    FOverview: TPaintBox;
    FOvBuf: TBitmap;
    // details
    FDetails: TListView;
    // claude
    FMsg, FPreview: TMemo;
    FIncState, FIncObjects, FIncPhysics, FIncLog, FIncShot: TCheckBox;
    FReportPath: TLabel;
    // export
    FStillFmt, FStillScale, FAnimFmt, FAnimFps, FAnimScale: TComboBox;
    FStillHud, FAnimHud: TCheckBox;
    FAnimSecs: TSpinEdit;
    FFfmpeg: TEdit;
    FFfmpegInfo, FExportStatus: TLabel;
    FRecButton: TButton;
    // layers
    FLayers: TListView;
    FLayerSync: boolean;
    // objects
    FObjects: TListView;
    FObjCode: array of integer;      // row -> part index, or 100 + layer
    // physics
    FPhys: array of TPhysRow;
    FPhysLive: TMemo;
    FPhysSync: boolean;
    // audio
    FAudioOn: TCheckBox;
    FVolume: TTrackBar;
    FSoundChecks: array of TCheckBox;
    FSoundInfo: array of TLabel;
    FAudioLast: TLabel;
    // log
    FLog: TMemo;
    FLogSeen: int64;
    FLogFilter: TEdit;
    FLogPause, FLogScroll: TCheckBox;

    function NewTab(const ACaption: string): TTabSheet;
    function AddButton(AParent: TWinControl; const ACaption: string; X, Y, W: integer; AClick: TNotifyEvent): TButton;
    function AddLabel(AParent: TWinControl; const ACaption: string; X, Y: integer): TLabel;
    function AddCombo(AParent: TWinControl; X, Y, W: integer; const Items: array of string; Index: integer): TComboBox;
    function AddCheck(AParent: TWinControl; const ACaption: string; X, Y: integer; AChecked: boolean): TCheckBox;
    procedure BuildOverview;
    procedure BuildDetails;
    procedure BuildClaude;
    procedure BuildExport;
    procedure BuildLayers;
    procedure BuildObjects;
    procedure BuildPhysics;
    procedure BuildAudio;
    procedure BuildLog;
    procedure TimerTick(Sender: TObject);
    procedure UpdateTab(const Tab: string);
    procedure OverviewPaint(Sender: TObject);
    procedure PaintOverview(ACanvas: TCanvas; OX, OY: integer);
    procedure RefreshDetails;
    procedure RefreshLayers;
    procedure RefreshObjects;
    procedure RefreshPhysicsLive;
    procedure RefreshAudio;
    procedure RefreshLog(Rebuild: boolean);
    procedure RefreshExport;
    function DetailsText: string;
    function ObjectsText(OnlySelected: boolean): string;
    function PhysicsText: string;
    function BuildReport(const ShotFile: string): string;
    // events
    procedure CopyDetails(Sender: TObject);
    procedure ReportPreview(Sender: TObject);
    procedure ReportCopy(Sender: TObject);
    procedure ReportSave(Sender: TObject);
    procedure StillSave(Sender: TObject);
    procedure RecordClick(Sender: TObject);
    procedure FfmpegBrowse(Sender: TObject);
    procedure OpenExportDir(Sender: TObject);
    procedure LayerChecked(Sender: TObject; Item: TListItem);
    procedure ObjMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure ObjMouseLeave(Sender: TObject);
    procedure ObjKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ObjCopyRow(Sender: TObject);
    procedure ObjCopyAll(Sender: TObject);
    procedure ListCopyKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure PhysChange(Sender: TObject);
    procedure PhysReset(Sender: TObject);
    procedure PhysShutter(Sender: TObject);
    procedure PhysExplode(Sender: TObject);
    procedure AudioChange(Sender: TObject);
    procedure AudioTest(Sender: TObject);
    procedure LogClearClick(Sender: TObject);
    procedure LogCopyClick(Sender: TObject);
    procedure LogSaveClick(Sender: TObject);
    procedure LogFilterChange(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SaveTabShots(const Dir: string);
    procedure DumpControls(P: TWinControl);
    destructor Destroy; override;
  end;

implementation

uses
  UMain, USketchScene, URenderPool, UAudio, ULog, UExport;

const
  Mono = 'Consolas';

function M: TMainForm; inline;
begin
  Result := MainForm;
end;

function SIf(B: boolean; const A, C: string): string;
begin
  if B then Result := A else Result := C;
end;

function F2(V: double): string;
begin
  Result := FormatFloat('0.00', V);
end;

function BoxText(const B: TRectF): string;
begin
  if B.Right < B.Left then Exit('-');
  Result := Format('%d,%d  %dx%d', [Round(B.Left), Round(B.Top), Round(B.Width), Round(B.Height)]);
end;

{ TDevForm }

constructor TDevForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'LZ-1 Developer';
  Width := 760;
  Height := 640;
  Position := poDesigned;
  Font.Name := 'Segoe UI';
  OnCloseQuery := @FormCloseQuery;
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  BuildOverview;
  BuildDetails;
  BuildClaude;
  BuildExport;
  BuildLayers;
  BuildObjects;
  BuildPhysics;
  BuildAudio;
  BuildLog;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;
  FTimer.OnTimer := @TimerTick;
  Log('dev', 'developer window created');
end;

destructor TDevForm.Destroy;
begin
  FOvBuf.Free;
  inherited Destroy;
end;

procedure TDevForm.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  // closing only hides: the tabs keep their state
  CanClose := False;
  Hide;
  M.HoverObj := -1;
end;

{ ------------------------------------------------------------ helpers }

function TDevForm.NewTab(const ACaption: string): TTabSheet;
begin
  Result := FPages.AddTabSheet;
  Result.Caption := ACaption;
end;

function TDevForm.AddButton(AParent: TWinControl; const ACaption: string; X, Y, W: integer;
  AClick: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 27);
  Result.Caption := ACaption;
  Result.OnClick := AClick;
end;

function TDevForm.AddLabel(AParent: TWinControl; const ACaption: string; X, Y: integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Caption := ACaption;
end;

function TDevForm.AddCombo(AParent: TWinControl; X, Y, W: integer; const Items: array of string;
  Index: integer): TComboBox;
var
  S: string;
begin
  Result := TComboBox.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 24);
  Result.Style := csDropDownList;
  for S in Items do Result.Items.Add(S);
  Result.ItemIndex := Index;
end;

function TDevForm.AddCheck(AParent: TWinControl; const ACaption: string; X, Y: integer;
  AChecked: boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Parent := AParent;
  Result.Left := X;
  Result.Top := Y;
  Result.Caption := ACaption;
  Result.Checked := AChecked;
end;

procedure TDevForm.ListCopyKey(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  LV: TListView;
  S: string;
  i, c: integer;
begin
  if not ((Key = VK_C) and (ssCtrl in Shift)) then Exit;
  LV := Sender as TListView;
  S := '';
  for i := 0 to LV.Items.Count - 1 do
    if LV.Items[i].Selected then
    begin
      S := S + LV.Items[i].Caption;
      for c := 0 to LV.Items[i].SubItems.Count - 1 do S := S + #9 + LV.Items[i].SubItems[c];
      S := S + LineEnding;
    end;
  if S <> '' then Clipboard.AsText := S;
  Key := 0;
end;

{ ------------------------------------------------------------ overview }

procedure TDevForm.BuildOverview;
var
  T: TTabSheet;
begin
  T := NewTab('Overview');
  FOverview := TPaintBox.Create(Self);
  FOverview.Parent := T;
  FOverview.Align := alClient;
  FOverview.OnPaint := @OverviewPaint;
end;

procedure TDevForm.OverviewPaint(Sender: TObject);
begin
  PaintOverview(FOverview.Canvas, 0, 0);
end;

// Plain GDI into a double buffer: it repaints a few times a second next to a
// 60 Hz loop, so it must stay cheap (BGRABitmap's antialiased polylines cost ~15 ms here).
procedure TDevForm.PaintOverview(ACanvas: TCanvas; OX, OY: integer);
const
  CBg = $00EDF2F4;
  CInk = $00282222;
  CSoft = $00786E6E;
  CFrame = $003C3C3C;
  CCpu = $00C87828;
  CRaster = $003C8CDC;
  CLimit = $003C3CC8;
var
  W, H, i, k, n, x0, y0, gw, gh, Tw: integer;
  C: TCanvas;
  v, MaxMs, BusyMax: single;
  Tiles: array[0..7, 0..1] of string;
  Pts: array[0..HistLen - 1] of TPoint;

  procedure Series(const Hist: array of single; Col: TColor);
  var
    j: integer;
  begin
    for j := 0 to HistLen - 1 do
    begin
      v := Hist[(M.HistPos + j) mod HistLen];
      Pts[j] := Point(x0 + Round(j * gw / (HistLen - 1)), y0 + gh - Round(Min(1, v / MaxMs) * gh));
    end;
    C.Pen.Color := Col;
    C.Pen.Width := 1;
    C.Polyline(Pts);
  end;

  procedure Txt(X, Y: integer; const S: string; Col: TColor; Size: integer = 12; Bold: boolean = False);
  begin
    C.Font.Height := -Size;
    C.Font.Color := Col;
    if Bold then C.Font.Style := [fsBold] else C.Font.Style := [];
    C.TextOut(X, Y, S);
  end;

begin
  W := FOverview.Width;
  H := FOverview.Height;
  if (W < 10) or (H < 10) then Exit;
  if FOvBuf = nil then FOvBuf := TBitmap.Create;
  if (FOvBuf.Width <> W) or (FOvBuf.Height <> H) then FOvBuf.SetSize(W, H);
  C := FOvBuf.Canvas;
  C.Font.Name := 'Segoe UI';
  C.Brush.Style := bsSolid;
  C.Brush.Color := CBg;
  C.FillRect(0, 0, W, H);
  Tiles[0, 0] := 'FPS';          Tiles[0, 1] := FormatFloat('0.0', M.FFps);
  Tiles[1, 0] := 'CPU / frame';  Tiles[1, 1] := F2(M.FCpuMs) + ' ms';
  Tiles[2, 0] := 'Raster';       Tiles[2, 1] := F2(M.FRasterMs) + ' ms';
  Tiles[3, 0] := 'Threads';      Tiles[3, 1] := IntToStr(M.FPool.ThreadCount);
  Tiles[4, 0] := 'Prims';        Tiles[4, 1] := IntToStr(M.FScene.Count);
  Tiles[5, 0] := 'Labels';       Tiles[5, 1] := IntToStr(M.FScene.LabelCount);
  Tiles[6, 0] := 'Frame size';   Tiles[6, 1] := Format('%dx%d', [M.FFrame.Width, M.FFrame.Height]);
  Tiles[7, 0] := 'Output';       Tiles[7, 1] := M.OutputName;
  Tw := (W - 24) div 4;
  C.Pen.Color := $00CDC8C8;
  for i := 0 to 7 do
  begin
    x0 := 12 + (i mod 4) * Tw;
    y0 := 12 + (i div 4) * 70;
    C.Brush.Color := clWhite;
    C.RoundRect(x0, y0, x0 + Tw - 8, y0 + 62, 10, 10);
    C.Brush.Style := bsClear;
    Txt(x0 + 10, y0 + 6, Tiles[i, 0], CSoft);
    Txt(x0 + 10, y0 + 24, Tiles[i, 1], CInk, IfThen(i = 7, 14, 24), True);
    C.Brush.Style := bsSolid;
  end;

  // frame time graph
  x0 := 12;
  y0 := 180;
  gw := W - 24;
  gh := Max(80, (H - y0) div 2 - 40);
  MaxMs := 40;
  C.Brush.Color := clWhite;
  C.Pen.Color := $00DCDCDC;
  C.Rectangle(x0, y0, x0 + gw, y0 + gh);
  C.Brush.Style := bsClear;
  for k := 0 to 4 do
  begin
    i := y0 + gh - Round(k * 10 / MaxMs * gh);
    C.Pen.Color := $00E1DCDC;
    C.Line(x0, i, x0 + gw, i);
    Txt(x0 + 3, i - 14, IntToStr(k * 10) + ' ms', CSoft, 10);
  end;
  i := y0 + gh - Round(16.67 / MaxMs * gh);
  C.Pen.Color := CLimit;
  C.Line(x0, i, x0 + gw, i);
  Series(M.HistFrame, CFrame);
  Series(M.HistCpu, CCpu);
  Series(M.HistRaster, CRaster);
  Txt(x0, y0 - 18, 'Frame time (last ' + IntToStr(HistLen) + ' frames)', CInk);
  Txt(x0 + 250, y0 - 18, '■ frame interval', CFrame);
  Txt(x0 + 370, y0 - 18, '■ CPU', CCpu);
  Txt(x0 + 430, y0 - 18, '■ raster', CRaster);
  Txt(x0 + 510, y0 - 18, '— 16.7 ms (60 Hz)', CLimit);

  // work per thread
  y0 := y0 + gh + 40;
  n := M.FPool.ThreadCount;
  Txt(x0, y0 - 18, 'Render threads: bands and busy time in the last frame', CInk);
  BusyMax := 0.01;
  for i := 0 to n - 1 do BusyMax := Max(BusyMax, M.FPool.WorkerBusyMs(i));
  gh := Max(10, Min(22, (H - y0 - 10) div Max(1, n)));
  for i := 0 to n - 1 do
  begin
    k := Round(M.FPool.WorkerBusyMs(i) / BusyMax * (gw - 220));
    Txt(x0, y0 + i * gh, Format('#%d', [i]), CSoft, 11);
    C.Brush.Style := bsSolid;
    C.Brush.Color := CRaster;
    C.FillRect(x0 + 34, y0 + i * gh + 2, x0 + 34 + Max(1, k), y0 + (i + 1) * gh - 2);
    C.Brush.Style := bsClear;
    Txt(x0 + 40 + k, y0 + i * gh, Format('%s ms  %d bands', [F2(M.FPool.WorkerBusyMs(i)), M.FPool.WorkerBands(i)]),
      CInk, 11);
  end;
  ACanvas.Draw(OX, OY, FOvBuf);
end;

{ ------------------------------------------------------------ details }

procedure TDevForm.BuildDetails;
var
  T: TTabSheet;
  P: TPanel;
begin
  T := NewTab('Details');
  P := TPanel.Create(Self);
  P.Parent := T;
  P.Align := alTop;
  P.Height := 36;
  P.BevelOuter := bvNone;
  AddButton(P, 'Copy all', 6, 4, 90, @CopyDetails);
  AddLabel(P, 'Ctrl+C copies the selected rows', 110, 10);
  FDetails := TListView.Create(Self);
  FDetails.Parent := T;
  FDetails.Align := alClient;
  FDetails.ViewStyle := vsReport;
  FDetails.ReadOnly := True;
  FDetails.RowSelect := True;
  FDetails.MultiSelect := True;
  FDetails.Font.Name := Mono;
  FDetails.OnKeyDown := @ListCopyKey;
  with FDetails.Columns.Add do begin Caption := 'Property'; Width := 260; end;
  with FDetails.Columns.Add do begin Caption := 'Value'; Width := 440; end;
end;

function TDevForm.DetailsText: string;
var
  S: TCameraScene;
  L: TStringList;
  i: integer;

  procedure A(const N, V: string);
  begin
    L.Add(N + '=' + V);
  end;

begin
  S := M.FScene;
  L := TStringList.Create;
  try
    A('— Timing', '');
    A('FPS', FormatFloat('0.0', M.FFps));
    A('CPU per frame (ms)', F2(M.FCpuMs));
    A('Build display list (ms)', F2(M.FBuildMs));
    A('HUD list (ms)', F2(M.FHudMs));
    A('Raster, all threads (ms)', F2(M.FRasterMs));
    A('Present / vsync wait (ms)', F2(M.FWaitMs));
    A('— Output', '');
    A('Output', M.OutputName);
    A('Refresh rate (Hz)', IntToStr(M.FRefreshHz));
    A('Swap interval', IntToStr(M.FSwapInterval));
    A('VSync on', BoolToStr(M.FVSync, True));
    A('GL vendor', M.GLVendor);
    A('GL renderer', M.GLRenderer);
    A('GL version', M.GLVersion);
    A('Frame size', Format('%dx%d', [M.FFrame.Width, M.FFrame.Height]));
    A('Window', Format('%dx%d  %s', [M.Width, M.Height, BoolToStr(M.FFullScreen, 'fullscreen', 'windowed')]));
    A('Screen DPI', IntToStr(Screen.PixelsPerInch));
    A('— Render pool', '');
    A('Threads', IntToStr(M.FPool.ThreadCount));
    A('Band height (rows)', IntToStr(BandH));
    A('Bands per frame', IntToStr((M.FFrame.Height + BandH - 1) div BandH));
    A('Hatch texture size', Format('%d px, %d textures', [TexSize, TexCount]));
    A('HUD overlay items', IntToStr(M.FPool.OverlayCount));
    A('Text sprite cache', IntToStr(M.FTextCache.Count));
    A('Plain paper', BoolToStr(M.FPool.PlainPaper, True));
    A('— Scene', '');
    A('Display list prims', IntToStr(S.Count));
    A('Labels', IntToStr(S.LabelCount));
    A('Scene time (s)', F2(S.Time));
    A('Reveal time (s)', F2(S.RevealTime));
    A('Yaw / pitch (rad)', F2(S.Yaw) + ' / ' + F2(S.Pitch));
    A('Distance', F2(S.Distance));
    A('Auto orbit', BoolToStr(S.AutoOrbit, True));
    A('Idle time (s)', F2(S.IdleTime));
    A('Explode on / value / velocity', Format('%s / %s / %s', [BoolToStr(S.ExplodeOn, True), F2(S.Explode), F2(S.ExplodeVel)]));
    A('X-ray', BoolToStr(S.Wire, True));
    A('Labels on', BoolToStr(S.ShowLabels, True));
    A('— Camera model', '');
    A('Shutter', ShutterNames[S.ShutterIdx]);
    A('Aperture', 'f/' + FormatFloat('0.#', FStops[S.ApertureIdx]) + '  (iris ' + F2(S.Aperture) + ')');
    A('ISO', IntToStr(IsoValues[S.IsoIdx]));
    A('Focal length', IntToStr(S.FocalMm) + ' mm  (zoom ' + F2(S.Zoom) + ' -> ' + F2(S.ZoomTarget) + ')');
    A('Focus ring angle', F2(S.Focus) + ' -> ' + F2(S.FocusTarget));
    A('Shots', IntToStr(S.Shots));
    A('Shutter sequence t (s)', F2(S.ShotT));
    A('Flash', F2(S.Flash));
    A('— Layers', '');
    for i := 0 to KindCount - 1 do
      A(KindNames[i], Format('%s, %d prims', [BoolToStr(S.LayerOn[i], 'on', 'off'), S.KindStats[i].Prims]));
    A('— Audio', '');
    A('Enabled / volume', BoolToStr(M.Audio.Enabled, True) + ' / ' + F2(M.Audio.Volume));
    A('Last sound', M.Audio.LastSound);
    A('— Process', '');
    A('Executable', ParamStr(0));
    A('Export folder', ExportDir);
    A('Log lines', IntToStr(LogCount));
    Result := L.Text;
  finally
    L.Free;
  end;
end;

procedure TDevForm.RefreshDetails;
var
  L: TStringList;
  i: integer;
  It: TListItem;
begin
  L := TStringList.Create;
  try
    L.Text := DetailsText;
    FDetails.Items.BeginUpdate;
    try
      while FDetails.Items.Count > L.Count do FDetails.Items.Delete(FDetails.Items.Count - 1);
      for i := 0 to L.Count - 1 do
      begin
        if i < FDetails.Items.Count then It := FDetails.Items[i]
        else
        begin
          It := FDetails.Items.Add;
          It.SubItems.Add('');
        end;
        if It.Caption <> L.Names[i] then It.Caption := L.Names[i];
        if It.SubItems[0] <> L.ValueFromIndex[i] then It.SubItems[0] := L.ValueFromIndex[i];
      end;
    finally
      FDetails.Items.EndUpdate;
    end;
  finally
    L.Free;
  end;
end;

procedure TDevForm.CopyDetails(Sender: TObject);
begin
  Clipboard.AsText := StringReplace(DetailsText, '=', #9, [rfReplaceAll]);
  Log('dev', 'details copied to the clipboard');
end;

{ ------------------------------------------------------------ claude }

procedure TDevForm.BuildClaude;
var
  T: TTabSheet;
  L: TLabel;
begin
  T := NewTab('Claude');
  L := AddLabel(T, 'Describe what you see or want changed. The report adds the exact program state so Claude can ' +
    'reproduce it (including a --shot command for the same view). Copy it, or save it and tell Claude the file path.', 8, 6);
  L.WordWrap := True;
  L.AutoSize := False;
  L.SetBounds(8, 6, 720, 36);
  L.Anchors := [akLeft, akTop, akRight];
  AddLabel(T, 'Your message to Claude:', 8, 46);
  FMsg := TMemo.Create(Self);
  FMsg.Parent := T;
  FMsg.SetBounds(8, 64, 720, 90);
  FMsg.Anchors := [akLeft, akTop, akRight];
  FMsg.ScrollBars := ssAutoVertical;
  FIncState := AddCheck(T, 'Program state', 8, 162, True);
  FIncObjects := AddCheck(T, 'Object list', 130, 162, True);
  FIncPhysics := AddCheck(T, 'Physics values', 240, 162, False);
  FIncLog := AddCheck(T, 'Last 30 log lines', 370, 162, True);
  FIncShot := AddCheck(T, 'Screenshot (when saving)', 510, 162, True);
  AddButton(T, 'Preview', 8, 190, 90, @ReportPreview);
  AddButton(T, 'Copy to clipboard', 104, 190, 130, @ReportCopy);
  AddButton(T, 'Save report + screenshot', 240, 190, 170, @ReportSave);
  FReportPath := AddLabel(T, '', 420, 196);
  FPreview := TMemo.Create(Self);
  FPreview.Parent := T;
  FPreview.SetBounds(8, 224, 720, 330);
  FPreview.Anchors := [akLeft, akTop, akRight, akBottom];
  FPreview.ReadOnly := True;
  FPreview.ScrollBars := ssBoth;
  FPreview.WordWrap := False;
  FPreview.Font.Name := Mono;
end;

function TDevForm.BuildReport(const ShotFile: string): string;
var
  R: TStringList;
begin
  R := TStringList.Create;
  try
    R.Add('# LZ-1 Camera Sketch - developer report');
    R.Add('');
    R.Add('Date: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    R.Add('Project: ' + ExtractFilePath(ParamStr(0)));
    R.Add('');
    R.Add('## Message');
    R.Add('');
    if Trim(FMsg.Text) = '' then R.Add('(no message)') else R.Add(Trim(FMsg.Text));
    R.Add('');
    R.Add('## Reproduce this view');
    R.Add('');
    R.Add('```');
    R.Add(M.ReproCommand);
    R.Add('```');
    if ShotFile <> '' then
    begin
      R.Add('');
      R.Add('Screenshot: ' + ShotFile);
    end;
    if M.HoverObj >= 0 then
    begin
      R.Add('');
      R.Add('Object under the mouse in the object list: ' + IntToStr(M.HoverObj));
    end;
    if FIncState.Checked then
    begin
      R.Add('');
      R.Add('## Program state');
      R.Add('');
      R.Add('```');
      R.Add(StringReplace(DetailsText, '=', ': ', [rfReplaceAll]));
      R.Add('```');
    end;
    if FIncObjects.Checked then
    begin
      R.Add('');
      R.Add('## Objects');
      R.Add('');
      R.Add('```');
      R.Add(ObjectsText(False));
      R.Add('```');
    end;
    if FIncPhysics.Checked then
    begin
      R.Add('');
      R.Add('## Physics');
      R.Add('');
      R.Add('```');
      R.Add(PhysicsText);
      R.Add('```');
    end;
    if FIncLog.Checked then
    begin
      R.Add('');
      R.Add('## Log (last 30 lines)');
      R.Add('');
      R.Add('```');
      R.Add(TrimRight(LogTail(30)));
      R.Add('```');
    end;
    Result := R.Text;
  finally
    R.Free;
  end;
end;

procedure TDevForm.ReportPreview(Sender: TObject);
begin
  RefreshObjects;
  FPreview.Text := BuildReport('');
end;

procedure TDevForm.ReportCopy(Sender: TObject);
begin
  RefreshObjects;
  FPreview.Text := BuildReport('');
  Clipboard.AsText := FPreview.Text;
  FReportPath.Caption := 'Copied - paste it into the Claude chat.';
  Log('dev', 'report copied to the clipboard');
end;

procedure TDevForm.ReportSave(Sender: TObject);
var
  Dir, Base, Shot: string;
begin
  RefreshObjects;
  Dir := ExtractFilePath(ParamStr(0)) + 'reports' + PathDelim;
  ForceDirectories(Dir);
  Base := Dir + 'report_' + FormatDateTime('yyyymmdd_hhnnss', Now);
  Shot := '';
  if FIncShot.Checked then
  begin
    Shot := Base + '.png';
    M.FFrame.SaveToFile(Shot);
  end;
  FPreview.Text := BuildReport(Shot);
  FPreview.Lines.SaveToFile(Base + '.md');
  FReportPath.Caption := Base + '.md';
  Clipboard.AsText := 'Please read ' + Base + '.md' + SIf(Shot <> '', ' and ' + Shot, '');
  Log('dev', 'report saved: ' + Base + '.md (a pointer to it is on the clipboard)');
end;

{ ------------------------------------------------------------ export }

procedure TDevForm.BuildExport;
var
  T: TTabSheet;
  G: TGroupBox;
begin
  T := NewTab('Export');
  G := TGroupBox.Create(Self);
  G.Parent := T;
  G.Caption := ' Still image ';
  G.SetBounds(8, 8, 720, 96);
  AddLabel(G, 'Format', 10, 10);
  FStillFmt := AddCombo(G, 10, 28, 90, ['PNG', 'BMP'], 0);
  AddLabel(G, 'Resolution', 115, 10);
  FStillScale := AddCombo(G, 115, 28, 120, ['1x (window)', '2x'], 0);
  FStillHud := AddCheck(G, 'Include HUD', 250, 30, True);
  AddButton(G, 'Save still', 380, 26, 110, @StillSave);
  AddButton(G, 'Open export folder', 500, 26, 150, @OpenExportDir);

  G := TGroupBox.Create(Self);
  G.Parent := T;
  G.Caption := ' Animation ';
  G.SetBounds(8, 112, 720, 210);
  AddLabel(G, 'Format', 10, 10);
  FAnimFmt := AddCombo(G, 10, 28, 90, ['GIF', 'MP4'], 0);
  AddLabel(G, 'Seconds', 115, 10);
  FAnimSecs := TSpinEdit.Create(Self);
  FAnimSecs.Parent := G;
  FAnimSecs.SetBounds(115, 28, 70, 24);
  FAnimSecs.MinValue := 1;
  FAnimSecs.MaxValue := 60;
  FAnimSecs.Value := 4;
  AddLabel(G, 'Frames/s', 200, 10);
  FAnimFps := AddCombo(G, 200, 28, 80, ['10', '15', '20', '25', '30', '60'], 2);
  AddLabel(G, 'Size', 295, 10);
  FAnimScale := AddCombo(G, 295, 28, 90, ['50%', '75%', '100%'], 0);
  FAnimHud := AddCheck(G, 'Include HUD', 400, 30, False);
  FRecButton := AddButton(G, 'Record', 520, 26, 120, @RecordClick);
  AddLabel(G, 'ffmpeg (for MP4):', 10, 70);
  FFfmpeg := TEdit.Create(Self);
  FFfmpeg.Parent := G;
  FFfmpeg.SetBounds(120, 66, 440, 24);
  AddButton(G, 'Browse...', 568, 64, 90, @FfmpegBrowse);
  FFfmpegInfo := AddLabel(G, '', 10, 98);
  with AddLabel(G, 'GIF: frames stay in memory while recording and are encoded in the background afterwards. ' +
    'MP4: frames go straight to ffmpeg; without ffmpeg a PNG sequence and make_mp4.bat are saved instead.', 10, 122) do
  begin
    WordWrap := True;
    AutoSize := False;
    SetBounds(10, 122, 690, 40);
  end;
  FExportStatus := AddLabel(T, '', 12, 334);
  FExportStatus.Font.Style := [fsBold];
end;

procedure TDevForm.RefreshExport;
var
  Exe: string;
begin
  Exe := FindFfmpeg(Trim(FFfmpeg.Text));
  if Exe <> '' then
    FFfmpegInfo.Caption := 'ffmpeg found: ' + Exe
  else
    FFfmpegInfo.Caption := 'ffmpeg not found (PATH, program folder, C:\ffmpeg\bin): MP4 falls back to a PNG sequence';
  if M.Recording then
  begin
    FRecButton.Caption := 'Stop';
    FExportStatus.Caption := M.RecordStatus;
  end
  else
  begin
    FRecButton.Caption := 'Record';
    FRecButton.Enabled := not ExportBusy;
    if ExportBusy then FExportStatus.Caption := 'Encoding in the background...'
    else FExportStatus.Caption := ExportStatus;
  end;
end;

procedure TDevForm.StillSave(Sender: TObject);
var
  Ext: string;
begin
  if FStillFmt.ItemIndex = 1 then Ext := '.bmp' else Ext := '.png';
  M.RequestStill(TimeStampName('still_', Ext), FStillScale.ItemIndex + 1, FStillHud.Checked);
end;

procedure TDevForm.RecordClick(Sender: TObject);
const
  Scales: array[0..2] of single = (0.5, 0.75, 1);
begin
  if M.Recording then
    M.StopRecording
  else
    M.StartRecording(FAnimFmt.ItemIndex = 1, FAnimSecs.Value, StrToInt(FAnimFps.Text),
      Scales[FAnimScale.ItemIndex], FAnimHud.Checked, Trim(FFfmpeg.Text));
end;

procedure TDevForm.FfmpegBrowse(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'ffmpeg.exe|ffmpeg.exe|Programs|*.exe';
    if D.Execute then FFfmpeg.Text := D.FileName;
  finally
    D.Free;
  end;
end;

procedure TDevForm.OpenExportDir(Sender: TObject);
begin
  OpenDocument(ExportDir);
end;

{ ------------------------------------------------------------ layers }

procedure TDevForm.BuildLayers;
var
  T: TTabSheet;
  i: integer;
  It: TListItem;
begin
  T := NewTab('Layers');
  FLayers := TListView.Create(Self);
  FLayers.Parent := T;
  FLayers.Align := alClient;
  FLayers.ViewStyle := vsReport;
  FLayers.Checkboxes := True;
  FLayers.ReadOnly := True;
  FLayers.RowSelect := True;
  with FLayers.Columns.Add do begin Caption := 'Layer'; Width := 220; end;
  with FLayers.Columns.Add do begin Caption := 'Prims / items'; Width := 110; end;
  with FLayers.Columns.Add do begin Caption := 'Screen bounds'; Width := 200; end;
  with FLayers.Columns.Add do begin Caption := 'Drawn by'; Width := 160; end;
  FLayerSync := True;
  It := FLayers.Items.Add;
  It.Caption := 'Paper texture';
  It.SubItems.AddStrings(['-', 'full frame', 'render threads']);
  for i := 0 to KindCount - 1 do
  begin
    It := FLayers.Items.Add;
    It.Caption := KindNames[i];
    It.SubItems.AddStrings(['', '', SIf(i = okMarking, 'main thread (labels)', 'render threads')]);
  end;
  It := FLayers.Items.Add;
  It.Caption := 'HUD (title, readout, buttons, title block)';
  It.SubItems.AddStrings(['', 'frame', 'render threads (overlay)']);
  It := FLayers.Items.Add;
  It.Caption := 'Camera flash effect';
  It.SubItems.AddStrings(['-', 'full frame', 'render threads']);
  It := FLayers.Items.Add;
  It.Caption := 'X-ray (wireframe instead of shading)';
  It.SubItems.AddStrings(['-', '-', 'scene build']);
  for i := 0 to FLayers.Items.Count - 1 do FLayers.Items[i].Checked := i <> FLayers.Items.Count - 1;
  FLayerSync := False;
  FLayers.OnItemChecked := @LayerChecked;
end;

procedure TDevForm.LayerChecked(Sender: TObject; Item: TListItem);
var
  i: integer;
begin
  if FLayerSync then Exit;
  i := Item.Index;
  if i = 0 then M.FPool.PlainPaper := not Item.Checked
  else if i <= KindCount then M.FScene.LayerOn[i - 1] := Item.Checked
  else if i = KindCount + 1 then M.ShowHud := Item.Checked
  else if i = KindCount + 2 then M.ShowFlash := Item.Checked
  else M.FScene.Wire := Item.Checked;
  Log('layers', Item.Caption + ': ' + BoolToStr(Item.Checked, 'on', 'off'));
end;

procedure TDevForm.RefreshLayers;
var
  i: integer;
begin
  FLayerSync := True;
  try
    for i := 0 to KindCount - 1 do
    begin
      FLayers.Items[i + 1].SubItems[0] := IntToStr(M.FScene.KindStats[i].Prims);
      FLayers.Items[i + 1].SubItems[1] := BoxText(M.FScene.KindStats[i].Box);
      if FLayers.Items[i + 1].Checked <> M.FScene.LayerOn[i] then
        FLayers.Items[i + 1].Checked := M.FScene.LayerOn[i];
    end;
    FLayers.Items[okMarking + 1].SubItems[0] := IntToStr(M.FScene.LabelCount) + ' labels';
    FLayers.Items[KindCount + 1].SubItems[0] := IntToStr(M.FPool.OverlayCount);
    // X-ray can also be switched with W in the main window
    if FLayers.Items[KindCount + 3].Checked <> M.FScene.Wire then
      FLayers.Items[KindCount + 3].Checked := M.FScene.Wire;
  finally
    FLayerSync := False;
  end;
end;

{ ------------------------------------------------------------ objects }

procedure TDevForm.BuildObjects;
var
  T: TTabSheet;
  P: TPanel;
  Pop: TPopupMenu;
  Mi: TMenuItem;
  i: integer;
  It: TListItem;
  Cols: array[0..9] of string = ('#', 'Object', 'Type', 'Prims', 'Screen box (x,y  w x h)', 'Depth min-max',
    'Reveal', 'Explode offset', 'Anchor hidden', 'Draw bias');
  Widths: array[0..9] of integer = (36, 170, 80, 50, 160, 110, 55, 120, 90, 70);
begin
  T := NewTab('Objects');
  P := TPanel.Create(Self);
  P.Parent := T;
  P.Align := alTop;
  P.Height := 36;
  P.BevelOuter := bvNone;
  AddButton(P, 'Copy all as text', 6, 4, 130, @ObjCopyAll);
  AddButton(P, 'Copy selected', 142, 4, 110, @ObjCopyRow);
  AddLabel(P, 'Point at a row: the object gets a dashed box in the main window.', 262, 10);
  FObjects := TListView.Create(Self);
  FObjects.Parent := T;
  FObjects.Align := alClient;
  FObjects.ViewStyle := vsReport;
  FObjects.ReadOnly := True;
  FObjects.RowSelect := True;
  FObjects.MultiSelect := True;
  FObjects.Font.Name := Mono;
  FObjects.OnMouseMove := @ObjMouseMove;
  FObjects.OnMouseLeave := @ObjMouseLeave;
  FObjects.OnKeyDown := @ObjKeyDown;
  for i := 0 to High(Cols) do
    with FObjects.Columns.Add do
    begin
      Caption := Cols[i];
      Width := Widths[i];
    end;
  Pop := TPopupMenu.Create(Self);
  Mi := TMenuItem.Create(Pop);
  Mi.Caption := 'Copy row(s)';
  Mi.OnClick := @ObjCopyRow;
  Pop.Items.Add(Mi);
  Mi := TMenuItem.Create(Pop);
  Mi.Caption := 'Copy all as text';
  Mi.OnClick := @ObjCopyAll;
  Pop.Items.Add(Mi);
  FObjects.PopupMenu := Pop;
  // parts, then the annotation layers (the model layer is the parts themselves)
  for i := 0 to High(M.FScene.Parts) do
  begin
    SetLength(FObjCode, Length(FObjCode) + 1);
    FObjCode[High(FObjCode)] := i;
  end;
  for i := 0 to KindCount - 1 do
    if not (i in [okModel, okMarking]) then
    begin
      SetLength(FObjCode, Length(FObjCode) + 1);
      FObjCode[High(FObjCode)] := 100 + i;
    end;
  for i := 0 to High(FObjCode) do
  begin
    It := FObjects.Items.Add;
    It.SubItems.AddStrings(['', '', '', '', '', '', '', '', '']);
  end;
end;

procedure TDevForm.RefreshObjects;
var
  i, c: integer;
  St: TObjStat;
  It: TListItem;
  V: array[0..9] of string;
  Pi_: TPartInfo;
begin
  FObjects.Items.BeginUpdate;
  try
    for i := 0 to High(FObjCode) do
    begin
      c := FObjCode[i];
      if c < 100 then
      begin
        St := M.FScene.PartStats[c];
        Pi_ := M.FScene.Parts[c];
        V[0] := IntToStr(c + 1);
        V[1] := Pi_.Name;
        V[2] := 'part';
        V[7] := Format('%.1f,%.1f,%.1f', [Pi_.Offset.X * M.FScene.Spread, Pi_.Offset.Y * M.FScene.Spread,
          Pi_.Offset.Z * M.FScene.Spread]);
        V[8] := BoolToStr(St.Occluded, 'yes', 'no');
        V[9] := F2(Pi_.Bias);
      end
      else
      begin
        St := M.FScene.KindStats[c - 100];
        V[0] := 'L' + IntToStr(c - 100);
        V[1] := KindNames[c - 100];
        V[2] := 'layer';
        V[7] := '-';
        V[8] := '-';
        V[9] := '-';
      end;
      V[3] := IntToStr(St.Prims);
      V[4] := BoxText(St.Box);
      if St.DMax >= St.DMin then V[5] := F2(St.DMin) + ' - ' + F2(St.DMax) else V[5] := '-';
      V[6] := F2(St.Reveal);
      It := FObjects.Items[i];
      if It.Caption <> V[0] then It.Caption := V[0];
      for c := 1 to 9 do
        if It.SubItems[c - 1] <> V[c] then It.SubItems[c - 1] := V[c];
    end;
  finally
    FObjects.Items.EndUpdate;
  end;
end;

function TDevForm.ObjectsText(OnlySelected: boolean): string;
var
  i, c: integer;
  S: string;
begin
  S := '';
  for c := 0 to FObjects.Columns.Count - 1 do
    S := S + SIf(c > 0, #9, '') + FObjects.Columns[c].Caption;
  Result := S + LineEnding;
  for i := 0 to FObjects.Items.Count - 1 do
    if not OnlySelected or FObjects.Items[i].Selected then
    begin
      S := FObjects.Items[i].Caption;
      for c := 0 to FObjects.Items[i].SubItems.Count - 1 do S := S + #9 + FObjects.Items[i].SubItems[c];
      Result := Result + S + LineEnding;
    end;
end;

procedure TDevForm.ObjMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
var
  It: TListItem;
begin
  It := FObjects.GetItemAt(X, Y);
  if It = nil then M.HoverObj := -1 else M.HoverObj := FObjCode[It.Index];
end;

procedure TDevForm.ObjMouseLeave(Sender: TObject);
begin
  M.HoverObj := -1;
end;

procedure TDevForm.ObjKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_C) and (ssCtrl in Shift) then
  begin
    ObjCopyRow(Sender);
    Key := 0;
  end;
end;

procedure TDevForm.ObjCopyRow(Sender: TObject);
begin
  RefreshObjects;
  Clipboard.AsText := ObjectsText(True);
  Log('dev', 'object rows copied');
end;

procedure TDevForm.ObjCopyAll(Sender: TObject);
begin
  RefreshObjects;
  Clipboard.AsText := ObjectsText(False);
  Log('dev', 'object list copied');
end;

{ ------------------------------------------------------------ physics }

procedure TDevForm.BuildPhysics;
var
  T: TTabSheet;
  S: TCameraScene;
  y: integer;

  procedure Row(const ACaption, AHint: string; P: PSingle; AMin, AMax, ADef: single);
  var
    R: TPhysRow;
  begin
    R.Name := ACaption;
    R.Value := P;
    R.Min := AMin;
    R.Max := AMax;
    R.Def := ADef;
    with AddLabel(T, ACaption, 10, y + 4) do Hint := AHint;
    R.Track := TTrackBar.Create(Self);
    R.Track.Parent := T;
    R.Track.SetBounds(190, y, 330, 28);
    R.Track.Min := 0;
    R.Track.Max := 1000;
    R.Track.TickStyle := tsNone;
    R.Track.Hint := AHint;
    R.Track.ShowHint := True;
    R.Track.Tag := Length(FPhys);
    R.Track.OnChange := @PhysChange;
    R.Lbl := AddLabel(T, '', 530, y + 4);
    SetLength(FPhys, Length(FPhys) + 1);
    FPhys[High(FPhys)] := R;
    Inc(y, 30);
  end;

begin
  T := NewTab('Physics');
  T.ShowHint := True;
  S := M.FScene;
  y := 8;
  FPhysSync := True;
  Row('Time scale', 'Slow motion < 1 < fast forward, for every animation', @S.TimeScale, 0.05, 3, 1);
  Row('Explode spring stiffness', 'Higher: parts fly out faster', @S.ExplodeK, 5, 250, 70);
  Row('Explode spring damping', 'Lower: more overshoot and bounce', @S.ExplodeC, 0.5, 40, 11);
  Row('Explode spread', 'How far the parts move apart', @S.Spread, 0.2, 1.6, 0.72);
  Row('Orbit friction', 'How fast a flicked orbit slows down', @S.OrbitDamp, 0.2, 12, 3.5);
  Row('Auto orbit speed (rad/s)', 'Turning speed when left alone', @S.AutoSpeed, 0, 1.2, 0.16);
  Row('Auto orbit delay (s)', 'Idle time before the auto orbit starts', @S.AutoDelay, 0, 10, 2.5);
  Row('Zoom response', 'How fast the lens follows the wheel', @S.ZoomRate, 0.5, 30, 7);
  Row('Focus response', 'How fast the focus ring turns', @S.FocusRate, 0.5, 30, 9);
  Row('Dial response', 'How fast the dials turn to a new value', @S.DialRate, 0.5, 30, 10);
  Row('Flash decay', 'How fast the flash fades', @S.FlashDecay, 0.5, 30, 7);
  FPhysSync := False;
  AddButton(T, 'Reset all', 10, y + 4, 100, @PhysReset);
  AddButton(T, 'Fire shutter', 116, y + 4, 100, @PhysShutter);
  AddButton(T, 'Toggle explode', 222, y + 4, 110, @PhysExplode);
  FPhysLive := TMemo.Create(Self);
  FPhysLive.Parent := T;
  FPhysLive.SetBounds(10, y + 40, 718, 150);
  FPhysLive.Anchors := [akLeft, akTop, akRight, akBottom];
  FPhysLive.ReadOnly := True;
  FPhysLive.Font.Name := Mono;
end;

procedure TDevForm.PhysChange(Sender: TObject);
var
  R: TPhysRow;
begin
  if FPhysSync then Exit;
  R := FPhys[(Sender as TTrackBar).Tag];
  R.Value^ := R.Min + (R.Max - R.Min) * R.Track.Position / 1000;
  R.Lbl.Caption := FormatFloat('0.000', R.Value^);
end;

procedure TDevForm.PhysReset(Sender: TObject);
begin
  M.FScene.ResetPhysics;
  Log('physics', 'parameters reset to defaults');
end;

procedure TDevForm.PhysShutter(Sender: TObject);
begin
  M.FScene.FireShutter;
end;

procedure TDevForm.PhysExplode(Sender: TObject);
begin
  M.PressButton(bExplode);
end;

function TDevForm.PhysicsText: string;
var
  i: integer;
begin
  Result := '';
  for i := 0 to High(FPhys) do
    Result := Result + Format('%-28s %8.3f   (default %.3f)', [FPhys[i].Name, FPhys[i].Value^, FPhys[i].Def]) +
      LineEnding;
end;

procedure TDevForm.RefreshPhysicsLive;
var
  S: TCameraScene;
  i: integer;
begin
  S := M.FScene;
  // follow values changed elsewhere (reset, presets)
  FPhysSync := True;
  try
    for i := 0 to High(FPhys) do
    begin
      FPhys[i].Track.Position := Round((FPhys[i].Value^ - FPhys[i].Min) / (FPhys[i].Max - FPhys[i].Min) * 1000);
      FPhys[i].Lbl.Caption := FormatFloat('0.000', FPhys[i].Value^) + '   (default ' + FormatFloat('0.###', FPhys[i].Def) + ')';
    end;
  finally
    FPhysSync := False;
  end;
  FPhysLive.Lines.BeginUpdate;
  try
    FPhysLive.Lines.Clear;
    FPhysLive.Lines.Add(Format('explode   x=%7.3f  v=%7.3f  target=%d', [S.Explode, S.ExplodeVel, Ord(S.ExplodeOn)]));
    FPhysLive.Lines.Add(Format('orbit     yaw=%7.3f  pitch=%6.3f  vyaw=%6.3f  vpitch=%6.3f  idle=%5.1f s',
      [S.Yaw, S.Pitch, S.YawVel, S.PitchVel, S.IdleTime]));
    FPhysLive.Lines.Add(Format('lens      zoom=%5.3f -> %5.3f  focus=%6.3f -> %6.3f  iris=%5.3f',
      [S.Zoom, S.ZoomTarget, S.Focus, S.FocusTarget, S.Aperture]));
    FPhysLive.Lines.Add(Format('dials     shutter=%5.3f rad  iso=%5.3f rad', [S.ShutterDial, S.IsoDial]));
    FPhysLive.Lines.Add(Format('shutter   t=%6.3f s  button=%5.3f  flash=%5.3f  shots=%d',
      [S.ShotT, S.ButtonDown, S.Flash, S.Shots]));
    FPhysLive.Lines.Add(Format('time      scene=%8.2f s  reveal=%8.2f s', [S.Time, S.RevealTime]));
  finally
    FPhysLive.Lines.EndUpdate;
  end;
end;

{ ------------------------------------------------------------ audio }

procedure TDevForm.BuildAudio;
var
  T: TTabSheet;
  S: TSound;
  y: integer;
  C: TCheckBox;
  B: TButton;
begin
  T := NewTab('Audio');
  FAudioOn := AddCheck(T, 'Sound effects on', 10, 10, M.Audio.Enabled);
  FAudioOn.OnChange := @AudioChange;
  AddLabel(T, 'Volume', 10, 44);
  FVolume := TTrackBar.Create(Self);
  FVolume.Parent := T;
  FVolume.SetBounds(70, 38, 300, 28);
  FVolume.Max := 100;
  FVolume.Position := Round(M.Audio.Volume * 100);
  FVolume.TickStyle := tsNone;
  FVolume.OnChange := @AudioChange;
  y := 84;
  for S := Low(TSound) to High(TSound) do
  begin
    C := AddCheck(T, SoundNames[S], 10, y + 3, M.Audio.SoundOn[S]);
    C.Tag := Ord(S);
    C.OnChange := @AudioChange;
    SetLength(FSoundChecks, Length(FSoundChecks) + 1);
    FSoundChecks[High(FSoundChecks)] := C;
    B := AddButton(T, 'Test', 200, y, 60, @AudioTest);
    B.Tag := Ord(S);
    SetLength(FSoundInfo, Length(FSoundInfo) + 1);
    FSoundInfo[High(FSoundInfo)] := AddLabel(T, '', 275, y + 5);
    Inc(y, 34);
  end;
  FAudioLast := AddLabel(T, '', 10, y + 10);
  with AddLabel(T, 'All sounds are synthesised in code (16-bit mono, 44.1 kHz WAV in memory) and played with ' +
    'PlaySound: one sound at a time, a new one cuts the previous one.', 10, y + 40) do
  begin
    WordWrap := True;
    AutoSize := False;
    SetBounds(10, y + 40, 700, 40);
  end;
end;

procedure TDevForm.AudioChange(Sender: TObject);
var
  i: integer;
begin
  M.Audio.Enabled := FAudioOn.Checked;
  M.Audio.Volume := FVolume.Position / 100;
  for i := 0 to High(FSoundChecks) do M.Audio.SoundOn[TSound(i)] := FSoundChecks[i].Checked;
end;

procedure TDevForm.AudioTest(Sender: TObject);
begin
  M.Audio.Play(TSound((Sender as TButton).Tag), True);
end;

procedure TDevForm.RefreshAudio;
var
  S: TSound;
begin
  for S := Low(TSound) to High(TSound) do
    FSoundInfo[Ord(S)].Caption := Format('%d ms, %d bytes, played %d times',
      [M.Audio.DurationMs(S), M.Audio.ByteSize(S), M.Audio.PlayCount[S]]);
  FAudioLast.Caption := 'Last played: ' + M.Audio.LastSound;
end;

{ ------------------------------------------------------------ log }

procedure TDevForm.BuildLog;
var
  T: TTabSheet;
  P: TPanel;
begin
  T := NewTab('Log');
  P := TPanel.Create(Self);
  P.Parent := T;
  P.Align := alTop;
  P.Height := 36;
  P.BevelOuter := bvNone;
  AddButton(P, 'Clear', 6, 4, 70, @LogClearClick);
  AddButton(P, 'Copy all', 82, 4, 80, @LogCopyClick);
  AddButton(P, 'Save...', 168, 4, 70, @LogSaveClick);
  AddLabel(P, 'Filter', 252, 10);
  FLogFilter := TEdit.Create(Self);
  FLogFilter.Parent := P;
  FLogFilter.SetBounds(290, 6, 160, 24);
  FLogFilter.OnChange := @LogFilterChange;
  FLogPause := AddCheck(P, 'Pause', 462, 8, False);
  FLogScroll := AddCheck(P, 'Auto-scroll', 530, 8, True);
  FLog := TMemo.Create(Self);
  FLog.Parent := T;
  FLog.Align := alClient;
  FLog.ReadOnly := True;
  FLog.ScrollBars := ssBoth;
  FLog.WordWrap := False;
  FLog.Font.Name := Mono;
end;

procedure TDevForm.RefreshLog(Rebuild: boolean);
var
  L: TStringList;
  i: integer;
  F: string;
begin
  if FLogPause.Checked and not Rebuild then Exit;
  L := TStringList.Create;
  try
    if Rebuild then
    begin
      FLog.Lines.Clear;
      FLogSeen := 0;
    end;
    FLogSeen := LogFetch(FLogSeen, L);
    if L.Count = 0 then Exit;
    F := LowerCase(Trim(FLogFilter.Text));
    FLog.Lines.BeginUpdate;
    try
      for i := 0 to L.Count - 1 do
        if (F = '') or (Pos(F, LowerCase(L[i])) > 0) then FLog.Lines.Add(L[i]);
      while FLog.Lines.Count > 3000 do FLog.Lines.Delete(0);
    finally
      FLog.Lines.EndUpdate;
    end;
    if FLogScroll.Checked then
    begin
      FLog.SelStart := Length(FLog.Text);
      FLog.SelLength := 0;
    end;
  finally
    L.Free;
  end;
end;

procedure TDevForm.LogClearClick(Sender: TObject);
begin
  LogClear;
  FLog.Lines.Clear;
end;

procedure TDevForm.LogCopyClick(Sender: TObject);
begin
  Clipboard.AsText := FLog.Text;
end;

procedure TDevForm.LogSaveClick(Sender: TObject);
var
  D: TSaveDialog;
begin
  D := TSaveDialog.Create(Self);
  try
    D.FileName := 'camerasketch_log.txt';
    D.Filter := 'Text|*.txt';
    if D.Execute then FLog.Lines.SaveToFile(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TDevForm.LogFilterChange(Sender: TObject);
begin
  RefreshLog(True);
end;

// Self-test (--devtest): a screenshot of every tab.
// Self-test: labels and track bars do not show in form images, so list them
procedure TDevForm.DumpControls(P: TWinControl);
var
  i: integer;
  C: TControl;
begin
  for i := 0 to P.ControlCount - 1 do
  begin
    C := P.Controls[i];
    if (C is TLabel) or (C is TTrackBar) then
      LogFmt('ui', '%s / %s "%s" visible=%s %dx%d at %d,%d', [FPages.ActivePage.Caption, C.ClassName,
        Copy(C.Caption, 1, 40), BoolToStr(C.IsVisible, True), C.Width, C.Height, C.Left, C.Top]);
    if C is TWinControl then DumpControls(TWinControl(C));
  end;
end;

procedure TDevForm.SaveTabShots(const Dir: string);
var
  i: integer;
  Bmp: TBitmap;
  Pt: TPoint;
begin
  for i := 0 to FPages.PageCount - 1 do
  begin
    FPages.ActivePageIndex := i;
    RefreshDetails;
    RefreshLayers;
    RefreshObjects;
    RefreshPhysicsLive;
    RefreshAudio;
    RefreshExport;
    RefreshLog(False);
    BringToFront;
    Application.ProcessMessages;
    Repaint;
    FOverview.Repaint;
    Application.ProcessMessages;
    Sleep(150);
    // the form image leaves out custom painting: draw the overview into it
    Bmp := GetFormImage;
    if FPages.ActivePage = FOverview.Parent then
    begin
      Pt := FOverview.ClientToParent(Point(0, 0), Self);
      PaintOverview(Bmp.Canvas, Pt.X, Pt.Y);
    end;
    DumpControls(FPages.ActivePage);
    try
      Bmp.SaveToFile(Dir + Format('tab%d_%s.bmp', [i, FPages.Pages[i].Caption]));
    finally
      Bmp.Free;
    end;
  end;
end;

{ ------------------------------------------------------------ timer }

procedure TDevForm.TimerTick(Sender: TObject);
var
  Tab: string;
  T0: QWord;
begin
  if not Visible then Exit;
  Inc(FTick);
  Tab := FPages.ActivePage.Caption;
  T0 := GetTickCount64;
  try
    UpdateTab(Tab);
  finally
    if GetTickCount64 - T0 > 20 then      // GetTickCount64 steps by ~16 ms
      LogFmt('dev', '%s tab refresh took %d ms', [Tab, GetTickCount64 - T0]);
  end;
end;

procedure TDevForm.UpdateTab(const Tab: string);
begin
  RefreshLog(False);                  // always, so no line is missed
  if Tab = 'Overview' then
  begin
    if FTick mod 2 = 0 then FOverview.Repaint;
  end
  else if FTick mod 3 <> 0 then Exit  // the lists refresh about 3 times a second
  else if Tab = 'Details' then RefreshDetails
  else if Tab = 'Layers' then RefreshLayers
  else if Tab = 'Objects' then RefreshObjects
  else if Tab = 'Physics' then RefreshPhysicsLive
  else if Tab = 'Audio' then RefreshAudio
  else if Tab = 'Export' then RefreshExport;
end;

end.
