unit UEditor;

{ Sketch Editor window.

  Modes (F2 / F3 / F4 or the toolbar):
    Model     select, move (G), rotate (R), scale (S) the shapes; X / Y / Z lock
              the axis; add box / cylinder / loft; duplicate (Ctrl+D), delete.
    Annotate  select and drag annotations; add a dimension (D: click two points
              on the model, corners snap), a label (L) or a numbered callout (C).
    Sketch    pencil (P), ruled line (L), ellipse (E), hatching (H: draw the
              outline, it is filled with pencil hatching), eraser (X), and
              two-point perspective guides (V: drag the vanishing points; ruled
              lines snap to them). Sketch layers live in the left panel.

  View: right drag orbits, middle drag (or Shift+right) pans, the wheel
  zooms, F frames the selection, F5-F8 front / side / top / iso, W x-ray.
  Ctrl+Z / Ctrl+Y undo and redo every change. Files are JSON.

  Rendering is the Camera Sketch engine: the document becomes a display
  list (udocscene.pas), every core rasterises a band (urenderpool.pas), and
  OpenGL shows the frame with vsync at 60 Hz. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math, Forms, Controls, Graphics, ExtCtrls, StdCtrls, ComCtrls, Buttons, Menus,
  Dialogs, Spin, LCLType, Clipbrd, GL, OpenGLContext, Contnrs,
  BGRABitmap, BGRABitmapTypes, UPrimTypes, URenderPool, UExport, ULog, UModel, UDocScene;

type
  TEditMode = (emModel, emAnnot, emSketch);
  TTool = (tSelect, tMove, tRotate, tScale, tAddDim, tAddLabel, tAddCallout,
    tPencil, tLine, tEllipse, tHatch, tEraser, tGuide);
  TAxisLock = (alFree, alX, alY, alZ);
  TDrag = (dgNone, dgOrbit, dgPan, dgTool);

  { TEditorForm }

  TEditorForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
  public
    Doc: TSketchDoc;
    Scene: TDocScene;
    Pool: TRenderPool;
    Frame, Paper: TBGRABitmap;
    FileName: string;
    Modified: boolean;
    Mode: TEditMode;
    Tool: TTool;
    Axis: TAxisLock;
    SelShape, SelAnnot: integer;
    HoverShape, HoverAnnot: integer;
    // sketch tool settings
    PenWidth, PenInk, EraserRadius, SnapGrid: single;
    RuledSketchy, SnapPersp: boolean;
    HatchLevel: integer;
    // UI
    FTopBar, FToolBar, FLeft, FRight: TPanel;
    FModeBtn: array[TEditMode] of TSpeedButton;
    FModePanel: array[TEditMode] of TPanel;
    FAxisBtns: array[TAxisLock] of TSpeedButton;
    FAddBtns: TList;
    FOutline: TListView;
    FLayerBar: TPanel;
    FProps: TScrollBox;
    FStatus: TStatusBar;
    FTimer: TTimer;
    // output
    FGL: TOpenGLControl;
    FView: TPaintBox;
    FOutput: TControl;
    FUseGL, FGLReady, FVSyncApplied, FVSyncSupported: boolean;
    FTexture: GLuint;
    FTexW, FTexH: integer;
    FRefreshHz, FSwapInterval: integer;
    FPaperW, FPaperH: integer;
    FFreq: int64;
    FFrames: integer;
    FFpsTime, FFps, FCpuMs, FSwapMs, FNextFrame: double;
    FSetInterval: function(Interval: longint): LongBool; stdcall;
    FGetInterval: function: longint; stdcall;
    // text
    FMeasure: TBGRABitmap;
    FTextCache: TStringList;
    // input state
    FDrag: TDrag;
    FDragButton: TMouseButton;
    FDownX, FDownY, FLastX, FLastY, FMouseX, FMouseY: integer;
    FBefore: string;                 // document before the current drag, for undo
    FStartPos, FStartRot, FStartScale, FStartA, FStartB, FStartOff: TVec3;
    FStartDX, FStartDY: single;
    FCurPts: array of TPointF;       // stroke being drawn
    FDimFirst: boolean;
    FDimA: TVec3;
    FDragVP: integer;
    // undo
    FUndo: TStringList;
    FUndoPos: integer;
    FCommitAt: QWord;
    // panels
    FOutlineSync, FPropSync: boolean;
    FOutlineKey: string;
    FPropsKey: string;
    // self-test
    FTestStep: integer;
    FTestT: QWord;

    function NowMs: double;
    procedure AppIdle(Sender: TObject; var Done: boolean);
    procedure DoFrame;
    procedure RenderTo(Target: TBGRABitmap; W, H: integer; Clean: boolean);
    procedure DrawLabels;
    procedure DrawOverlay;
    procedure DashedRect(const B: TRectF; C: TBGRAPixel);
    procedure PresentGL;
    procedure GLPaint(Sender: TObject);
    procedure ViewPaint(Sender: TObject);
    function OutputName: string;
    function TextSprite(const S: string; Size: integer; Bold: boolean; C: TBGRAPixel): TBGRABitmap;
    function Txt(X, Y: single; const S: string; Size: integer; Bold: boolean; C: TBGRAPixel;
      AAlign: TAlignment = taLeftJustify): single;
    // UI building
    procedure BuildMenu;
    procedure BuildBars;
    function AddSpeed(AParent: TWinControl; const ACaption, AHint: string; AGroup: integer; W: integer;
      AClick: TNotifyEvent): TSpeedButton;
    procedure LayoutToolBar;
    procedure RefreshOutliner(Force: boolean = False);
    procedure RefreshProps(Force: boolean = False);
    procedure SyncPropValues;
    procedure UpdateStatus;
    // property panel
    function PropRow(const ACaption: string; Id: integer; AKind: integer; AMin: double = 0; AMax: double = 0;
      AStep: double = 0.1; Items: string = ''): TControl;
    procedure PropHeader(const ACaption: string);
    function GetFloat(Id: integer): double;
    procedure SetFloat(Id: integer; V: double);
    function GetText(Id: integer): string;
    procedure SetText(Id: integer; const V: string);
    procedure PropChanged(Sender: TObject);
    // actions
    procedure SetMode(M: TEditMode);
    procedure SetTool(T: TTool);
    procedure SetAxis(A: TAxisLock);
    procedure ModeClick(Sender: TObject);
    procedure ToolClick(Sender: TObject);
    procedure AxisClick(Sender: TObject);
    procedure AddShapeClick(Sender: TObject);
    procedure LayerBtnClick(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure OutlineSelect(Sender: TObject; Item: TListItem; Selected: boolean);
    procedure OutlineChecked(Sender: TObject; Item: TListItem);
    procedure OutlineMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure OutlineMouseLeave(Sender: TObject);
    procedure OutlineKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NewDoc(Preset: boolean);
    procedure OpenDoc;
    procedure SaveDoc(AsNew: boolean);
    function ConfirmDiscard: boolean;
    procedure DeleteSelection;
    procedure DuplicateSelection;
    procedure FrameSelection;
    procedure SetView(AYaw, APitch: single);
    procedure ExportStill;
    procedure ExportTurntable(Mp4: boolean);
    // undo
    procedure Commit(const What: string);
    procedure ScheduleCommit;
    procedure Undo;
    procedure Redo;
    procedure RestoreState(const S: string);
    // input
    procedure VMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure VMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
    procedure VMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure VMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: integer; MousePos: TPoint;
      var Handled: boolean);
    procedure ToolDown(X, Y: integer; Shift: TShiftState);
    procedure ToolMove(X, Y: integer; Shift: TShiftState);
    procedure ToolUp(X, Y: integer; Shift: TShiftState);
    function SnapLineEnd(const A, B: TPointF): TPointF;
    procedure FinishStroke;
    procedure EraseAt(X, Y: single);
    function ActiveLayerOK: boolean;
    function EditingText: boolean;
    procedure SelfTestStep;
    procedure AppException(Sender: TObject; E: Exception);
  end;

var
  EditorForm: TEditorForm;

implementation

{$R *.lfm}

const
  // property ids
  pName = 1; pMat = 2; pVisible = 3; pPosX = 4; pPosY = 5; pPosZ = 6; pRotX = 7; pRotY = 8; pRotZ = 9;
  pScaleX = 10; pScaleY = 11; pScaleZ = 12; pBias = 13; pSizeX = 14; pSizeY = 15; pSizeZ = 16; pRadius = 17;
  pRBot = 18; pRTop = 19; pHeight = 20; pSegs = 21; pRibbed = 22; pTicks = 23; pBW = 24; pBD = 25; pTW = 26;
  pTD = 27; pShift = 28; pChamfer = 29;
  pAText = 40; pAX = 41; pAY = 42; pAZ = 43; pBX = 44; pBY = 45; pBZ = 46; pOX = 47; pOY = 48; pOZ = 49;
  pADX = 50; pADY = 51; pANum = 52; pAVis = 53;
  pTitle = 60; pPenW = 61; pInk = 62; pRuled = 63; pHatch = 64; pEraser = 65; pSnapP = 66; pGuides = 67;
  pLName = 68; pLVis = 69; pLLock = 70; pSnapGrid = 71;
  // property row kinds
  rkFloat = 0; rkInt = 1; rkText = 2; rkBool = 3; rkCombo = 4; rkInfo = 5;
  // menu ids
  mNew = 1; mPreset = 2; mOpen = 3; mSave = 4; mSaveAs = 5; mStill = 6; mGif = 7; mMp4 = 8; mExit = 9;
  mUndo = 10; mRedo = 11; mDup = 12; mDel = 13; mNone = 14;
  mFront = 20; mSide = 21; mTop = 22; mIso = 23; mFrame = 24; mWire = 25; mGrid = 26; mModelInSketch = 27;
  mKeys = 30;

  ToolNames: array[TTool] of string = ('Select', 'Move', 'Rotate', 'Scale', 'Dimension', 'Label',
    'Callout', 'Pencil', 'Line', 'Ellipse', 'Hatch', 'Eraser', 'Perspective');
  ToolKeys: array[TTool] of string = ('Q', 'G', 'R', 'S', 'D', 'L', 'C', 'P', 'L', 'E', 'H', 'X', 'V');
  ToolHints: array[TTool] of string = ('Click to select', 'Drag the selected shape (X/Y/Z lock an axis)',
    'Drag left/right to rotate (Shift: 15 degree steps)', 'Drag up/down to scale (X/Y/Z: one axis)',
    'Click two points on the model', 'Click a point on the model', 'Click a point on the model',
    'Freehand pencil', 'Ruled line (snaps to the perspective guides)', 'Drag a box (Shift: circle)',
    'Draw an outline: it is filled with hatching', 'Rub out strokes on the active layer',
    'Drag the vanishing points');
  ModeTools: array[TEditMode] of set of TTool = ([tSelect, tMove, tRotate, tScale],
    [tSelect, tAddDim, tAddLabel, tAddCallout], [tPencil, tLine, tEllipse, tHatch, tEraser, tGuide]);

  Ink: TBGRAPixel = (blue: 40; green: 34; red: 34; alpha: 230);
  SelC: TBGRAPixel = (blue: 210; green: 90; red: 30; alpha: 235);
  HoverC: TBGRAPixel = (blue: 200; green: 120; red: 90; alpha: 170);

function PtDist(const A, B: TPointF): single; inline;
begin
  Result := Sqrt(Sqr(A.X - B.X) + Sqr(A.Y - B.Y));
end;

{ TEditorForm }

procedure TEditorForm.FormCreate(Sender: TObject);
{$IFDEF WINDOWS}
var
  DC: HDC;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  QueryPerformanceFrequency(FFreq);
  {$ENDIF}
  Caption := 'LZ Sketch Editor';
  KeyPreview := True;
  Doc := TSketchDoc.Create;
  Scene := TDocScene.Create;
  Pool := TRenderPool.Create(0);
  Frame := TBGRABitmap.Create(16, 16);
  Paper := TBGRABitmap.Create(16, 16);
  FMeasure := TBGRABitmap.Create(4, 4);
  FMeasure.FontName := 'Bahnschrift';
  FMeasure.FontQuality := fqFineAntialiasing;
  FTextCache := TStringList.Create;
  FTextCache.Sorted := True;
  FTextCache.CaseSensitive := True;
  FTextCache.OwnsObjects := True;
  FUndo := TStringList.Create;
  FAddBtns := TList.Create;
  SelShape := -1;
  SelAnnot := -1;
  HoverShape := -1;
  HoverAnnot := -1;
  PenWidth := 1.3;
  PenInk := 0.85;
  EraserRadius := 12;
  SnapGrid := 0.1;
  RuledSketchy := True;
  SnapPersp := True;
  HatchLevel := 1;
  FDragVP := -1;

  BuildMenu;
  BuildBars;

  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.Visible := False;
  FView.OnPaint := @ViewPaint;
  FOutput := FView;
  FUseGL := True;
  try
    FGL := TOpenGLControl.Create(Self);
    FGL.Parent := Self;
    FGL.Align := alClient;
    FGL.AutoResizeViewport := False;
    FGL.DepthBits := 0;
    FGL.DoubleBuffered := True;       // SwapBuffers then waits for the vertical blank
    FGL.OnPaint := @GLPaint;
    FOutput := FGL;
  except
    on E: Exception do
    begin
      FUseGL := False;
      FView.Visible := True;
    end;
  end;
  if FOutput = FGL then
  begin
    FGL.OnMouseDown := @VMouseDown;
    FGL.OnMouseMove := @VMouseMove;
    FGL.OnMouseUp := @VMouseUp;
    FGL.OnMouseWheel := @VMouseWheel;
  end;
  FView.OnMouseDown := @VMouseDown;
  FView.OnMouseMove := @VMouseMove;
  FView.OnMouseUp := @VMouseUp;
  FView.OnMouseWheel := @VMouseWheel;

  FRefreshHz := 60;
  {$IFDEF WINDOWS}
  DC := GetDC(0);
  FRefreshHz := GetDeviceCaps(DC, VREFRESH);
  ReleaseDC(0, DC);
  if FRefreshHz <= 1 then FRefreshHz := 60;
  timeBeginPeriod(1);
  {$ENDIF}
  FSwapInterval := Max(1, Round(FRefreshHz / 60));

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 150;
  FTimer.OnTimer := @TimerTick;

  NewDoc(True);
  SetMode(emModel);
  FFpsTime := NowMs;
  Application.AddOnIdleHandler(@AppIdle);
  Application.OnException := @AppException;
  LogFmt('editor', 'start: %d render threads, %s', [Pool.ThreadCount, OutputName]);
end;

procedure TEditorForm.FormDestroy(Sender: TObject);
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  {$IFDEF WINDOWS}
  timeEndPeriod(1);
  {$ENDIF}
  Pool.Free;
  Scene.Free;
  Doc.Free;
  Frame.Free;
  Paper.Free;
  FMeasure.Free;
  FTextCache.Free;
  FUndo.Free;
  FAddBtns.Free;
end;

procedure TEditorForm.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  CanClose := (ParamStr(1) = '--selftest') or ConfirmDiscard;
end;

function TEditorForm.NowMs: double;
{$IFDEF WINDOWS}
var
  C: int64;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  QueryPerformanceCounter(C);
  Result := double(C) * 1000 / FFreq;    // not C * 1000.0: FPC would compute that in single precision
  {$ELSE}
  Result := GetTickCount64;
  {$ENDIF}
end;

function TEditorForm.OutputName: string;
begin
  if not FUseGL then Result := 'GDI'
  else if FVSyncSupported then Result := Format('OpenGL vsync %d Hz / %d', [FRefreshHz, FSwapInterval])
  else Result := 'OpenGL';
end;

{ ------------------------------------------------------------ UI }

procedure TEditorForm.BuildMenu;
var
  MM: TMainMenu;

  function Top(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(MM);
    Result.Caption := ACaption;
    MM.Items.Add(Result);
  end;

  procedure Item(Parent: TMenuItem; const ACaption: string; Id: integer; AShortCut: TShortCut = 0);
  var
    Mi: TMenuItem;
  begin
    Mi := TMenuItem.Create(MM);
    Mi.Caption := ACaption;
    Mi.Tag := Id;
    Mi.ShortCut := AShortCut;
    Mi.OnClick := @MenuClick;
    Parent.Add(Mi);
  end;

var
  M: TMenuItem;
begin
  MM := TMainMenu.Create(Self);
  Menu := MM;
  M := Top('&File');
  Item(M, '&New (empty)', mNew, ShortCut(VK_N, [ssCtrl]));
  Item(M, 'New from &LZ-1 camera', mPreset);
  Item(M, '&Open...', mOpen, ShortCut(VK_O, [ssCtrl]));
  Item(M, '&Save', mSave, ShortCut(VK_S, [ssCtrl]));
  Item(M, 'Save &as...', mSaveAs, ShortCut(VK_S, [ssCtrl, ssShift]));
  Item(M, '-', 0);
  Item(M, 'E&xit', mExit);
  M := Top('&Edit');
  Item(M, '&Undo', mUndo, ShortCut(VK_Z, [ssCtrl]));
  Item(M, '&Redo', mRedo, ShortCut(VK_Y, [ssCtrl]));
  Item(M, '-', 0);
  Item(M, '&Duplicate', mDup, ShortCut(VK_D, [ssCtrl]));
  Item(M, 'De&lete', mDel);
  Item(M, 'Select &none', mNone);
  M := Top('&View');
  Item(M, 'Front (F5)', mFront);
  Item(M, 'Side (F6)', mSide);
  Item(M, 'Top (F7)', mTop);
  Item(M, 'Isometric (F8)', mIso);
  Item(M, 'Frame selection (F)', mFrame);
  Item(M, '-', 0);
  Item(M, 'X-ray (W)', mWire);
  Item(M, 'Grid', mGrid);
  Item(M, 'Model under the sketch', mModelInSketch);
  M := Top('E&xport');
  Item(M, 'Image (PNG / BMP)...', mStill);
  Item(M, 'Turntable GIF (3 s)', mGif);
  Item(M, 'Turntable MP4 (4 s, 60 fps)', mMp4);
  M := Top('&Help');
  Item(M, 'Keys and mouse', mKeys);
end;

function TEditorForm.AddSpeed(AParent: TWinControl; const ACaption, AHint: string; AGroup: integer; W: integer;
  AClick: TNotifyEvent): TSpeedButton;
begin
  Result := TSpeedButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Hint := AHint;
  Result.ShowHint := True;
  Result.GroupIndex := AGroup;
  Result.AllowAllUp := AGroup = 0;
  Result.SetBounds(AParent.Tag + 2, 3, W, 26);
  AParent.Tag := AParent.Tag + W + 2;
  Result.OnClick := AClick;
end;

procedure TEditorForm.BuildBars;
const
  ModeCaps: array[TEditMode] of string = ('Model  F2', 'Annotate  F3', 'Sketch  F4');
  AxisCaps: array[TAxisLock] of string = ('Free', 'X', 'Y', 'Z');
var
  M: TEditMode;
  T: TTool;
  A: TAxisLock;
  B: TSpeedButton;
  k: TShapeKind;

  procedure Spacer(AParent: TWinControl; W: integer; const ACaption: string = '');
  var
    L: TLabel;
  begin
    AParent.Tag := AParent.Tag + W;
    if ACaption <> '' then
    begin
      L := TLabel.Create(Self);
      L.Parent := AParent;
      L.Caption := ACaption;
      L.SetBounds(AParent.Tag, 9, 8 * Length(ACaption), 16);
      AParent.Tag := AParent.Tag + 8 * Length(ACaption) + 2;
    end;
  end;

  function Btn(AParent: TWinControl; const ACaption, AHint: string; AGroup, W, ATag: integer;
    AClick: TNotifyEvent): TSpeedButton;
  begin
    Result := AddSpeed(AParent, ACaption, AHint, AGroup, W, AClick);
    Result.Tag := ATag;
  end;

begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := False;
  with FStatus.Panels.Add do Width := 520;
  with FStatus.Panels.Add do Width := 380;
  with FStatus.Panels.Add do Width := 300;

  FTopBar := TPanel.Create(Self);
  FTopBar.Parent := Self;
  FTopBar.Align := alTop;
  FTopBar.Height := 34;
  FTopBar.BevelOuter := bvNone;
  FTopBar.BorderSpacing.Around := 3;
  for M := Low(TEditMode) to High(TEditMode) do
  begin
    B := Btn(FTopBar, ModeCaps[M], '', 1, 110, Ord(M), @ModeClick);
    B.Font.Style := [fsBold];
    FModeBtn[M] := B;
  end;
  Spacer(FTopBar, 16);
  Btn(FTopBar, 'Undo', 'Ctrl+Z', 0, 60, mUndo, @MenuClick);
  Btn(FTopBar, 'Redo', 'Ctrl+Y', 0, 60, mRedo, @MenuClick);
  Btn(FTopBar, 'Save', 'Ctrl+S', 0, 60, mSave, @MenuClick);
  Spacer(FTopBar, 16);
  Btn(FTopBar, 'Front', 'F5', 0, 56, mFront, @MenuClick);
  Btn(FTopBar, 'Side', 'F6', 0, 56, mSide, @MenuClick);
  Btn(FTopBar, 'Top', 'F7', 0, 56, mTop, @MenuClick);
  Btn(FTopBar, 'Iso', 'F8', 0, 56, mIso, @MenuClick);
  Btn(FTopBar, 'Frame', 'F', 0, 60, mFrame, @MenuClick);
  Btn(FTopBar, 'X-ray', 'W', 0, 60, mWire, @MenuClick);
  Spacer(FTopBar, 16);
  Btn(FTopBar, 'Export image', '', 0, 100, mStill, @MenuClick);
  Btn(FTopBar, 'Turntable GIF', '', 0, 100, mGif, @MenuClick);
  Btn(FTopBar, 'Turntable MP4', '', 0, 100, mMp4, @MenuClick);

  // one tool strip per mode; only the current one shows
  FToolBar := TPanel.Create(Self);
  FToolBar.Parent := Self;
  FToolBar.Align := alTop;
  FToolBar.Top := 40;
  FToolBar.Height := 32;
  FToolBar.BevelOuter := bvNone;
  FToolBar.BorderSpacing.Around := 3;
  for M := Low(TEditMode) to High(TEditMode) do
  begin
    FModePanel[M] := TPanel.Create(Self);
    FModePanel[M].Parent := FToolBar;
    FModePanel[M].Align := alClient;
    FModePanel[M].BevelOuter := bvNone;
    FModePanel[M].Visible := False;
    for T := Low(TTool) to High(TTool) do
      if T in ModeTools[M] then
        Btn(FModePanel[M], ToolNames[T] + '  ' + ToolKeys[T], ToolHints[T], 2, 96, Ord(T), @ToolClick);
  end;
  Spacer(FModePanel[emModel], 12, 'Axis:');
  for A := Low(TAxisLock) to High(TAxisLock) do
    FAxisBtns[A] := Btn(FModePanel[emModel], AxisCaps[A], 'Lock the move / scale / rotation to one axis', 3, 40,
      Ord(A), @AxisClick);
  Spacer(FModePanel[emModel], 12, 'Add:');
  for k := Low(TShapeKind) to High(TShapeKind) do
    FAddBtns.Add(Btn(FModePanel[emModel], '+ ' + ShapeKindNames[k], 'New ' + LowerCase(ShapeKindNames[k]) +
      ' at the centre of the view', 0, 80, Ord(k), @AddShapeClick));

  // left: outliner
  FLeft := TPanel.Create(Self);
  FLeft.Parent := Self;
  FLeft.Align := alLeft;
  FLeft.Width := 270;
  FLeft.BevelOuter := bvNone;
  with TSplitter.Create(Self) do
  begin
    Parent := Self;
    Align := alLeft;
    Left := 280;
  end;
  FLayerBar := TPanel.Create(Self);
  FLayerBar.Parent := FLeft;
  FLayerBar.Align := alBottom;
  FLayerBar.Height := 64;
  FLayerBar.BevelOuter := bvNone;
  with TButton.Create(Self) do begin Parent := FLayerBar; SetBounds(4, 4, 60, 26); Caption := 'Add'; Tag := 1; OnClick := @LayerBtnClick; end;
  with TButton.Create(Self) do begin Parent := FLayerBar; SetBounds(68, 4, 60, 26); Caption := 'Delete'; Tag := 2; OnClick := @LayerBtnClick; end;
  with TButton.Create(Self) do begin Parent := FLayerBar; SetBounds(132, 4, 60, 26); Caption := 'Up'; Tag := 3; OnClick := @LayerBtnClick; end;
  with TButton.Create(Self) do begin Parent := FLayerBar; SetBounds(196, 4, 60, 26); Caption := 'Down'; Tag := 4; OnClick := @LayerBtnClick; end;
  with TButton.Create(Self) do begin Parent := FLayerBar; SetBounds(4, 34, 124, 26); Caption := 'Clear layer'; Tag := 5; OnClick := @LayerBtnClick; end;
  FOutline := TListView.Create(Self);
  FOutline.Parent := FLeft;
  FOutline.Align := alClient;
  FOutline.ViewStyle := vsReport;
  FOutline.ReadOnly := True;
  FOutline.RowSelect := True;
  FOutline.HideSelection := False;
  FOutline.Checkboxes := True;
  FOutline.OnSelectItem := @OutlineSelect;
  FOutline.OnItemChecked := @OutlineChecked;
  FOutline.OnMouseMove := @OutlineMouseMove;
  FOutline.OnMouseLeave := @OutlineMouseLeave;
  FOutline.OnKeyDown := @OutlineKey;
  with FOutline.Columns.Add do begin Caption := 'Name'; Width := 150; end;
  with FOutline.Columns.Add do begin Caption := 'Type'; Width := 90; end;

  // right: properties
  FRight := TPanel.Create(Self);
  FRight.Parent := Self;
  FRight.Align := alRight;
  FRight.Width := 290;
  FRight.BevelOuter := bvNone;
  FProps := TScrollBox.Create(Self);
  FProps.Parent := FRight;
  FProps.Align := alClient;
  FProps.HorzScrollBar.Visible := False;
  FProps.VertScrollBar.Tracking := True;
end;

procedure TEditorForm.LayoutToolBar;
var
  M: TEditMode;
begin
  for M := Low(TEditMode) to High(TEditMode) do FModePanel[M].Visible := M = Mode;
  FLayerBar.Visible := Mode = emSketch;
end;

procedure TEditorForm.SetMode(M: TEditMode);
begin
  Mode := M;
  FModeBtn[M].Down := True;
  FDimFirst := False;
  SetLength(FCurPts, 0);
  LayoutToolBar;
  case M of
    emModel: SetTool(tSelect);
    emAnnot: SetTool(tSelect);
    emSketch: SetTool(tPencil);
  end;
  RefreshOutliner(True);
  RefreshProps(True);
  Log('editor', 'mode ' + FModeBtn[M].Caption);
end;

procedure TEditorForm.SetTool(T: TTool);
var
  i: integer;
begin
  Tool := T;
  for i := 0 to FModePanel[Mode].ControlCount - 1 do
    if (FModePanel[Mode].Controls[i] is TSpeedButton) and (TSpeedButton(FModePanel[Mode].Controls[i]).GroupIndex = 2) and
      (FModePanel[Mode].Controls[i].Tag = Ord(T)) then
      TSpeedButton(FModePanel[Mode].Controls[i]).Down := True;
  FDimFirst := False;
  UpdateStatus;
end;

procedure TEditorForm.SetAxis(A: TAxisLock);
begin
  Axis := A;
  FAxisBtns[A].Down := True;
end;

procedure TEditorForm.ModeClick(Sender: TObject);
begin
  SetMode(TEditMode((Sender as TComponent).Tag));
end;

procedure TEditorForm.ToolClick(Sender: TObject);
begin
  SetTool(TTool((Sender as TComponent).Tag));
end;

procedure TEditorForm.AxisClick(Sender: TObject);
begin
  SetAxis(TAxisLock((Sender as TComponent).Tag));
end;

procedure TEditorForm.AddShapeClick(Sender: TObject);
var
  S: TShape;
begin
  S := TShape.Create(TShapeKind((Sender as TComponent).Tag));
  S.Name := Doc.UniqueName(ShapeKindNames[S.Kind]);
  S.Pos := Scene.Target;
  Doc.Shapes.Add(S);
  SelShape := Doc.ShapeCount - 1;
  if Mode <> emModel then SetMode(emModel);
  SetTool(tMove);
  Commit('add ' + S.Name);
  RefreshOutliner(True);
  RefreshProps(True);
end;

procedure TEditorForm.LayerBtnClick(Sender: TObject);
var
  L: TSketchLayer;
  i: integer;
begin
  i := Doc.ActiveLayer;
  case (Sender as TComponent).Tag of
    1:
      begin
        L := TSketchLayer.Create(Format('Sketch %d', [Doc.LayerCount + 1]));
        Doc.Layers.Insert(i + 1, L);
        Doc.ActiveLayer := i + 1;
      end;
    2:
      if Doc.LayerCount > 1 then
      begin
        Doc.Layers.Delete(i);
        Doc.ActiveLayer := Min(i, Doc.LayerCount - 1);
      end;
    3:
      if i < Doc.LayerCount - 1 then
      begin
        Doc.Layers.Exchange(i, i + 1);
        Doc.ActiveLayer := i + 1;
      end;
    4:
      if i > 0 then
      begin
        Doc.Layers.Exchange(i, i - 1);
        Doc.ActiveLayer := i - 1;
      end;
    5: Doc.Layer(i).Strokes.Clear;
  end;
  Commit('layers');
  RefreshOutliner(True);
  RefreshProps(True);
end;

{ ------------------------------------------------------------ outliner }

procedure TEditorForm.RefreshOutliner(Force: boolean);
var
  Key: string;
  i: integer;
  It: TListItem;
begin
  // rebuild only when what it lists changed
  Key := IntToStr(Ord(Mode)) + '|';
  case Mode of
    emModel:
      for i := 0 to Doc.ShapeCount - 1 do
        Key := Key + Doc.Shape(i).Name + ShapeKindNames[Doc.Shape(i).Kind] + BoolToStr(Doc.Shape(i).Visible, '1', '0') + '|';
    emAnnot:
      for i := 0 to Doc.AnnotCount - 1 do Key := Key + Doc.Annot(i).Caption + BoolToStr(Doc.Annot(i).Visible, '1', '0') + '|';
  else
    for i := Doc.LayerCount - 1 downto 0 do
      Key := Key + Doc.Layer(i).Name + IntToStr(Doc.Layer(i).StrokeCount) + BoolToStr(Doc.Layer(i).Visible, '1', '0') +
        BoolToStr(Doc.Layer(i).Locked, 'L', '') + '|';
  end;
  if not Force and (Key = FOutlineKey) then Exit;
  FOutlineKey := Key;
  FOutlineSync := True;
  FOutline.Items.BeginUpdate;
  try
    FOutline.Items.Clear;
    case Mode of
      emModel:
        for i := 0 to Doc.ShapeCount - 1 do
        begin
          It := FOutline.Items.Add;
          It.Caption := Doc.Shape(i).Name;
          It.SubItems.Add(ShapeKindNames[Doc.Shape(i).Kind] + ' / ' + MaterialNames[Doc.Shape(i).Mat]);
          It.Checked := Doc.Shape(i).Visible;
          It.Data := Pointer(PtrInt(i));
        end;
      emAnnot:
        for i := 0 to Doc.AnnotCount - 1 do
        begin
          It := FOutline.Items.Add;
          It.Caption := Doc.Annot(i).Caption;
          It.SubItems.Add(AnnotKindNames[Doc.Annot(i).Kind]);
          It.Checked := Doc.Annot(i).Visible;
          It.Data := Pointer(PtrInt(i));
        end;
    else
      // top layer first, like a paint program
      for i := Doc.LayerCount - 1 downto 0 do
      begin
        It := FOutline.Items.Add;
        It.Caption := Doc.Layer(i).Name;
        It.SubItems.Add(Format('%d strokes%s', [Doc.Layer(i).StrokeCount, BoolToStr(Doc.Layer(i).Locked, ', locked', '')]));
        It.Checked := Doc.Layer(i).Visible;
        It.Data := Pointer(PtrInt(i));
      end;
    end;
    for i := 0 to FOutline.Items.Count - 1 do
    begin
      It := FOutline.Items[i];
      case Mode of
        emModel: It.Selected := PtrInt(It.Data) = SelShape;
        emAnnot: It.Selected := PtrInt(It.Data) = SelAnnot;
      else
        It.Selected := PtrInt(It.Data) = Doc.ActiveLayer;
      end;
    end;
  finally
    FOutline.Items.EndUpdate;
    FOutlineSync := False;
  end;
end;

procedure TEditorForm.OutlineSelect(Sender: TObject; Item: TListItem; Selected: boolean);
begin
  if FOutlineSync or not Selected then Exit;
  case Mode of
    emModel: SelShape := PtrInt(Item.Data);
    emAnnot: SelAnnot := PtrInt(Item.Data);
  else
    Doc.ActiveLayer := PtrInt(Item.Data);
  end;
  RefreshProps(True);
end;

procedure TEditorForm.OutlineChecked(Sender: TObject; Item: TListItem);
var
  i: integer;
begin
  if FOutlineSync then Exit;
  i := PtrInt(Item.Data);
  case Mode of
    emModel: Doc.Shape(i).Visible := Item.Checked;
    emAnnot: Doc.Annot(i).Visible := Item.Checked;
  else
    Doc.Layer(i).Visible := Item.Checked;
  end;
  Commit('visibility');
end;

procedure TEditorForm.OutlineMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
var
  It: TListItem;
begin
  It := FOutline.GetItemAt(X, Y);
  HoverShape := -1;
  HoverAnnot := -1;
  if It = nil then Exit;
  case Mode of
    emModel: HoverShape := PtrInt(It.Data);
    emAnnot: HoverAnnot := PtrInt(It.Data);
  end;
end;

procedure TEditorForm.OutlineMouseLeave(Sender: TObject);
begin
  HoverShape := -1;
  HoverAnnot := -1;
end;

procedure TEditorForm.OutlineKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_C) and (ssCtrl in Shift) and (FOutline.Selected <> nil) then
  begin
    Clipboard.AsText := FOutline.Selected.Caption + #9 + FOutline.Selected.SubItems.Text;
    Key := 0;
  end;
end;

{ ------------------------------------------------------------ properties }

procedure TEditorForm.PropHeader(const ACaption: string);
var
  L: TLabel;
begin
  L := TLabel.Create(FProps);
  L.Parent := FProps;
  L.Caption := ACaption;
  L.Font.Style := [fsBold];
  L.Left := 8;
  L.Top := FProps.Tag + 8;
  FProps.Tag := FProps.Tag + 30;
end;

function TEditorForm.PropRow(const ACaption: string; Id: integer; AKind: integer; AMin: double; AMax: double;
  AStep: double; Items: string): TControl;
var
  L: TLabel;
  Y: integer;
begin
  Y := FProps.Tag;
  if AKind <> rkBool then
  begin
    L := TLabel.Create(FProps);
    L.Parent := FProps;
    L.Caption := ACaption;
    L.Left := 10;
    L.Top := Y + 5;
  end;
  case AKind of
    rkFloat:
      begin
        Result := TFloatSpinEdit.Create(FProps);
        with TFloatSpinEdit(Result) do
        begin
          MinValue := AMin;
          MaxValue := AMax;
          Increment := AStep;
          DecimalPlaces := IfThen(AStep < 0.1, 3, 2);
          OnChange := @PropChanged;
        end;
      end;
    rkInt:
      begin
        Result := TSpinEdit.Create(FProps);
        with TSpinEdit(Result) do
        begin
          MinValue := Round(AMin);
          MaxValue := Round(AMax);
          OnChange := @PropChanged;
        end;
      end;
    rkText:
      begin
        Result := TEdit.Create(FProps);
        TEdit(Result).OnChange := @PropChanged;
      end;
    rkBool:
      begin
        Result := TCheckBox.Create(FProps);
        TCheckBox(Result).Caption := ACaption;
        TCheckBox(Result).OnChange := @PropChanged;
      end;
    rkCombo:
      begin
        Result := TComboBox.Create(FProps);
        TComboBox(Result).Style := csDropDownList;
        TComboBox(Result).Items.Text := Items;
        TComboBox(Result).OnChange := @PropChanged;
      end;
  else
    begin
      Result := TLabel.Create(FProps);
      TLabel(Result).Caption := Items;
    end;
  end;
  Result.Parent := FProps;
  Result.Tag := Id;
  Result.HelpContext := AKind;
  if AKind = rkBool then Result.SetBounds(10, Y + 3, 250, 22)
  else Result.SetBounds(112, Y, 150, 24);
  FProps.Tag := Y + 28;
end;

procedure TEditorForm.RefreshProps(Force: boolean);
var
  Key: string;
  S: TShape;
  A: TAnnot;
  i: integer;
  Mats: string;
  M: TMaterial;
begin
  case Mode of
    emModel: Key := 'M' + IntToStr(SelShape);
    emAnnot: Key := 'A' + IntToStr(SelAnnot);
  else
    Key := 'S' + IntToStr(Doc.ActiveLayer);
  end;
  if SelShape >= Doc.ShapeCount then SelShape := -1;
  if SelAnnot >= Doc.AnnotCount then SelAnnot := -1;
  if (Mode = emModel) and (SelShape >= 0) then Key := Key + ShapeKindNames[Doc.Shape(SelShape).Kind];
  if (Mode = emAnnot) and (SelAnnot >= 0) then Key := Key + AnnotKindNames[Doc.Annot(SelAnnot).Kind];
  if not Force and (Key = FPropsKey) then Exit;
  FPropsKey := Key;
  FPropSync := True;
  try
    FProps.DisableAutoSizing;
    try
      for i := FProps.ControlCount - 1 downto 0 do FProps.Controls[i].Free;
      FProps.Tag := 0;
      FProps.VertScrollBar.Position := 0;
      Mats := '';
      for M := Low(TMaterial) to High(TMaterial) do Mats := Mats + MaterialNames[M] + LineEnding;
      case Mode of
        emModel:
          if SelShape < 0 then
          begin
            PropHeader('Document');
            PropRow('Title', pTitle, rkText);
            PropRow('Snap (cm)', pSnapGrid, rkFloat, 0, 5, 0.05);
            PropRow('', 0, rkInfo, 0, 0, 0, Format('%d shapes, %d annotations, %d sketch layers',
              [Doc.ShapeCount, Doc.AnnotCount, Doc.LayerCount]));
            PropRow('', 0, rkInfo, 0, 0, 0, 'Click a shape to edit it.');
          end
          else
          begin
            S := Doc.Shape(SelShape);
            PropHeader(ShapeKindNames[S.Kind]);
            PropRow('Name', pName, rkText);
            PropRow('Material', pMat, rkCombo, 0, 0, 0, Mats);
            PropRow('Visible', pVisible, rkBool);
            PropHeader('Transform');
            PropRow('Position X', pPosX, rkFloat, -500, 500, 0.1);
            PropRow('Position Y', pPosY, rkFloat, -500, 500, 0.1);
            PropRow('Position Z', pPosZ, rkFloat, -500, 500, 0.1);
            PropRow('Rotation X', pRotX, rkFloat, -360, 360, 5);
            PropRow('Rotation Y', pRotY, rkFloat, -360, 360, 5);
            PropRow('Rotation Z', pRotZ, rkFloat, -360, 360, 5);
            PropRow('Scale X', pScaleX, rkFloat, 0.01, 100, 0.05);
            PropRow('Scale Y', pScaleY, rkFloat, 0.01, 100, 0.05);
            PropRow('Scale Z', pScaleZ, rkFloat, 0.01, 100, 0.05);
            PropRow('Draw order bias', pBias, rkFloat, -10, 10, 0.05);
            PropHeader('Shape');
            case S.Kind of
              skBox:
                begin
                  PropRow('Width (X)', pSizeX, rkFloat, 0.01, 500, 0.1);
                  PropRow('Height (Y)', pSizeY, rkFloat, 0.01, 500, 0.1);
                  PropRow('Depth (Z)', pSizeZ, rkFloat, 0.01, 500, 0.1);
                  PropRow('Corner radius', pRadius, rkFloat, 0, 100, 0.05);
                end;
              skCylinder:
                begin
                  PropRow('Radius bottom', pRBot, rkFloat, 0, 500, 0.05);
                  PropRow('Radius top', pRTop, rkFloat, 0, 500, 0.05);
                  PropRow('Height', pHeight, rkFloat, 0.01, 500, 0.1);
                  PropRow('Segments', pSegs, rkInt, 3, 256);
                  PropRow('Ribbed (knurling)', pRibbed, rkBool);
                  PropRow('Scale ticks', pTicks, rkInt, 0, 128);
                end;
              skLoft:
                begin
                  PropRow('Height', pHeight, rkFloat, 0.01, 500, 0.1);
                  PropRow('Bottom width', pBW, rkFloat, 0.01, 500, 0.1);
                  PropRow('Bottom depth', pBD, rkFloat, 0.01, 500, 0.1);
                  PropRow('Top width', pTW, rkFloat, 0, 500, 0.1);
                  PropRow('Top depth', pTD, rkFloat, 0, 500, 0.1);
                  PropRow('Top shift (Z)', pShift, rkFloat, -500, 500, 0.05);
                  PropRow('Chamfer', pChamfer, rkFloat, 0, 50, 0.05);
                end;
            end;
          end;
        emAnnot:
          if SelAnnot < 0 then
          begin
            PropHeader('Annotations');
            PropRow('', 0, rkInfo, 0, 0, 0, 'Pick a tool, then click on the model.');
            PropRow('', 0, rkInfo, 0, 0, 0, 'Select one to drag or edit it.');
          end
          else
          begin
            A := Doc.Annot(SelAnnot);
            PropHeader(AnnotKindNames[A.Kind]);
            PropRow('Text', pAText, rkText);
            if A.Kind = akDimension then PropRow('', 0, rkInfo, 0, 0, 0, '(empty text: measured, in mm)');
            PropRow('Visible', pAVis, rkBool);
            PropHeader('Anchor');
            PropRow('A  X', pAX, rkFloat, -500, 500, 0.1);
            PropRow('A  Y', pAY, rkFloat, -500, 500, 0.1);
            PropRow('A  Z', pAZ, rkFloat, -500, 500, 0.1);
            case A.Kind of
              akDimension:
                begin
                  PropRow('B  X', pBX, rkFloat, -500, 500, 0.1);
                  PropRow('B  Y', pBY, rkFloat, -500, 500, 0.1);
                  PropRow('B  Z', pBZ, rkFloat, -500, 500, 0.1);
                  PropHeader('Offset of the line');
                  PropRow('Offset X', pOX, rkFloat, -500, 500, 0.1);
                  PropRow('Offset Y', pOY, rkFloat, -500, 500, 0.1);
                  PropRow('Offset Z', pOZ, rkFloat, -500, 500, 0.1);
                end;
              akCallout:
                begin
                  PropRow('Label dx (px)', pADX, rkFloat, -2000, 2000, 5);
                  PropRow('Label dy (px)', pADY, rkFloat, -2000, 2000, 5);
                  PropRow('Number', pANum, rkInt, 0, 999);
                end;
            end;
          end;
      else
        begin
          PropHeader('Pencil');
          PropRow('Line width', pPenW, rkFloat, 0.3, 8, 0.1);
          PropRow('Darkness', pInk, rkFloat, 0.05, 1, 0.05);
          PropRow('Ruled lines overshoot', pRuled, rkBool);
          PropRow('Hatching', pHatch, rkCombo, 0, 0, 0, 'Light' + LineEnding + 'Medium' + LineEnding + 'Dark (cross)');
          PropRow('Eraser radius', pEraser, rkFloat, 2, 80, 1);
          PropHeader('Perspective');
          PropRow('Show guides', pGuides, rkBool);
          PropRow('Ruled lines snap to them', pSnapP, rkBool);
          PropHeader('Active layer');
          PropRow('Name', pLName, rkText);
          PropRow('Visible', pLVis, rkBool);
          PropRow('Locked', pLLock, rkBool);
        end;
      end;
    finally
      FProps.EnableAutoSizing;
    end;
  finally
    FPropSync := False;
  end;
  SyncPropValues;
end;

function TEditorForm.GetFloat(Id: integer): double;
var
  S: TShape;
  A: TAnnot;
begin
  Result := 0;
  S := nil;
  A := nil;
  if (SelShape >= 0) and (SelShape < Doc.ShapeCount) then S := Doc.Shape(SelShape);
  if (SelAnnot >= 0) and (SelAnnot < Doc.AnnotCount) then A := Doc.Annot(SelAnnot);
  case Id of
    pSnapGrid: Result := SnapGrid;
    pPenW: Result := PenWidth;
    pInk: Result := PenInk;
    pEraser: Result := EraserRadius;
    pHatch: Result := HatchLevel;
    pRuled: Result := Ord(RuledSketchy);
    pSnapP: Result := Ord(SnapPersp);
    pGuides: Result := Ord(Scene.ShowGuides);
    pLVis: Result := Ord(Doc.Layer(Doc.ActiveLayer).Visible);
    pLLock: Result := Ord(Doc.Layer(Doc.ActiveLayer).Locked);
  end;
  if (S <> nil) and (Mode = emModel) then
    case Id of
      pMat: Result := Ord(S.Mat);
      pVisible: Result := Ord(S.Visible);
      pPosX: Result := S.Pos.X;
      pPosY: Result := S.Pos.Y;
      pPosZ: Result := S.Pos.Z;
      pRotX: Result := S.Rot.X;
      pRotY: Result := S.Rot.Y;
      pRotZ: Result := S.Rot.Z;
      pScaleX: Result := S.Scale.X;
      pScaleY: Result := S.Scale.Y;
      pScaleZ: Result := S.Scale.Z;
      pBias: Result := S.DepthBias;
      pSizeX: Result := S.Size.X;
      pSizeY: Result := S.Size.Y;
      pSizeZ: Result := S.Size.Z;
      pRadius: Result := S.Radius;
      pRBot: Result := S.RBottom;
      pRTop: Result := S.RTop;
      pHeight: Result := S.Height;
      pSegs: Result := S.Segments;
      pRibbed: Result := Ord(S.Ribbed);
      pTicks: Result := S.Ticks;
      pBW: Result := S.BW;
      pBD: Result := S.BD;
      pTW: Result := S.TW;
      pTD: Result := S.TD;
      pShift: Result := S.TopShift;
      pChamfer: Result := S.Chamfer;
    end;
  if (A <> nil) and (Mode = emAnnot) then
    case Id of
      pAX: Result := A.A.X;
      pAY: Result := A.A.Y;
      pAZ: Result := A.A.Z;
      pBX: Result := A.B.X;
      pBY: Result := A.B.Y;
      pBZ: Result := A.B.Z;
      pOX: Result := A.Offset.X;
      pOY: Result := A.Offset.Y;
      pOZ: Result := A.Offset.Z;
      pADX: Result := A.DX;
      pADY: Result := A.DY;
      pANum: Result := A.Number;
      pAVis: Result := Ord(A.Visible);
    end;
end;

procedure TEditorForm.SetFloat(Id: integer; V: double);
var
  S: TShape;
  A: TAnnot;
begin
  S := nil;
  A := nil;
  if (SelShape >= 0) and (SelShape < Doc.ShapeCount) then S := Doc.Shape(SelShape);
  if (SelAnnot >= 0) and (SelAnnot < Doc.AnnotCount) then A := Doc.Annot(SelAnnot);
  case Id of
    pSnapGrid: SnapGrid := V;
    pPenW: PenWidth := V;
    pInk: PenInk := V;
    pEraser: EraserRadius := V;
    pHatch: HatchLevel := Round(V);
    pRuled: RuledSketchy := V <> 0;
    pSnapP: SnapPersp := V <> 0;
    pGuides: Scene.ShowGuides := V <> 0;
    pLVis: Doc.Layer(Doc.ActiveLayer).Visible := V <> 0;
    pLLock: Doc.Layer(Doc.ActiveLayer).Locked := V <> 0;
  end;
  if (S <> nil) and (Mode = emModel) then
    case Id of
      pMat: S.Mat := TMaterial(EnsureRange(Round(V), 0, Ord(High(TMaterial))));
      pVisible: S.Visible := V <> 0;
      pPosX: S.Pos.X := V;
      pPosY: S.Pos.Y := V;
      pPosZ: S.Pos.Z := V;
      pRotX: S.Rot.X := V;
      pRotY: S.Rot.Y := V;
      pRotZ: S.Rot.Z := V;
      pScaleX: S.Scale.X := V;
      pScaleY: S.Scale.Y := V;
      pScaleZ: S.Scale.Z := V;
      pBias: S.DepthBias := V;
      pSizeX: S.Size.X := V;
      pSizeY: S.Size.Y := V;
      pSizeZ: S.Size.Z := V;
      pRadius: S.Radius := V;
      pRBot: S.RBottom := V;
      pRTop: S.RTop := V;
      pHeight: S.Height := V;
      pSegs: S.Segments := EnsureRange(Round(V), 3, 256);
      pRibbed: S.Ribbed := V <> 0;
      pTicks: S.Ticks := Round(V);
      pBW: S.BW := V;
      pBD: S.BD := V;
      pTW: S.TW := V;
      pTD: S.TD := V;
      pShift: S.TopShift := V;
      pChamfer: S.Chamfer := V;
    end;
  if (A <> nil) and (Mode = emAnnot) then
    case Id of
      pAX: A.A.X := V;
      pAY: A.A.Y := V;
      pAZ: A.A.Z := V;
      pBX: A.B.X := V;
      pBY: A.B.Y := V;
      pBZ: A.B.Z := V;
      pOX: A.Offset.X := V;
      pOY: A.Offset.Y := V;
      pOZ: A.Offset.Z := V;
      pADX: A.DX := V;
      pADY: A.DY := V;
      pANum: A.Number := Round(V);
      pAVis: A.Visible := V <> 0;
    end;
end;

function TEditorForm.GetText(Id: integer): string;
begin
  Result := '';
  case Id of
    pTitle: Result := Doc.Title;
    pName: if SelShape >= 0 then Result := Doc.Shape(SelShape).Name;
    pAText: if SelAnnot >= 0 then Result := Doc.Annot(SelAnnot).Text;
    pLName: Result := Doc.Layer(Doc.ActiveLayer).Name;
  end;
end;

procedure TEditorForm.SetText(Id: integer; const V: string);
begin
  case Id of
    pTitle: Doc.Title := V;
    pName: if SelShape >= 0 then Doc.Shape(SelShape).Name := V;
    pAText: if SelAnnot >= 0 then Doc.Annot(SelAnnot).Text := V;
    pLName: Doc.Layer(Doc.ActiveLayer).Name := V;
  end;
end;

// Panel values follow the document (drags, undo), except the field being typed in.
procedure TEditorForm.SyncPropValues;
var
  i: integer;
  C: TControl;
begin
  FPropSync := True;
  try
    for i := 0 to FProps.ControlCount - 1 do
    begin
      C := FProps.Controls[i];
      if (C.Tag = 0) or (C = ActiveControl) then Continue;
      case C.HelpContext of
        rkFloat: if Abs(TFloatSpinEdit(C).Value - GetFloat(C.Tag)) > 1e-6 then TFloatSpinEdit(C).Value := GetFloat(C.Tag);
        rkInt: if TSpinEdit(C).Value <> Round(GetFloat(C.Tag)) then TSpinEdit(C).Value := Round(GetFloat(C.Tag));
        rkText: if TEdit(C).Text <> GetText(C.Tag) then TEdit(C).Text := GetText(C.Tag);
        rkBool: if TCheckBox(C).Checked <> (GetFloat(C.Tag) <> 0) then TCheckBox(C).Checked := GetFloat(C.Tag) <> 0;
        rkCombo: if TComboBox(C).ItemIndex <> Round(GetFloat(C.Tag)) then TComboBox(C).ItemIndex := Round(GetFloat(C.Tag));
      end;
    end;
  finally
    FPropSync := False;
  end;
end;

procedure TEditorForm.PropChanged(Sender: TObject);
var
  C: TControl;
begin
  if FPropSync then Exit;
  C := Sender as TControl;
  case C.HelpContext of
    rkFloat: SetFloat(C.Tag, TFloatSpinEdit(C).Value);
    rkInt: SetFloat(C.Tag, TSpinEdit(C).Value);
    rkText: SetText(C.Tag, TEdit(C).Text);
    rkBool: SetFloat(C.Tag, Ord(TCheckBox(C).Checked));
    rkCombo: SetFloat(C.Tag, TComboBox(C).ItemIndex);
  end;
  // tool settings are not part of the document
  if not (C.Tag in [pSnapGrid, pPenW, pInk, pRuled, pHatch, pEraser, pSnapP, pGuides]) then ScheduleCommit;
end;

procedure TEditorForm.UpdateStatus;
const
  Hints: array[TTool] of string = ('Click a shape to select it.  Right drag orbits, middle drag pans, wheel zooms.',
    'Drag the shape.  X / Y / Z lock an axis, Ctrl turns the snap off.',
    'Drag sideways to rotate about the locked axis (Y when free).  Shift: 15 degree steps.',
    'Drag up / down to scale.  X / Y / Z: one axis only.',
    'Click the first point, then the second.  Corners snap.',
    'Click a point on the model to label it.',
    'Click a point on the model: a numbered callout.',
    'Draw freehand.', 'Drag a ruled line; it snaps to the perspective guides.',
    'Drag a box for the ellipse; Shift for a circle.',
    'Draw the outline of an area: it fills with hatching.',
    'Drag over strokes of the active layer to rub them out.',
    'Drag a vanishing point (the blue circles).');
var
  Sel: string;
begin
  FStatus.Panels[0].Text := Hints[Tool];
  Sel := '';
  if (Mode = emModel) and (SelShape >= 0) and (SelShape < Doc.ShapeCount) then
    with Doc.Shape(SelShape) do
      Sel := Format('%s  pos %.2f, %.2f, %.2f', [Name, Pos.X, Pos.Y, Pos.Z])
  else if (Mode = emAnnot) and (SelAnnot >= 0) and (SelAnnot < Doc.AnnotCount) then
    Sel := Doc.Annot(SelAnnot).Caption
  else if Mode = emSketch then
    Sel := Format('layer "%s", %d strokes', [Doc.Layer(Doc.ActiveLayer).Name, Doc.Layer(Doc.ActiveLayer).StrokeCount]);
  FStatus.Panels[1].Text := Sel;
  FStatus.Panels[2].Text := Format('%.0f fps  %.1f ms  %d prims  %d threads', [FFps, FCpuMs, Scene.PrimCount,
    Pool.ThreadCount]);
end;

procedure TEditorForm.TimerTick(Sender: TObject);
var
  Cap: string;
begin
  RefreshOutliner;
  RefreshProps;
  SyncPropValues;
  UpdateStatus;
  if (FCommitAt <> 0) and (GetTickCount64 >= FCommitAt) then
  begin
    FCommitAt := 0;
    Commit('edit');
  end;
  if FileName <> '' then Cap := ExtractFileName(FileName) else Cap := Doc.Title;
  Cap := 'LZ Sketch Editor - ' + Cap;
  if Modified then Cap := Cap + ' *';
  if Caption <> Cap then Caption := Cap;
end;

{ ------------------------------------------------------------ undo }

procedure TEditorForm.Commit(const What: string);
var
  S: string;
begin
  S := Doc.ToJSONString;
  if (FUndoPos >= 0) and (FUndoPos < FUndo.Count) and (FUndo[FUndoPos] = S) then Exit;
  while FUndo.Count > FUndoPos + 1 do FUndo.Delete(FUndo.Count - 1);
  FUndo.Add(S);
  if FUndo.Count > 200 then FUndo.Delete(0);
  FUndoPos := FUndo.Count - 1;
  if FUndo.Count > 1 then Modified := True;
  Log('edit', What);
end;

procedure TEditorForm.ScheduleCommit;
begin
  FCommitAt := GetTickCount64 + 500;
end;

procedure TEditorForm.RestoreState(const S: string);
begin
  Doc.FromJSONString(S);
  if SelShape >= Doc.ShapeCount then SelShape := -1;
  if SelAnnot >= Doc.AnnotCount then SelAnnot := -1;
  RefreshOutliner(True);
  RefreshProps(True);
  Modified := True;
end;

procedure TEditorForm.Undo;
begin
  if FCommitAt <> 0 then
  begin
    FCommitAt := 0;
    Commit('edit');
  end;
  if FUndoPos <= 0 then Exit;
  Dec(FUndoPos);
  RestoreState(FUndo[FUndoPos]);
  Log('edit', 'undo');
end;

procedure TEditorForm.Redo;
begin
  if FUndoPos >= FUndo.Count - 1 then Exit;
  Inc(FUndoPos);
  RestoreState(FUndo[FUndoPos]);
  Log('edit', 'redo');
end;

{ ------------------------------------------------------------ files }

function TEditorForm.ConfirmDiscard: boolean;
begin
  Result := not Modified or
    (MessageDlg('Discard the unsaved changes?', mtConfirmation, [mbYes, mbNo], 0) = mrYes);
end;

procedure TEditorForm.NewDoc(Preset: boolean);
begin
  if Preset then Doc.LoadCameraPreset else Doc.Clear;
  FileName := '';
  SelShape := -1;
  SelAnnot := -1;
  Scene.Yaw := Doc.ViewYaw;
  Scene.Pitch := Doc.ViewPitch;
  Scene.Dist := Doc.ViewDist;
  Scene.Target := Doc.ViewTarget;
  if Preset then Scene.FrameShapes(Doc);
  FUndo.Clear;
  FUndoPos := -1;
  Commit('new document');
  Modified := False;
  RefreshOutliner(True);
  RefreshProps(True);
end;

procedure TEditorForm.OpenDoc;
var
  D: TOpenDialog;
begin
  if not ConfirmDiscard then Exit;
  D := TOpenDialog.Create(Self);
  try
    D.Filter := 'Sketch documents|*.sketch.json;*.json|All files|*.*';
    if not D.Execute then Exit;
    try
      Doc.LoadFromFile(D.FileName);
    except
      on E: Exception do
      begin
        MessageDlg('Cannot open ' + D.FileName + ': ' + E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    FileName := D.FileName;
    SelShape := -1;
    SelAnnot := -1;
    Scene.Yaw := Doc.ViewYaw;
    Scene.Pitch := Doc.ViewPitch;
    Scene.Dist := Doc.ViewDist;
    Scene.Target := Doc.ViewTarget;
    FUndo.Clear;
    FUndoPos := -1;
    Commit('open ' + FileName);
    Modified := False;
    RefreshOutliner(True);
    RefreshProps(True);
  finally
    D.Free;
  end;
end;

procedure TEditorForm.SaveDoc(AsNew: boolean);
var
  D: TSaveDialog;
begin
  if AsNew or (FileName = '') then
  begin
    D := TSaveDialog.Create(Self);
    try
      D.Filter := 'Sketch documents|*.sketch.json';
      D.DefaultExt := '.sketch.json';
      D.FileName := Doc.Title + '.sketch.json';
      D.Options := D.Options + [ofOverwritePrompt];
      if not D.Execute then Exit;
      FileName := D.FileName;
    finally
      D.Free;
    end;
  end;
  Doc.ViewYaw := Scene.Yaw;
  Doc.ViewPitch := Scene.Pitch;
  Doc.ViewDist := Scene.Dist;
  Doc.ViewTarget := Scene.Target;
  Doc.SaveToFile(FileName);
  Modified := False;
  Log('file', 'saved ' + FileName);
  FStatus.Panels[1].Text := 'Saved ' + FileName;
end;

{ ------------------------------------------------------------ menu / keys }

procedure TEditorForm.SetView(AYaw, APitch: single);
begin
  Scene.Yaw := AYaw;
  Scene.Pitch := APitch;
end;

procedure TEditorForm.FrameSelection;
begin
  if (Mode = emModel) and (SelShape >= 0) then
  begin
    Scene.FrameShapes(Doc, SelShape);
    Scene.Dist := Max(Scene.Dist, 12);
  end
  else
    Scene.FrameShapes(Doc);
end;

procedure TEditorForm.DeleteSelection;
begin
  if (Mode = emModel) and (SelShape >= 0) then
  begin
    Doc.Shapes.Delete(SelShape);
    SelShape := -1;
    Commit('delete shape');
  end
  else if (Mode = emAnnot) and (SelAnnot >= 0) then
  begin
    Doc.Annots.Delete(SelAnnot);
    SelAnnot := -1;
    Commit('delete annotation');
  end;
  RefreshOutliner(True);
  RefreshProps(True);
end;

procedure TEditorForm.DuplicateSelection;
var
  S: TShape;
  A: TAnnot;
begin
  if (Mode = emModel) and (SelShape >= 0) then
  begin
    S := Doc.Shape(SelShape).Clone;
    S.Name := Doc.UniqueName(S.Name);
    S.Pos := VAdd(S.Pos, V3(1, 0, 0));
    Doc.Shapes.Add(S);
    SelShape := Doc.ShapeCount - 1;
    Commit('duplicate ' + S.Name);
  end
  else if (Mode = emAnnot) and (SelAnnot >= 0) then
  begin
    A := Doc.Annot(SelAnnot).Clone;
    A.A := VAdd(A.A, V3(1, 0, 0));
    A.B := VAdd(A.B, V3(1, 0, 0));
    if A.Kind = akCallout then A.Number := Doc.NextCalloutNumber;
    Doc.Annots.Add(A);
    SelAnnot := Doc.AnnotCount - 1;
    Commit('duplicate annotation');
  end;
  RefreshOutliner(True);
  RefreshProps(True);
end;

procedure TEditorForm.MenuClick(Sender: TObject);
begin
  case (Sender as TComponent).Tag of
    mNew: if ConfirmDiscard then NewDoc(False);
    mPreset: if ConfirmDiscard then NewDoc(True);
    mOpen: OpenDoc;
    mSave: SaveDoc(False);
    mSaveAs: SaveDoc(True);
    mExit: Close;
    mUndo: Undo;
    mRedo: Redo;
    mDup: DuplicateSelection;
    mDel: DeleteSelection;
    mNone:
      begin
        SelShape := -1;
        SelAnnot := -1;
      end;
    mFront: SetView(0, 0.02);
    mSide: SetView(-Pi / 2, 0.02);
    mTop: SetView(0, Pi / 2 - 0.02);
    mIso: SetView(-0.62, 0.42);
    mFrame: FrameSelection;
    mWire: Scene.Wire := not Scene.Wire;
    mGrid: Scene.ShowGrid := not Scene.ShowGrid;
    mModelInSketch: Scene.ShowModel := not Scene.ShowModel;
    mStill: ExportStill;
    mGif: ExportTurntable(False);
    mMp4: ExportTurntable(True);
    mKeys:
      MessageDlg('Keys and mouse',
        'Right drag: orbit    Middle drag / Shift+right drag: pan    Wheel: zoom' + LineEnding +
        'F2 Model   F3 Annotate   F4 Sketch' + LineEnding +
        'Model: Q select, G move, R rotate, S scale, X / Y / Z axis lock, Ctrl+D duplicate, Del delete' + LineEnding +
        'Annotate: Q select, D dimension, L label, C callout' + LineEnding +
        'Sketch: P pencil, L line, E ellipse, H hatch, X eraser, V perspective guides' + LineEnding +
        'F frame selection, F5-F8 front / side / top / iso, W x-ray' + LineEnding +
        'Ctrl+Z undo, Ctrl+Y redo, Ctrl+S save, Ctrl+O open',
        mtInformation, [mbOK], 0);
  end;
end;

function TEditorForm.EditingText: boolean;
begin
  Result := (ActiveControl is TCustomEdit) or (ActiveControl is TCustomFloatSpinEdit) or
    (ActiveControl is TCustomComboBox);
end;

procedure TEditorForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if EditingText then Exit;
  if ssCtrl in Shift then Exit;      // menu shortcuts
  case Key of
    VK_F2: SetMode(emModel);
    VK_F3: SetMode(emAnnot);
    VK_F4: SetMode(emSketch);
    VK_F5: SetView(0, 0.02);
    VK_F6: SetView(-Pi / 2, 0.02);
    VK_F7: SetView(0, Pi / 2 - 0.02);
    VK_F8: SetView(-0.62, 0.42);
    VK_F: FrameSelection;
    VK_DELETE: DeleteSelection;
    VK_ESCAPE:
      begin
        SetLength(FCurPts, 0);
        FDimFirst := False;
        FDrag := dgNone;
      end;
  else
    case Mode of
      emModel:
        case Key of
          VK_Q: SetTool(tSelect);
          VK_G: SetTool(tMove);
          VK_R: SetTool(tRotate);
          VK_S: SetTool(tScale);
          VK_X: if Axis = alX then SetAxis(alFree) else SetAxis(alX);
          VK_Y: if Axis = alY then SetAxis(alFree) else SetAxis(alY);
          VK_Z: if Axis = alZ then SetAxis(alFree) else SetAxis(alZ);
          VK_W: Scene.Wire := not Scene.Wire;
        else
          Exit;
        end;
      emAnnot:
        case Key of
          VK_Q: SetTool(tSelect);
          VK_D: SetTool(tAddDim);
          VK_L: SetTool(tAddLabel);
          VK_C: SetTool(tAddCallout);
          VK_W: Scene.Wire := not Scene.Wire;
        else
          Exit;
        end;
      emSketch:
        case Key of
          VK_P: SetTool(tPencil);
          VK_L: SetTool(tLine);
          VK_E: SetTool(tEllipse);
          VK_H: SetTool(tHatch);
          VK_X: SetTool(tEraser);
          VK_V:
            begin
              SetTool(tGuide);
              Scene.ShowGuides := True;
            end;
        else
          Exit;
        end;
    end;
  end;
  Key := 0;
end;

{ ------------------------------------------------------------ viewport input }

procedure TEditorForm.VMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  if FOutput is TWinControl then TWinControl(FOutput).SetFocus;
  FDownX := X;
  FDownY := Y;
  FLastX := X;
  FLastY := Y;
  FDragButton := Button;
  if (Button = mbMiddle) or ((Button = mbRight) and (ssShift in Shift)) then
    FDrag := dgPan
  else if (Button = mbRight) or ((Button = mbLeft) and (ssAlt in Shift)) then
    FDrag := dgOrbit
  else if Button = mbLeft then
  begin
    FDrag := dgTool;
    ToolDown(X, Y, Shift);
  end;
end;

procedure TEditorForm.VMouseMove(Sender: TObject; Shift: TShiftState; X, Y: integer);
begin
  FMouseX := X;
  FMouseY := Y;
  case FDrag of
    dgOrbit:
      begin
        Scene.Yaw := Scene.Yaw + (X - FLastX) * 0.008;
        Scene.Pitch := EnsureRange(Scene.Pitch + (Y - FLastY) * 0.006, -1.55, 1.55);
      end;
    dgPan:
      Scene.Target := VSub(Scene.Target, Scene.ScreenDeltaToWorld(Scene.Target, X - FLastX, Y - FLastY));
    dgTool:
      ToolMove(X, Y, Shift);
  else
    if Mode = emModel then HoverShape := Scene.PickShape(X, Y);
  end;
  FLastX := X;
  FLastY := Y;
end;

procedure TEditorForm.VMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
begin
  if (FDrag = dgTool) and (Button = mbLeft) then ToolUp(X, Y, Shift);
  FDrag := dgNone;
end;

procedure TEditorForm.VMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: integer; MousePos: TPoint;
  var Handled: boolean);
begin
  Scene.Dist := EnsureRange(Scene.Dist * Power(0.88, WheelDelta / 120), 2, 2000);
  Handled := True;
end;

function TEditorForm.ActiveLayerOK: boolean;
begin
  Result := not Doc.Layer(Doc.ActiveLayer).Locked and Doc.Layer(Doc.ActiveLayer).Visible;
  if not Result then FStatus.Panels[0].Text := 'The active layer is locked or hidden.';
end;

procedure TEditorForm.ToolDown(X, Y: integer; Shift: TShiftState);
var
  Hit: TVec3;
  Sh, i, Best: integer;
  An: TAnnot;
  D, BestD: single;
begin
  FBefore := Doc.ToJSONString;
  case Mode of
    emModel:
      begin
        Sh := Scene.PickShape(X, Y);
        // the select tool picks (or clears); move / rotate / scale take a clicked shape,
        // or keep working on the selection when the drag starts on empty paper
        if (Tool = tSelect) or (Sh >= 0) then SelShape := Sh;
        if SelShape >= 0 then
          with Doc.Shape(SelShape) do
          begin
            FStartPos := Pos;
            FStartRot := Rot;
            FStartScale := Scale;
          end;
        RefreshOutliner(True);
        RefreshProps;
      end;
    emAnnot:
      case Tool of
        tSelect:
          begin
            // the nearest annotation handle within 14 px
            Best := -1;
            BestD := 14;
            for i := 0 to Doc.AnnotCount - 1 do
              if i <= High(Scene.AnnotHandles) then
              begin
                D := PtDist(Scene.AnnotHandles[i], PointF(X, Y));
                if D < BestD then
                begin
                  BestD := D;
                  Best := i;
                end;
              end;
            SelAnnot := Best;
            if Best >= 0 then
              with Doc.Annot(Best) do
              begin
                FStartA := A;
                FStartB := B;
                FStartOff := Offset;
                FStartDX := DX;
                FStartDY := DY;
              end;
            RefreshOutliner(True);
            RefreshProps;
          end;
        tAddDim:
          if Scene.PickPoint(X, Y, Hit, Sh) then
          begin
            if not FDimFirst then
            begin
              FDimA := Hit;
              FDimFirst := True;
            end
            else
            begin
              An := TAnnot.Create(akDimension);
              An.A := FDimA;
              An.B := Hit;
              // offset: away from the model, across the measured line, about 2 cm
              An.Offset := VMul(VNorm(VCross(VSub(Hit, FDimA), VSub(Scene.FromView(V3(0, 0, Scene.Dist)), Hit))), 2);
              if An.Offset.Y < 0 then An.Offset := VMul(An.Offset, -1);
              Doc.Annots.Add(An);
              SelAnnot := Doc.AnnotCount - 1;
              FDimFirst := False;
              Commit('add dimension');
              RefreshOutliner(True);
              RefreshProps(True);
            end;
          end;
        tAddLabel, tAddCallout:
          if Scene.PickPoint(X, Y, Hit, Sh) then
          begin
            if Tool = tAddLabel then
            begin
              An := TAnnot.Create(akLabel);
              if Sh >= 0 then An.Text := Doc.Shape(Sh).Name;
            end
            else
            begin
              An := TAnnot.Create(akCallout);
              An.Number := Doc.NextCalloutNumber;
              if Sh >= 0 then An.Text := Doc.Shape(Sh).Name;
              if X < Frame.Width / 2 then An.DX := -70;
            end;
            An.A := Hit;
            Doc.Annots.Add(An);
            SelAnnot := Doc.AnnotCount - 1;
            Commit('add ' + LowerCase(AnnotKindNames[An.Kind]));
            RefreshOutliner(True);
            RefreshProps(True);
          end;
      end;
    emSketch:
      case Tool of
        tPencil, tHatch, tLine, tEllipse:
          if ActiveLayerOK then
          begin
            SetLength(FCurPts, 1);
            FCurPts[0] := PointF(X, Y);
          end;
        tEraser:
          if ActiveLayerOK then EraseAt(X, Y);
        tGuide:
          begin
            FDragVP := -1;
            if PtDist(Doc.VP1, PointF(X, Y)) < 16 then FDragVP := 1
            else if PtDist(Doc.VP2, PointF(X, Y)) < 16 then FDragVP := 2;
          end;
      end;
  end;
end;

procedure TEditorForm.ToolMove(X, Y: integer; Shift: TShiftState);
var
  S: TShape;
  D, AxisV: TVec3;
  P0, P1, Ms: TPointF;
  T, Ang, F: single;

  function AxisVec: TVec3;
  begin
    case Axis of
      alX: Result := V3(1, 0, 0);
      alY: Result := V3(0, 1, 0);
    else
      Result := V3(0, 0, 1);
    end;
  end;

  function Snap(V: single): single;
  begin
    if (SnapGrid > 0) and not (ssCtrl in Shift) then Result := Round(V / SnapGrid) * SnapGrid else Result := V;
  end;

begin
  case Mode of
    emModel:
      if (SelShape >= 0) and (Tool in [tMove, tRotate, tScale]) then
      begin
        S := Doc.Shape(SelShape);
        case Tool of
          tMove:
            begin
              if Axis = alFree then
                D := Scene.ScreenDeltaToWorld(FStartPos, X - FDownX, Y - FDownY)
              else
              begin
                // along the axis: the mouse movement measured along the axis' screen direction
                AxisV := AxisVec;
                P0 := Scene.Project(FStartPos);
                P1 := Scene.Project(VAdd(FStartPos, AxisV));
                Ms := P1 - P0;
                T := ((X - FDownX) * Ms.X + (Y - FDownY) * Ms.Y) / Max(1, Ms.X * Ms.X + Ms.Y * Ms.Y);
                D := VMul(AxisV, T);
              end;
              S.Pos := V3(Snap(FStartPos.X + D.X), Snap(FStartPos.Y + D.Y), Snap(FStartPos.Z + D.Z));
            end;
          tRotate:
            begin
              Ang := (X - FDownX) * 0.5;
              if ssShift in Shift then Ang := Round(Ang / 15) * 15;
              S.Rot := FStartRot;
              case Axis of
                alX: S.Rot.X := FStartRot.X + Ang;
                alZ: S.Rot.Z := FStartRot.Z + Ang;
              else
                S.Rot.Y := FStartRot.Y + Ang;
              end;
            end;
          tScale:
            begin
              F := Exp(-(Y - FDownY) * 0.01);
              S.Scale := FStartScale;
              case Axis of
                alX: S.Scale.X := Max(0.01, FStartScale.X * F);
                alY: S.Scale.Y := Max(0.01, FStartScale.Y * F);
                alZ: S.Scale.Z := Max(0.01, FStartScale.Z * F);
              else
                S.Scale := VMul(FStartScale, F);
              end;
            end;
        end;
      end;
    emAnnot:
      if (Tool = tSelect) and (SelAnnot >= 0) then
        with Doc.Annot(SelAnnot) do
          case Kind of
            akDimension: Offset := VAdd(FStartOff, Scene.ScreenDeltaToWorld(VAdd(FStartA, FStartOff), X - FDownX, Y - FDownY));
            akLabel: A := VAdd(FStartA, Scene.ScreenDeltaToWorld(FStartA, X - FDownX, Y - FDownY));
            akCallout:
              begin
                DX := FStartDX + X - FDownX;
                DY := FStartDY + Y - FDownY;
              end;
          end;
    emSketch:
      case Tool of
        tPencil, tHatch:
          if (Length(FCurPts) > 0) and (PtDist(FCurPts[High(FCurPts)], PointF(X, Y)) >= 2) then
          begin
            SetLength(FCurPts, Length(FCurPts) + 1);
            FCurPts[High(FCurPts)] := PointF(X, Y);
          end;
        tLine, tEllipse:
          if Length(FCurPts) > 0 then
          begin
            SetLength(FCurPts, 2);
            FCurPts[1] := PointF(X, Y);
            if Tool = tLine then FCurPts[1] := SnapLineEnd(FCurPts[0], FCurPts[1]);
          end;
        tEraser:
          EraseAt(X, Y);
        tGuide:
          if FDragVP = 1 then Doc.VP1 := PointF(X, Y)
          else if FDragVP = 2 then Doc.VP2 := PointF(X, Y);
      end;
  end;
end;

procedure TEditorForm.ToolUp(X, Y: integer; Shift: TShiftState);
begin
  case Mode of
    emModel:
      if Doc.ToJSONString <> FBefore then Commit(Format('%s %s', [ToolNames[Tool],
        Doc.Shape(SelShape).Name]));
    emAnnot:
      if (Tool = tSelect) and (Doc.ToJSONString <> FBefore) then Commit('move annotation');
    emSketch:
      case Tool of
        tPencil, tLine, tEllipse, tHatch: FinishStroke;
        tEraser, tGuide: if Doc.ToJSONString <> FBefore then Commit(ToolNames[Tool]);
      end;
  end;
end;

// Ruled lines: snap to the direction of a vanishing point, or vertical, within 10 degrees.
function TEditorForm.SnapLineEnd(const A, B: TPointF): TPointF;
var
  Dirs: array[0..2] of TPointF;
  D, U: TPointF;
  L, Best, C, T: single;
  i, k: integer;
begin
  Result := B;
  if not (SnapPersp and Scene.ShowGuides) then Exit;
  D := B - A;
  L := Sqrt(D.X * D.X + D.Y * D.Y);
  if L < 5 then Exit;
  Dirs[0] := Doc.VP1 - A;
  Dirs[1] := Doc.VP2 - A;
  Dirs[2] := PointF(0, 1);
  Best := Cos(DegToRad(10));
  k := -1;
  for i := 0 to 2 do
  begin
    U := Dirs[i] * (1 / Max(1e-6, Sqrt(Dirs[i].X * Dirs[i].X + Dirs[i].Y * Dirs[i].Y)));
    C := Abs(U.X * D.X + U.Y * D.Y) / L;
    if C > Best then
    begin
      Best := C;
      k := i;
    end;
  end;
  if k < 0 then Exit;
  U := Dirs[k] * (1 / Max(1e-6, Sqrt(Dirs[k].X * Dirs[k].X + Dirs[k].Y * Dirs[k].Y)));
  T := U.X * D.X + U.Y * D.Y;
  Result := A + U * T;
end;

procedure TEditorForm.FinishStroke;
var
  St: TStroke;
  i, n, k: integer;
  C, R: TPointF;
  Spacing, Ang, Lo, Hi, P, Q, T: single;
  Xs: array of single;
  Pass: integer;
  Dir, Nrm, A, B: TPointF;
begin
  if Length(FCurPts) < 2 then
  begin
    SetLength(FCurPts, 0);
    Exit;
  end;
  St := TStroke.Create(stLine);
  St.Width := PenWidth;
  St.Ink := PenInk;
  case Tool of
    tPencil:
      St.Pts := Copy(FCurPts);
    tLine:
      begin
        St.Pts := Copy(FCurPts, 0, 2);
        St.Sketchy := RuledSketchy;
      end;
    tEllipse:
      begin
        C := (FCurPts[0] + FCurPts[1]) * 0.5;
        R := PointF(Abs(FCurPts[1].X - FCurPts[0].X) / 2, Abs(FCurPts[1].Y - FCurPts[0].Y) / 2);
        if ssShift in GetKeyShiftState then
        begin
          R.X := Max(R.X, R.Y);
          R.Y := R.X;
        end;
        n := 72;
        SetLength(St.Pts, n + 1);
        for i := 0 to n do
          St.Pts[i] := C + PointF(R.X * Cos(2 * Pi * i / n), R.Y * Sin(2 * Pi * i / n));
      end;
    tHatch:
      begin
        // fill the outline with parallel pencil lines (two directions for the dark level)
        St.Kind := stHatch;
        St.Width := 0.8;
        St.Ink := Min(1, PenInk * 0.8);
        case HatchLevel of
          0: Spacing := 8;
          1: Spacing := 5;
        else
          Spacing := 4;
        end;
        n := 0;
        for Pass := 0 to Ord(HatchLevel >= 2) do
        begin
          if Pass = 0 then Ang := Pi / 4 else Ang := -Pi / 4;
          Dir := PointF(Cos(Ang), Sin(Ang));
          Nrm := PointF(-Dir.Y, Dir.X);
          Lo := 1e9;
          Hi := -1e9;
          for i := 0 to High(FCurPts) do
          begin
            P := FCurPts[i].X * Nrm.X + FCurPts[i].Y * Nrm.Y;
            Lo := Min(Lo, P);
            Hi := Max(Hi, P);
          end;
          P := Lo + Spacing / 2;
          while P < Hi do
          begin
            // crossings of the line {x . Nrm = P} with the outline, by the parameter along Dir
            SetLength(Xs, 0);
            for i := 0 to High(FCurPts) do
            begin
              A := FCurPts[i];
              B := FCurPts[(i + 1) mod Length(FCurPts)];
              Q := A.X * Nrm.X + A.Y * Nrm.Y;
              T := B.X * Nrm.X + B.Y * Nrm.Y;
              if (Q - P) * (T - P) < 0 then
              begin
                C := A + (B - A) * ((P - Q) / (T - Q));
                SetLength(Xs, Length(Xs) + 1);
                Xs[High(Xs)] := C.X * Dir.X + C.Y * Dir.Y;
              end;
            end;
            // sort and pair them up
            for i := 1 to High(Xs) do
            begin
              Q := Xs[i];
              k := i - 1;
              while (k >= 0) and (Xs[k] > Q) do
              begin
                Xs[k + 1] := Xs[k];
                Dec(k);
              end;
              Xs[k + 1] := Q;
            end;
            k := 0;
            while k + 1 <= High(Xs) do
            begin
              SetLength(St.Pts, n + 2);
              St.Pts[n] := Nrm * P + Dir * Xs[k];
              St.Pts[n + 1] := Nrm * P + Dir * Xs[k + 1];
              Inc(n, 2);
              Inc(k, 2);
            end;
            P := P + Spacing;
          end;
        end;
      end;
  end;
  SetLength(FCurPts, 0);
  if Length(St.Pts) < 2 then
  begin
    St.Free;
    Exit;
  end;
  Doc.Layer(Doc.ActiveLayer).Strokes.Add(St);
  Commit(ToolNames[Tool]);
end;

// Rub out: every stroke of the active layer loses the parts within the eraser radius.
procedure TEditorForm.EraseAt(X, Y: single);
var
  L: TSketchLayer;
  i, k, m: integer;
  St, Piece: TStroke;
  C, A, B: TPointF;
  R2: single;
  Dense: array of TPointF;
  Keep: array of boolean;
  NewList: TFPObjectList;
  AnyErased: boolean;

  procedure Densify(const P: array of TPointF; Pairs: boolean);
  var
    j, s, n: integer;
    Len: single;
    Step: integer;
  begin
    SetLength(Dense, 0);
    if Pairs then Step := 2 else Step := 1;
    j := 0;
    while j < High(P) do
    begin
      A := P[j];
      B := P[j + 1];
      Len := PtDist(A, B);
      n := Max(1, Ceil(Len / 3));
      for s := 0 to n - 1 do
      begin
        SetLength(Dense, Length(Dense) + 1);
        Dense[High(Dense)] := A + (B - A) * (s / n);
      end;
      if Pairs then
      begin
        // end of a hatch segment, then a break marker
        SetLength(Dense, Length(Dense) + 2);
        Dense[High(Dense) - 1] := B;
        Dense[High(Dense)] := PointF(NaN, NaN);
      end;
      Inc(j, Step);
    end;
    if not Pairs then
    begin
      SetLength(Dense, Length(Dense) + 1);
      Dense[High(Dense)] := P[High(P)];
    end;
  end;

  procedure Emit(First, Last: integer);
  var
    j: integer;
  begin
    if Last - First < 1 then Exit;
    if St.Kind = stHatch then
    begin
      // hatching stays one stroke: the kept piece is appended as one more segment
      if Piece = nil then
      begin
        Piece := TStroke.Create(stHatch);
        Piece.Width := St.Width;
        Piece.Ink := St.Ink;
        NewList.Add(Piece);
      end;
      SetLength(Piece.Pts, Length(Piece.Pts) + 2);
      Piece.Pts[High(Piece.Pts) - 1] := Dense[First];
      Piece.Pts[High(Piece.Pts)] := Dense[Last];
      Exit;
    end;
    Piece := TStroke.Create(St.Kind);
    Piece.Width := St.Width;
    Piece.Ink := St.Ink;
    Piece.Sketchy := St.Sketchy;
    if False then
    begin
    end
    else
    begin
      SetLength(Piece.Pts, Last - First + 1);
      for j := First to Last do Piece.Pts[j - First] := Dense[j];
    end;
    NewList.Add(Piece);
  end;

begin
  L := Doc.Layer(Doc.ActiveLayer);
  C := PointF(X, Y);
  R2 := Sqr(EraserRadius);
  NewList := TFPObjectList.Create(False);
  try
    AnyErased := False;
    for i := 0 to L.StrokeCount - 1 do
    begin
      St := L.Stroke(i);
      // quick reject: nothing within reach
      k := 0;
      for m := 0 to High(St.Pts) do
        if Sqr(St.Pts[m].X - X) + Sqr(St.Pts[m].Y - Y) < R2 + Sqr(400) then k := 1;
      Densify(St.Pts, St.Kind = stHatch);
      SetLength(Keep, Length(Dense));
      m := 0;
      for k := 0 to High(Dense) do
      begin
        Keep[k] := IsNan(Dense[k].X) or (Sqr(Dense[k].X - X) + Sqr(Dense[k].Y - Y) > R2);
        if not Keep[k] then Inc(m);
      end;
      if m = 0 then
      begin
        NewList.Add(St.Clone);
        Continue;
      end;
      AnyErased := True;
      // runs of kept points become new strokes (one stroke for what is left of a hatching)
      Piece := nil;
      k := 0;
      while k <= High(Dense) do
      begin
        while (k <= High(Dense)) and (not Keep[k] or IsNan(Dense[k].X)) do Inc(k);
        m := k;
        while (m + 1 <= High(Dense)) and Keep[m + 1] and not IsNan(Dense[m + 1].X) do Inc(m);
        if k <= High(Dense) then Emit(k, m);
        k := m + 1;
      end;
    end;
    if AnyErased then
    begin
      L.Strokes.Clear;
      for i := 0 to NewList.Count - 1 do L.Strokes.Add(NewList[i]);
    end
    else
      for i := 0 to NewList.Count - 1 do NewList[i].Free;
  finally
    NewList.Free;
  end;
end;

{ ------------------------------------------------------------ text }

function TEditorForm.TextSprite(const S: string; Size: integer; Bold: boolean; C: TBGRAPixel): TBGRABitmap;
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

function TEditorForm.Txt(X, Y: single; const S: string; Size: integer; Bold: boolean; C: TBGRAPixel;
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
  if C.alpha > 0 then Pool.AddSprite(Round(X), Round(Y), Sp, C.alpha);
end;

{ ------------------------------------------------------------ frame }

procedure TEditorForm.DrawLabels;
var
  i: integer;
  L: TEdLabel;
  C: TBGRAPixel;
  Sp: TBGRABitmap;
  X, Y, W, H: single;
begin
  for i := 0 to Scene.LabelCount - 1 do
  begin
    L := Scene.Labels[i];
    if L.Highlight then C := SelC else C := Ink;
    case L.Kind of
      elDim:
        begin
          Sp := TextSprite(L.Text, 13, False, C);
          W := Sp.Width;
          H := Sp.Height;
          Pool.AddFill(L.X - W / 2 - 5, L.Y - H / 2 - 1, L.X + W / 2 + 5, L.Y + H / 2 + 1, BGRA(246, 244, 236, 235));
          Pool.AddRect(L.X - W / 2 - 5, L.Y - H / 2 - 1, L.X + W / 2 + 5, L.Y + H / 2 + 1, BGRA(46, 52, 66, 170), 0.8);
          Txt(L.X, L.Y - H / 2, L.Text, 13, False, C, taCenter);
        end;
      elLabel:
        Txt(L.X, L.Y - 8, L.Text, 12, False, C);
    else
      begin
        Sp := TextSprite(L.Text, 12, False, C);
        W := Sp.Width;
        H := Sp.Height;
        if L.Align = taLeftJustify then X := L.X else X := L.X - W;
        Y := L.Y - H / 2;
        Pool.AddFill(X - 3, Y, X + W + 3, Y + H, BGRA(246, 244, 236, 225));
        Pool.AddRect(X - 3, Y, X + W + 3, Y + H, C, 0.9);
        Txt(X, Y, L.Text, 12, False, C);
      end;
    end;
  end;
end;

procedure TEditorForm.DashedRect(const B: TRectF; C: TBGRAPixel);

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
      Pool.AddLine(X0 + DX * T / L, Y0 + DY * T / L, X0 + DX * Min(L, T + 5) / L, Y0 + DY * Min(L, T + 5) / L, C, 1);
      T := T + 9;
    end;
  end;

begin
  if B.Right < B.Left then Exit;
  Dashed(B.Left - 6, B.Top - 6, B.Right + 6, B.Top - 6);
  Dashed(B.Right + 6, B.Top - 6, B.Right + 6, B.Bottom + 6);
  Dashed(B.Right + 6, B.Bottom + 6, B.Left - 6, B.Bottom + 6);
  Dashed(B.Left - 6, B.Bottom + 6, B.Left - 6, B.Top - 6);
end;

// Editing aids drawn on top: selection, gizmo, tool previews, guides' handles.
procedure TEditorForm.DrawOverlay;
var
  S: TShape;
  O, P: TPointF;
  i, Sh: integer;
  Hit: TVec3;
  Cols: array[0..2] of TBGRAPixel;
  Ax: array[0..2] of TVec3;
  W: single;
  C: TBGRAPixel;
  R: TPointF;
begin
  // hover and selection boxes
  if (HoverShape >= 0) and (HoverShape <> SelShape) and (HoverShape <= High(Scene.ShapeBoxes)) and (Mode = emModel) then
    DashedRect(Scene.ShapeBoxes[HoverShape].Box, HoverC);
  if (HoverAnnot >= 0) and (HoverAnnot <= High(Scene.AnnotBoxes)) and (Mode = emAnnot) then
    DashedRect(Scene.AnnotBoxes[HoverAnnot].Box, HoverC);
  if (Mode = emModel) and (SelShape >= 0) and (SelShape <= High(Scene.ShapeBoxes)) then
  begin
    DashedRect(Scene.ShapeBoxes[SelShape].Box, SelC);
    // gizmo: the world axes through the shape's position
    S := Doc.Shape(SelShape);
    Cols[0] := BGRA(210, 50, 50, 230);
    Cols[1] := BGRA(40, 160, 60, 230);
    Cols[2] := BGRA(40, 90, 220, 230);
    Ax[0] := V3(1, 0, 0);
    Ax[1] := V3(0, 1, 0);
    Ax[2] := V3(0, 0, 1);
    O := Scene.Project(S.Pos);
    for i := 0 to 2 do
    begin
      P := Scene.Project(VAdd(S.Pos, VMul(Ax[i], Scene.Dist * 0.06)));
      if Ord(Axis) = i + 1 then W := 3 else W := 1.6;
      Pool.AddLine(O.X, O.Y, P.X, P.Y, Cols[i], W);
      Txt(P.X + 3, P.Y - 8, Chr(Ord('X') + i), 11, True, Cols[i]);
    end;
    Pool.AddFill(O.X - 3, O.Y - 3, O.X + 3, O.Y + 3, SelC);
  end;
  if (Mode = emAnnot) and (SelAnnot >= 0) and (SelAnnot <= High(Scene.AnnotBoxes)) then
  begin
    DashedRect(Scene.AnnotBoxes[SelAnnot].Box, SelC);
    if SelAnnot <= High(Scene.AnnotHandles) then
    begin
      P := Scene.AnnotHandles[SelAnnot];
      Pool.AddRect(P.X - 4, P.Y - 4, P.X + 4, P.Y + 4, SelC, 1.4);
    end;
  end;
  // annotation tools: the snapped point under the mouse, and the first point of a dimension
  if (Mode = emAnnot) and (Tool in [tAddDim, tAddLabel, tAddCallout]) then
  begin
    if Scene.PickPoint(FMouseX, FMouseY, Hit, Sh) then
    begin
      P := Scene.Project(Hit);
      Pool.AddRect(P.X - 5, P.Y - 5, P.X + 5, P.Y + 5, SelC, 1.2);
      if FDimFirst then
      begin
        O := Scene.Project(FDimA);
        Pool.AddLine(O.X, O.Y, P.X, P.Y, SelC, 1);
        Txt((O.X + P.X) / 2 + 6, (O.Y + P.Y) / 2 - 16, FormatFloat('0.#', VLen(VSub(Hit, FDimA)) * 10) + ' mm', 11, False, SelC);
      end;
    end;
    if FDimFirst then
    begin
      O := Scene.Project(FDimA);
      Pool.AddFill(O.X - 3, O.Y - 3, O.X + 3, O.Y + 3, SelC);
    end;
  end;
  // sketch previews
  if Mode = emSketch then
  begin
    C := BGRA(28, 28, 36, Round(255 * PenInk));
    case Tool of
      tPencil, tHatch:
        begin
          for i := 0 to High(FCurPts) - 1 do
            Pool.AddLine(FCurPts[i].X, FCurPts[i].Y, FCurPts[i + 1].X, FCurPts[i + 1].Y, C, PenWidth);
          if (Tool = tHatch) and (Length(FCurPts) > 2) then
            Pool.AddLine(FCurPts[High(FCurPts)].X, FCurPts[High(FCurPts)].Y, FCurPts[0].X, FCurPts[0].Y, HoverC, 1);
        end;
      tLine:
        if Length(FCurPts) = 2 then Pool.AddLine(FCurPts[0].X, FCurPts[0].Y, FCurPts[1].X, FCurPts[1].Y, C, PenWidth);
      tEllipse:
        if Length(FCurPts) = 2 then
        begin
          O := (FCurPts[0] + FCurPts[1]) * 0.5;
          R := PointF(Abs(FCurPts[1].X - FCurPts[0].X) / 2, Abs(FCurPts[1].Y - FCurPts[0].Y) / 2);
          for i := 0 to 47 do
            Pool.AddLine(O.X + R.X * Cos(2 * Pi * i / 48), O.Y + R.Y * Sin(2 * Pi * i / 48),
              O.X + R.X * Cos(2 * Pi * (i + 1) / 48), O.Y + R.Y * Sin(2 * Pi * (i + 1) / 48), C, PenWidth);
        end;
      tEraser:
        for i := 0 to 31 do
          Pool.AddLine(FMouseX + EraserRadius * Cos(2 * Pi * i / 32), FMouseY + EraserRadius * Sin(2 * Pi * i / 32),
            FMouseX + EraserRadius * Cos(2 * Pi * (i + 1) / 32), FMouseY + EraserRadius * Sin(2 * Pi * (i + 1) / 32),
            HoverC, 1);
    end;
    if Scene.ShowGuides then
      for i := 1 to 2 do
      begin
        if i = 1 then P := Doc.VP1 else P := Doc.VP2;
        Pool.AddRect(P.X - 7, P.Y - 7, P.X + 7, P.Y + 7, BGRA(60, 110, 200, 220), 1.5);
        Txt(P.X + 10, P.Y - 18, 'VP' + IntToStr(i), 11, True, BGRA(60, 110, 200, 220));
      end;
    // the active layer, top left
    Txt(12, 10, 'Layer: ' + Doc.Layer(Doc.ActiveLayer).Name, 12, True, Ink);
  end;
end;

// Build and rasterise into Target. Clean: no editing aids (for exports).
procedure TEditorForm.RenderTo(Target: TBGRABitmap; W, H: integer; Clean: boolean);
var
  SS, SA: integer;
  G: boolean;
begin
  if (Paper.Width <> W) or (Paper.Height <> H) then
  begin
    Paper.SetSize(W, H);
    Pool.BuildPaper(Paper);
  end;
  if (Target.Width <> W) or (Target.Height <> H) then Target.SetSize(W, H);
  SS := Scene.SelShape;
  SA := Scene.SelAnnot;
  G := Scene.ShowGuides;
  if Clean then
  begin
    Scene.SelShape := -1;
    Scene.SelAnnot := -1;
    Scene.ShowGuides := False;
  end
  else
  begin
    if Mode = emModel then Scene.SelShape := SelShape else Scene.SelShape := -1;
    if Mode = emAnnot then Scene.SelAnnot := SelAnnot else Scene.SelAnnot := -1;
    Scene.ShowGuides := G and (Mode = emSketch);
  end;
  Scene.Build(Doc, W, H);
  DrawLabels;
  if not Clean then DrawOverlay;
  Pool.RenderFrame(Target, Paper, Scene, 0);
  if Clean then
  begin
    Scene.SelShape := SS;
    Scene.SelAnnot := SA;
  end;
  Scene.ShowGuides := G;
end;

procedure TEditorForm.DoFrame;
var
  T0: double;
  W, H: integer;
begin
  T0 := NowMs;
  W := Max(64, FOutput.Width);
  H := Max(64, FOutput.Height);
  RenderTo(Frame, W, H, False);
  FCpuMs := FCpuMs * 0.9 + (NowMs - T0) * 0.1;
  if FUseGL then
    try
      PresentGL;
    except
      on E: Exception do
      begin
        FUseGL := False;
        FGL.Visible := False;
        FView.Visible := True;
        FOutput := FView;
        Log('gl', 'falling back to GDI: ' + E.Message);
      end;
    end
  else
    FView.Repaint;
  if ParamStr(1) = '--selftest' then SelfTestStep;
  Inc(FFrames);
  if T0 - FFpsTime >= 500 then
  begin
    FFps := FFrames * 1000 / (T0 - FFpsTime);
    FFrames := 0;
    FFpsTime := T0;
  end;
end;

procedure TEditorForm.AppIdle(Sender: TObject; var Done: boolean);
var
  T: double;
begin
  Done := False;
  if WindowState = wsMinimized then
  begin
    Sleep(10);
    Exit;
  end;
  // vsync paces the loop while SwapBuffers really waits; with the display asleep,
  // the session locked or no OpenGL, a 60 Hz timer grid does (FSwapMs keeps measuring)
  if FUseGL and FVSyncSupported and (FSwapMs > 3.5) then
  begin
    DoFrame;
    FNextFrame := NowMs;
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

procedure TEditorForm.PresentGL;
const
  GL_BGRA = $80E1;
  GL_CLAMP_TO_EDGE = $812F;
var
  V0, V1, T: double;
begin
  if not FGL.MakeCurrent then raise Exception.Create('cannot make the OpenGL context current');
  if not FGLReady then
  begin
    glGenTextures(1, @FTexture);
    glBindTexture(GL_TEXTURE_2D, FTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    FTexW := 0;
    FGLReady := True;
  end;
  {$IFDEF WINDOWS}
  // The control may get a new GL context after start-up (the window being laid
  // out and shown), and a new context starts with the driver's default interval.
  // So the interval is checked on the current context, cheaply, every frame.
  if not FVSyncApplied then
  begin
    Pointer(FSetInterval) := wglGetProcAddress('wglSwapIntervalEXT');
    Pointer(FGetInterval) := wglGetProcAddress('wglGetSwapIntervalEXT');
    FVSyncSupported := Assigned(FSetInterval);
    FVSyncApplied := True;
  end;
  if FVSyncSupported and (not Assigned(FGetInterval) or (FGetInterval() <> FSwapInterval)) then
  begin
    FSetInterval(FSwapInterval);
    LogFmt('gl', 'swap interval set to %d (context %p)', [FSwapInterval, Pointer(wglGetCurrentContext)]);
    if not Assigned(FGetInterval) then FGetInterval := nil;
  end;
  {$ENDIF}
  glViewport(0, 0, FGL.Width, FGL.Height);
  glBindTexture(GL_TEXTURE_2D, FTexture);
  if (FTexW <> Frame.Width) or (FTexH <> Frame.Height) then
  begin
    FTexW := Frame.Width;
    FTexH := Frame.Height;
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, FTexW, FTexH, 0, GL_BGRA, GL_UNSIGNED_BYTE, Frame.Data);
  end
  else
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, FTexW, FTexH, GL_BGRA, GL_UNSIGNED_BYTE, Frame.Data);
  if Frame.LineOrder = riloBottomToTop then
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
  glFinish;
  FSwapMs := FSwapMs * 0.95 + (NowMs - T) * 0.05;
end;

procedure TEditorForm.GLPaint(Sender: TObject);
begin
  if FUseGL and (Frame.Width > 16) then
    try
      PresentGL;
    except
    end;
end;

procedure TEditorForm.ViewPaint(Sender: TObject);
begin
  Frame.Draw(FView.Canvas, 0, 0, True);
end;

{ ------------------------------------------------------------ export }

procedure TEditorForm.ExportStill;
var
  D: TSaveDialog;
  B: TBGRABitmap;
  L: TFPList;
begin
  if ExportBusy then Exit;
  D := TSaveDialog.Create(Self);
  try
    D.Filter := 'PNG image|*.png|BMP image|*.bmp';
    D.DefaultExt := '.png';
    D.InitialDir := ExportDir;
    D.FileName := Doc.Title + '.png';
    D.Options := D.Options + [ofOverwritePrompt];
    if not D.Execute then Exit;
    B := TBGRABitmap.Create(16, 16);
    RenderTo(B, Frame.Width, Frame.Height, True);
    L := TFPList.Create;
    L.Add(B);
    TExportThread.Create(ekStill, L, D.FileName, 1, nil);
    FStatus.Panels[1].Text := 'Saving ' + D.FileName;
  finally
    D.Free;
  end;
end;

// A full turn around the model, rendered frame by frame (not in real time).
procedure TEditorForm.ExportTurntable(Mp4: boolean);
var
  N, Fps, W, H, i: integer;
  Y0: single;
  B: TBGRABitmap;
  Frames: TFPList;
  Writer: TFfmpegWriter;
  Exe, Path: string;
  Sk: boolean;
begin
  if ExportBusy then Exit;
  if Mp4 then
  begin
    Exe := FindFfmpeg('');
    if Exe = '' then
    begin
      MessageDlg('ffmpeg was not found (PATH, program folder or winget). Use the GIF export instead.',
        mtWarning, [mbOK], 0);
      Exit;
    end;
    Fps := 60;
    N := 240;
    W := Frame.Width and not 1;
    H := Frame.Height and not 1;
    Path := TimeStampName('turntable_', '.mp4');
  end
  else
  begin
    Fps := 20;
    N := 60;
    W := (Frame.Width div 2) and not 1;
    H := (Frame.Height div 2) and not 1;
    Path := TimeStampName('turntable_', '.gif');
  end;
  Writer := nil;
  Frames := nil;
  if Mp4 then Writer := TFfmpegWriter.Create(StartFfmpeg(Exe, Path, W, H, Fps), Path)
  else Frames := TFPList.Create;
  Y0 := Scene.Yaw;
  Sk := Scene.ShowSketch;
  Scene.ShowSketch := False;          // the sketch is drawn on the sheet, it does not turn
  Screen.Cursor := crHourGlass;
  try
    for i := 0 to N - 1 do
    begin
      Scene.Yaw := Y0 + 2 * Pi * i / N;
      B := TBGRABitmap.Create(16, 16);
      RenderTo(B, W, H, True);
      if Mp4 then Writer.Push(B) else Frames.Add(B);
      if i mod 20 = 0 then
      begin
        FStatus.Panels[1].Text := Format('Rendering turntable %d / %d', [i, N]);
        Application.ProcessMessages;
      end;
    end;
  finally
    Screen.Cursor := crDefault;
    Scene.Yaw := Y0;
    Scene.ShowSketch := Sk;
    Paper.SetSize(1, 1);              // back to the window size on the next frame
  end;
  if Mp4 then Writer.Finish
  else TExportThread.Create(ekGif, Frames, Path, Fps, nil);
  FStatus.Panels[1].Text := 'Encoding ' + Path;
  LogFmt('export', 'turntable %d frames %dx%d -> %s', [N, W, H, Path]);
end;

{ ------------------------------------------------------------ self-test }

procedure TEditorForm.AppException(Sender: TObject; E: Exception);
var
  L: TStringList;
begin
  Log('error', E.ClassName + ': ' + E.Message);
  if ParamStr(1) = '--selftest' then
  begin
    // no dialog in a self-test: keep the log and stop
    L := TStringList.Create;
    try
      L.Text := LogTail(200);
      L.SaveToFile(IncludeTrailingPathDelimiter(ParamStr(2)) + 'log.txt');
    finally
      L.Free;
    end;
    Halt(2);
  end
  else
    MessageDlg(E.Message, mtError, [mbOK], 0);
end;

// --selftest <folder>: drive every mode and tool, check save / load, export; then quit.
procedure TEditorForm.SelfTestStep;
var
  Dir: string;
  L: TStringList;
  S1, S2: string;
  Sh: integer;
  Hit: TVec3;
  i: integer;
  P: TPointF;
  M: TEditMode;

  procedure Shot(const Name: string);
  var
    Bmp: TBitmap;
  begin
    Frame.SaveToFile(Dir + Name + '_view.png');
    Bmp := GetFormImage;
    try
      Bmp.SaveToFile(Dir + Name + '_window.bmp');
    finally
      Bmp.Free;
    end;
  end;

  procedure Click(X, Y: integer);
  begin
    VMouseDown(nil, mbLeft, [], X, Y);
    VMouseUp(nil, mbLeft, [], X, Y);
  end;

  procedure DragPath(const Pts: array of TPoint);
  var
    k: integer;
  begin
    VMouseDown(nil, mbLeft, [], Pts[0].X, Pts[0].Y);
    for k := 1 to High(Pts) do VMouseMove(nil, [ssLeft], Pts[k].X, Pts[k].Y);
    VMouseUp(nil, mbLeft, [], Pts[High(Pts)].X, Pts[High(Pts)].Y);
  end;

begin
  Dir := IncludeTrailingPathDelimiter(ParamStr(2));
  if GetTickCount64 < FTestT then Exit;
  FTestT := GetTickCount64 + 400;
  case FTestStep of
    0: ;
    1:
      begin
        Shot('01_model');
        for M := Low(TEditMode) to High(TEditMode) do
        begin
          FModePanel[M].Visible := True;
          FModePanel[M].HandleNeeded;
          for i := 0 to FModePanel[M].ControlCount - 1 do
            with FModePanel[M].Controls[i] do
              LogFmt('ui', '%d %s "%s" x=%d w=%d', [Ord(M), ClassName, Caption, Left, Width]);
          FModePanel[M].Visible := M = Mode;
        end;
        for i := 0 to FTopBar.ControlCount - 1 do
          with FTopBar.Controls[i] do LogFmt('ui', 'top %s "%s" x=%d w=%d', [ClassName, Caption, Left, Width]);
        // select the zoom ring by clicking the middle of its screen box, then move it up
        for i := 0 to Doc.ShapeCount - 1 do
          if Doc.Shape(i).Name = 'Prism hood' then Sh := i;
        with Scene.ShapeBoxes[Sh].Box do Click(Round((Left + Right) / 2), Round((Top + Bottom) / 2));
        LogFmt('test', 'clicked prism hood: selected %d (%s)', [SelShape, Doc.Shape(Max(0, SelShape)).Name]);
        SetTool(tMove);
        SetAxis(alY);
        with Scene.ShapeBoxes[Sh].Box do
          DragPath([Point(Round((Left + Right) / 2), Round((Top + Bottom) / 2)),
            Point(Round((Left + Right) / 2), Round((Top + Bottom) / 2) - 40)]);
        LogFmt('test', 'moved up: y = %.2f', [Doc.Shape(Sh).Pos.Y]);
        HoverShape := Doc.ShapeCount - 1;
      end;
    2:
      begin
        Shot('02_moved');
        Undo;
        LogFmt('test', 'after undo: y = %.2f, undo steps %d', [Doc.Shape(SelShape).Pos.Y, FUndo.Count]);
        Redo;
        Undo;
        HoverShape := -1;
        AddShapeClick(TObject(FAddBtns[1]));
        LogFmt('test', 'added %s, %d shapes', [Doc.Shape(SelShape).Name, Doc.ShapeCount]);
        Doc.Shape(SelShape).Pos := V3(-12, 0, 0);
        Doc.Shape(SelShape).Ribbed := True;
        Doc.Shape(SelShape).Mat := mtKnurl;
        SetTool(tRotate);
        SetAxis(alZ);
        DragPath([Point(100, 100), Point(160, 100)]);
        LogFmt('test', 'rotated: z = %.1f deg', [Doc.Shape(SelShape).Rot.Z]);
        RefreshProps(True);
      end;
    3:
      begin
        Shot('03_added');
        Scene.Wire := True;
      end;
    4:
      begin
        Shot('04_xray');
        Scene.Wire := False;
        SetMode(emAnnot);
        SetTool(tAddDim);
        // two corners of the bottom plate, found by picking near its box corners
        for i := 0 to Doc.ShapeCount - 1 do
          if Doc.Shape(i).Name = 'Bottom plate' then Sh := i;
        // two points on the right side of the body, then a callout on the shutter dial
        P := Scene.Project(V3(6.9, 1.5, 1.2));
        Click(Round(P.X), Round(P.Y));
        P := Scene.Project(V3(6.9, -2.5, -1.2));
        Click(Round(P.X), Round(P.Y));
        LogFmt('test', 'dimension: %d annotations, last %s', [Doc.AnnotCount, Doc.Annot(Doc.AnnotCount - 1).Caption]);
        SetTool(tAddCallout);
        P := Scene.Project(V3(4.6, 5.62, 0.9));
        Click(Round(P.X), Round(P.Y));
        LogFmt('test', 'callout: %d annotations, last %s', [Doc.AnnotCount, Doc.Annot(Doc.AnnotCount - 1).Caption]);
        SetTool(tAddLabel);
        P := Scene.Project(V3(-2.0, 7.4, 0.0));
        Click(Round(P.X), Round(P.Y));
        LogFmt('test', 'label: %d annotations, last %s', [Doc.AnnotCount, Doc.Annot(Doc.AnnotCount - 1).Caption]);
        SetTool(tSelect);
      end;
    5:
      begin
        // drag the new callout's label (its grab point comes from the frame just drawn)
        P := Scene.AnnotHandles[Doc.AnnotCount - 2];
        DragPath([Point(Round(P.X), Round(P.Y)), Point(Round(P.X) + 40, Round(P.Y) - 30)]);
        LogFmt('test', 'callout dragged: selected %d, dx %.0f dy %.0f', [SelAnnot, Doc.Annot(Doc.AnnotCount - 2).DX,
          Doc.Annot(Doc.AnnotCount - 2).DY]);
        Shot('05_annotate');
        SetMode(emSketch);
        Scene.ShowGuides := True;
        SetTool(tLine);
        DragPath([Point(200, 600), Point(500, 560)]);
        DragPath([Point(200, 600), Point(200, 420)]);
        SetTool(tPencil);
        DragPath([Point(600, 600), Point(640, 580), Point(690, 600), Point(740, 570), Point(800, 610)]);
        SetTool(tEllipse);
        DragPath([Point(850, 520), Point(1000, 600)]);
        HatchLevel := 2;
        SetTool(tHatch);
        DragPath([Point(250, 650), Point(450, 640), Point(470, 720), Point(260, 730), Point(250, 650)]);
        SetTool(tEraser);
        DragPath([Point(330, 640), Point(340, 700)]);
        LogFmt('test', 'sketch: %d strokes on "%s"', [Doc.Layer(Doc.ActiveLayer).StrokeCount, Doc.Layer(Doc.ActiveLayer).Name]);
      end;
    6:
      begin
        Shot('06_sketch');
        // save, load, compare
        Doc.SaveToFile(Dir + 'test.sketch.json');
        S1 := Doc.ToJSONString;
        Doc.LoadFromFile(Dir + 'test.sketch.json');
        S2 := Doc.ToJSONString;
        LogFmt('test', 'save/load round trip: %s (%d bytes)', [BoolToStr(S1 = S2, 'identical', 'DIFFERENT'), Length(S1)]);
        if Scene.PickPoint(Frame.Width div 2, Frame.Height div 2, Hit, Sh) then
          LogFmt('test', 'pick at centre: shape %d at %.2f %.2f %.2f', [Sh, Hit.X, Hit.Y, Hit.Z]);
        ExportTurntable(False);
      end;
    7..30:
      if not ExportBusy then
      begin
        LogFmt('test', 'frame rate %.1f fps, %.2f ms per frame, swap %.2f ms, %d prims', [FFps, FCpuMs, FSwapMs, Scene.PrimCount]);
        LogFmt('test', 'export: %s', [ExportStatus]);
        L := TStringList.Create;
        try
          L.Text := LogTail(200);
          L.SaveToFile(Dir + 'log.txt');
        finally
          L.Free;
        end;
        Modified := False;
        Application.Terminate;
        FTestStep := 100;
      end;
  end;
  if FTestStep < 100 then Inc(FTestStep);
end;

end.
