unit URenderPool;

{ Rasterises the whole frame (scene and HUD) on every logical CPU.

  The frame is cut into horizontal bands of BandH (16) rows. One worker
  thread per core takes the next free band (interlocked counter), copies the
  paper rows into its own W x 16 bitmap, draws every prim and overlay item
  that touches the band and copies the rows back into the frame. Bands never
  overlap, so no locks are needed while drawing. Small bands keep the cores
  evenly busy: the camera fills only the middle of the sheet.

  The hot paths do not go through BGRABitmap's general drawing routines
  (they allocate on every call, and the threads then queue on the heap):
    PencilLine    antialiased stroke with round caps and graphite grain
    FillTextured  scanline polygon fill with a 64 x 64 hatch texture
    FillSolidAA   4x supersampled polygon fill with alpha
    BlendRect / BlendSprite for the HUD
  The texture row is chosen from the absolute frame row, so the hatching
  continues across bands.

  The pool also builds the paper background (grain, blotches, vignette)
  band by band when the window is resized. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, Math, Graphics, BGRABitmap, BGRABitmapTypes, USketchScene;

const
  BandH = 16;
  TexSize = TileH;                   // 64, hatch texture size

type
  TRenderPool = class;

  TJobKind = (jkFrame, jkPaper);

  TOverlayKind = (okFill, okLine, okSprite);

  TOverlay = record
    Kind: TOverlayKind;
    X0, Y0, X1, Y1, W: single;
    C: TBGRAPixel;
    Sprite: TBGRABitmap;
  end;

  { TRenderWorker }

  TRenderWorker = class(TThread)
  private
    FPool: TRenderPool;
    FStart, FDone: PRTLEvent;
    FBand: TBGRABitmap;
    FDecal: array[0..DecalCount - 1] of TBGRABitmap;
    FTmp: array[1..128] of array of TPointF;   // scratch polygons by point count, no allocation per prim
    FCov: array of integer;                    // coverage row for FillSolidAA
    FBands: integer;
    FBusyMs: double;                           // time spent drawing in the last job
    FRows: array[0..BandH - 1] of PBGRAPixel;  // band row pointers
    FBandW, FBandRows, FBandY0: integer;
    procedure PencilLine(X1, Y1, X2, Y2: single; C: TBGRAPixel; W: single);
    procedure FillTextured(const T: array of TPointF; n, Tex: integer);
    procedure FillSolidAA(const T: array of TPointF; n: integer; C: TBGRAPixel);
    procedure BlendRect(X0, Y0, X1, Y1: single; C: TBGRAPixel);
    procedure BlendSprite(X, Y: integer; S: TBGRABitmap; Opacity: integer);
    procedure FrameTile(Tile: integer);
    procedure PaperTile(Tile: integer);
    procedure DrawPrim(P: PPrim; dy: single);
    procedure Stroke(X1, Y1, X2, Y2: single; C: TBGRAPixel; W, Reveal: single; Sketchy: boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TRenderPool);
    destructor Destroy; override;
  end;

  { TRenderPool }

  TRenderPool = class
  private
    FWorkers: array of TRenderWorker;
    FNextTile: longint;
    FTiles: integer;
    FJob: TJobKind;
    FFrame, FPaper: TBGRABitmap;
    FScene: TCameraScene;
    FFlash: single;
    FTex: array[0..TexCount - 1] of TBGRABitmap;
    FTexRows: array[0..TexCount - 1, 0..TexSize - 1] of PBGRAPixel;   // read only, shared
    FDecal: array[0..DecalCount - 1] of TBGRABitmap;
    FOverlay: array of TOverlay;
    FOverlayCount, FLastOverlay: integer;
    procedure Run(AJob: TJobKind; ATiles: integer);
    procedure MakeTextures;
    function GetThreadCount: integer;
    function NewOverlay(AKind: TOverlayKind): integer;
  public
    constructor Create(AThreads: integer);
    destructor Destroy; override;
    procedure RenderFrame(AFrame, APaper: TBGRABitmap; AScene: TCameraScene; AFlash: single);
    procedure BuildPaper(APaper: TBGRABitmap);
    // HUD items, drawn by the workers on top of the scene; cleared after each frame
    procedure AddFill(X0, Y0, X1, Y1: single; C: TBGRAPixel);
    procedure AddLine(X0, Y0, X1, Y1: single; C: TBGRAPixel; W: single);
    procedure AddRect(X0, Y0, X1, Y1: single; C: TBGRAPixel; W: single);
    procedure AddSprite(X, Y: integer; S: TBGRABitmap; Opacity: byte);
    property ThreadCount: integer read GetThreadCount;
    function WorkerBands(i: integer): integer;
    function WorkerBusyMs(i: integer): double;
    function OverlayCount: integer;
  public
    PlainPaper: boolean;             // layer "Paper texture" off
  end;

const
  PaperR = 243;
  PaperG = 240;
  PaperB = 231;

function Hash2(X, Y: longint): cardinal; inline;

implementation

function Hash2(X, Y: longint): cardinal;
var
  H: cardinal;
begin
  H := cardinal(X) * 374761393 + cardinal(Y) * 668265263;
  H := (H xor (H shr 13)) * 1274126177;
  Result := H xor (H shr 16);
end;

function ValueNoise(X, Y: single): single;
var
  ix, iy: integer;
  fx, fy, a, b, c, d: single;
begin
  ix := Floor(X);
  iy := Floor(Y);
  fx := X - ix;
  fy := Y - iy;
  fx := fx * fx * (3 - 2 * fx);
  fy := fy * fy * (3 - 2 * fy);
  a := (Hash2(ix, iy) and $FFFF) / 65535;
  b := (Hash2(ix + 1, iy) and $FFFF) / 65535;
  c := (Hash2(ix, iy + 1) and $FFFF) / 65535;
  d := (Hash2(ix + 1, iy + 1) and $FFFF) / 65535;
  Result := (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
end;

function TickMs: double;
{$IFDEF WINDOWS}
var
  C, F: int64;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := double(C) * 1000 / F;     // not C * 1000.0: that is computed in single precision
  {$ELSE}
  Result := GetTickCount64;
  {$ENDIF}
end;

procedure BlendPixel(Px: PBGRAPixel; const C: TBGRAPixel; A: integer); inline;
var
  IA: integer;
begin
  IA := 256 - A;
  Px^.red := (Px^.red * IA + C.red * A) shr 8;
  Px^.green := (Px^.green * IA + C.green * A) shr 8;
  Px^.blue := (Px^.blue * IA + C.blue * A) shr 8;
end;

{ TRenderWorker }

constructor TRenderWorker.Create(APool: TRenderPool);
var
  i: integer;
begin
  FPool := APool;
  FStart := RTLEventCreate;
  FDone := RTLEventCreate;
  FBand := TBGRABitmap.Create(16, BandH);
  // the decal is used through BGRABitmap's texture mapper, which keeps state in the bitmap
  for i := 0 to DecalCount - 1 do FDecal[i] := APool.FDecal[i].Duplicate as TBGRABitmap;
  for i := 1 to High(FTmp) do SetLength(FTmp[i], i);
  inherited Create(False);
end;

destructor TRenderWorker.Destroy;
var
  i: integer;
begin
  RTLEventDestroy(FStart);
  RTLEventDestroy(FDone);
  FBand.Free;
  for i := 0 to DecalCount - 1 do FDecal[i].Free;
  inherited Destroy;
end;

procedure TRenderWorker.Execute;
var
  Tile: integer;
  T0: double;
begin
  while True do
  begin
    RTLEventWaitFor(FStart);
    if Terminated then Break;
    FBands := 0;
    T0 := TickMs;
    repeat
      Tile := InterlockedIncrement(FPool.FNextTile) - 1;
      if Tile >= FPool.FTiles then Break;
      try
        if FPool.FJob = jkFrame then FrameTile(Tile) else PaperTile(Tile);
      except
        // a failed band stays as paper; never let an exception kill the worker
      end;
      Inc(FBands);
    until False;
    FBusyMs := TickMs - T0;
    RTLEventSetEvent(FDone);
  end;
end;

// Antialiased pencil stroke straight into the band rows: for each row only the
// few pixels near the line are visited, coverage comes from the distance to the
// segment (round caps), and a per-pixel grain makes it look like graphite.
procedure TRenderWorker.PencilLine(X1, Y1, X2, Y2: single; C: TBGRAPixel; W: single);
var
  DX, DY, Len, Len2, InvLen2, R1, Op, XA, XB, XC, HW, MinX, MaxX: single;
  T, QX, QY, D, Cov: single;
  y, x, ya, yb, xs, xe, a: integer;
  Px: PBGRAPixel;
begin
  Op := C.alpha;
  if W < 1 then
  begin
    Op := Op * W;                    // thin lines: 1 px wide, lighter
    W := 1;
  end;
  R1 := W * 0.5 + 0.5;
  ya := Max(0, Ceil(Min(Y1, Y2) - R1));
  yb := Min(FBandRows - 1, Floor(Max(Y1, Y2) + R1));
  if ya > yb then Exit;
  MinX := Max(0, Min(X1, X2) - R1);
  MaxX := Min(FBandW - 1, Max(X1, X2) + R1);
  if MinX > MaxX then Exit;
  DX := X2 - X1;
  DY := Y2 - Y1;
  Len2 := DX * DX + DY * DY;
  Len := Sqrt(Len2);
  if Len2 < 1e-6 then InvLen2 := 0 else InvLen2 := 1 / Len2;
  for y := ya to yb do
  begin
    if Abs(DY) > 1e-3 then
    begin
      XC := X1 + (y - Y1) * DX / DY;
      HW := R1 * Len / Abs(DY) + 1;
      XA := Max(MinX, XC - HW);
      XB := Min(MaxX, XC + HW);
    end
    else
    begin
      XA := MinX;
      XB := MaxX;
    end;
    xs := Ceil(XA);
    xe := Floor(XB);
    if xs > xe then Continue;
    Px := FRows[y] + xs;
    for x := xs to xe do
    begin
      T := ((x - X1) * DX + (y - Y1) * DY) * InvLen2;
      if T < 0 then T := 0 else if T > 1 then T := 1;
      QX := X1 + T * DX - x;
      QY := Y1 + T * DY - y;
      D := Sqrt(QX * QX + QY * QY);
      Cov := R1 - D;
      if Cov > 0 then
      begin
        if Cov > 1 then Cov := 1;
        a := Round(Cov * Op * (0.72 + 0.28 * ((Hash2(x, y + FBandY0) shr 9) and 255) / 255));
        if a > 0 then BlendPixel(Px, C, a);
      end;
      Inc(Px);
    end;
  end;
end;

// Scanline fill with a 64 x 64 hatch texture, even-odd rule, pixel centres at
// integer coordinates. No allocation: crossings go into a fixed buffer.
procedure TRenderWorker.FillTextured(const T: array of TPointF; n, Tex: integer);
var
  Xs: array[0..127] of single;
  Cnt, i, j, k, y, ya, yb, xa, xb, x: integer;
  Y0f, Y1f, MinY, MaxY, V: single;
  Src, Dst: PBGRAPixel;
begin
  MinY := 1e9;
  MaxY := -1e9;
  for i := 0 to n - 1 do
  begin
    if T[i].Y < MinY then MinY := T[i].Y;
    if T[i].Y > MaxY then MaxY := T[i].Y;
  end;
  ya := Max(0, Ceil(MinY));
  yb := Min(FBandRows - 1, Floor(MaxY));
  for y := ya to yb do
  begin
    Cnt := 0;
    j := n - 1;
    for i := 0 to n - 1 do
    begin
      Y0f := T[j].Y;
      Y1f := T[i].Y;
      if (((Y0f <= y) and (Y1f > y)) or ((Y1f <= y) and (Y0f > y))) and (Cnt <= High(Xs)) then
      begin
        V := T[j].X + (y - Y0f) * (T[i].X - T[j].X) / (Y1f - Y0f);
        k := Cnt;                    // insertion sort: only a few crossings
        while (k > 0) and (Xs[k - 1] > V) do
        begin
          Xs[k] := Xs[k - 1];
          Dec(k);
        end;
        Xs[k] := V;
        Inc(Cnt);
      end;
      j := i;
    end;
    Src := FPool.FTexRows[Tex, (y + FBandY0) and (TexSize - 1)];
    k := 0;
    while k + 1 < Cnt do
    begin
      xa := Max(0, Ceil(Xs[k]));
      xb := Min(FBandW - 1, Ceil(Xs[k + 1]) - 1);
      Dst := FRows[y] + xa;
      for x := xa to xb do
      begin
        Dst^ := Src[x and (TexSize - 1)];
        Inc(Dst);
      end;
      Inc(k, 2);
    end;
  end;
end;

// Antialiased solid fill: 4 sub-rows per pixel row, exact horizontal coverage
// at span ends, accumulated in a coverage row (0..1024 per pixel).
procedure TRenderWorker.FillSolidAA(const T: array of TPointF; n: integer; C: TBGRAPixel);
const
  Sub = 4;
var
  Xs: array[0..127] of single;
  Cnt, i, j, k, s, y, ya, yb, x, xa, xb, Lo, Hi: integer;
  Y0f, Y1f, MinY, MaxY, MinX, MaxX, V, SY, L, R: single;
  Px: PBGRAPixel;
  A: integer;
begin
  MinY := 1e9; MaxY := -1e9; MinX := 1e9; MaxX := -1e9;
  for i := 0 to n - 1 do
  begin
    MinY := Min(MinY, T[i].Y); MaxY := Max(MaxY, T[i].Y);
    MinX := Min(MinX, T[i].X); MaxX := Max(MaxX, T[i].X);
  end;
  ya := Max(0, Floor(MinY));
  yb := Min(FBandRows - 1, Ceil(MaxY));
  Lo := Max(0, Floor(MinX) - 1);
  Hi := Min(FBandW - 1, Ceil(MaxX) + 1);
  if (ya > yb) or (Lo > Hi) then Exit;
  if Length(FCov) < FBandW + 2 then SetLength(FCov, FBandW + 2);
  for y := ya to yb do
  begin
    for x := Lo to Hi do FCov[x] := 0;
    for s := 0 to Sub - 1 do
    begin
      SY := y - 0.5 + (s + 0.5) / Sub;
      Cnt := 0;
      j := n - 1;
      for i := 0 to n - 1 do
      begin
        Y0f := T[j].Y;
        Y1f := T[i].Y;
        if (((Y0f <= SY) and (Y1f > SY)) or ((Y1f <= SY) and (Y0f > SY))) and (Cnt <= High(Xs)) then
        begin
          V := T[j].X + (SY - Y0f) * (T[i].X - T[j].X) / (Y1f - Y0f);
          k := Cnt;
          while (k > 0) and (Xs[k - 1] > V) do
          begin
            Xs[k] := Xs[k - 1];
            Dec(k);
          end;
          Xs[k] := V;
          Inc(Cnt);
        end;
        j := i;
      end;
      k := 0;
      while k + 1 < Cnt do
      begin
        // pixel x covers [x - 0.5, x + 0.5)
        L := Max(Lo - 0.5, Xs[k]);
        R := Min(Hi + 0.5, Xs[k + 1]);
        if R > L then
        begin
          xa := Floor(L + 0.5);
          xb := Floor(R + 0.5);
          if xa = xb then
            Inc(FCov[xa], Round((R - L) * 256))
          else
          begin
            Inc(FCov[xa], Round((xa + 0.5 - L) * 256));
            for x := xa + 1 to xb - 1 do Inc(FCov[x], 256);
            if xb <= Hi then Inc(FCov[xb], Round((R - (xb - 0.5)) * 256));
          end;
        end;
        Inc(k, 2);
      end;
    end;
    Px := FRows[y] + Lo;
    for x := Lo to Hi do
    begin
      if FCov[x] > 0 then
      begin
        A := (Min(1024, FCov[x]) * C.alpha) shr 10;
        if A > 0 then BlendPixel(Px, C, A);
      end;
      Inc(Px);
    end;
  end;
end;

procedure TRenderWorker.BlendRect(X0, Y0, X1, Y1: single; C: TBGRAPixel);
var
  xa, xb, ya, yb, x, y: integer;
  Px: PBGRAPixel;
begin
  xa := Max(0, Round(X0));
  xb := Min(FBandW - 1, Round(X1) - 1);
  ya := Max(0, Round(Y0));
  yb := Min(FBandRows - 1, Round(Y1) - 1);
  if C.alpha = 0 then Exit;
  for y := ya to yb do
  begin
    Px := FRows[y] + xa;
    for x := xa to xb do
    begin
      BlendPixel(Px, C, C.alpha);
      Inc(Px);
    end;
  end;
end;

procedure TRenderWorker.BlendSprite(X, Y: integer; S: TBGRABitmap; Opacity: integer);
var
  sy, sx, xa, xb, A: integer;
  Src, Dst: PBGRAPixel;
begin
  xa := Max(0, -X);
  xb := Min(S.Width - 1, FBandW - 1 - X);
  if xa > xb then Exit;
  for sy := Max(0, -Y) to Min(S.Height - 1, FBandRows - 1 - Y) do
  begin
    Src := S.ScanLine[sy] + xa;
    Dst := FRows[Y + sy] + X + xa;
    for sx := xa to xb do
    begin
      A := (Src^.alpha * Opacity) shr 8;
      if A > 0 then BlendPixel(Dst, Src^, A);
      Inc(Src);
      Inc(Dst);
    end;
  end;
end;

procedure TRenderWorker.Stroke(X1, Y1, X2, Y2: single; C: TBGRAPixel; W, Reveal: single; Sketchy: boolean);
var
  DX, DY, L, J1, J2: single;
  H: cardinal;
begin
  if Reveal < 1 then
  begin
    X2 := X1 + (X2 - X1) * Reveal;
    Y2 := Y1 + (Y2 - Y1) * Reveal;
  end;
  if Sketchy then
  begin
    DX := X2 - X1;
    DY := Y2 - Y1;
    L := Sqrt(DX * DX + DY * DY);
    if L > 6 then
    begin
      // pencil overshoot at both ends, more on long edges
      L := Min(6, 1.5 + L * 0.02) / L;
      if Reveal >= 1 then
      begin
        X2 := X2 + DX * L;
        Y2 := Y2 + DY * L;
      end;
      X1 := X1 - DX * L;
      Y1 := Y1 - DY * L;
      PencilLine(X1, Y1, X2, Y2, C, W);
      // second, lighter pass slightly off the first, fixed per edge so it does not shimmer
      H := Hash2(Round(X1 * 0.25) + Round(X2 * 0.25) * 7919, Round(Y1 * 0.25) * 31 + Round(Y2 * 0.25));
      J1 := ((H and 255) / 255 - 0.5) * 1.6;
      J2 := (((H shr 8) and 255) / 255 - 0.5) * 1.6;
      C.alpha := C.alpha * 2 div 5;
      PencilLine(X1 + J1, Y1 + J2, X2 - J2, Y2 + J1, C, W * 0.75);
      Exit;
    end;
  end;
  PencilLine(X1, Y1, X2, Y2, C, W);
end;

procedure TRenderWorker.DrawPrim(P: PPrim; dy: single);
var
  n, i, j: integer;
  T: array of TPointF;
  R: single;
  Dw, Dh: integer;
begin
  R := P^.Reveal;
  if R <= 0 then Exit;
  n := Length(P^.Pts);
  if n > 0 then
  begin
    if n <= High(FTmp) then T := FTmp[n] else SetLength(T, n);
    for i := 0 to n - 1 do
    begin
      T[i].X := P^.Pts[i].X;
      T[i].Y := P^.Pts[i].Y + dy;
    end;
    // shading comes in after the outline has been drawn halfway
    if (P^.Tex <> TexNone) and (R >= 0.5) then
    begin
      if P^.Tex = TexSolid then
        FillSolidAA(T, n, P^.Solid)
      else
        FillTextured(T, n, P^.Tex);
    end;
    if (P^.Decal >= 0) and (n = 4) and (R >= 0.75) then
    begin
      Dw := FDecal[P^.Decal].Width;
      Dh := FDecal[P^.Decal].Height;
      FBand.FillQuadPerspectiveMappingAntialias(T[3], T[2], T[1], T[0], FDecal[P^.Decal],
        PointF(0, 0), PointF(Dw, 0), PointF(Dw, Dh), PointF(0, Dh));
    end;
    case P^.Edge of
      emAll:
        for i := 0 to n - 1 do
        begin
          j := (i + 1) mod n;
          Stroke(T[i].X, T[i].Y, T[j].X, T[j].Y, P^.EdgeC, P^.EdgeW, R, P^.Sketchy and (n <= 8));
        end;
      emMask:
        for i := 0 to n - 1 do
          if P^.EdgeMask and (1 shl i) <> 0 then
          begin
            j := (i + 1) mod n;
            Stroke(T[i].X, T[i].Y, T[j].X, T[j].Y, P^.EdgeC, P^.EdgeW, R, P^.Sketchy);
          end;
    end;
  end;
  i := 0;
  while i < P^.NSeg do
  begin
    Stroke(P^.Segs[i].X, P^.Segs[i].Y + dy, P^.Segs[i + 1].X, P^.Segs[i + 1].Y + dy,
      P^.SegC, P^.SegW, R, P^.Sketchy);
    Inc(i, 2);
  end;
end;

procedure TRenderWorker.FrameTile(Tile: integer);
var
  W, Y0, Rows, y, i, Fl: integer;
  Scene: TCameraScene;
  P: PPrim;
  O: ^TOverlay;
begin
  W := FPool.FFrame.Width;
  Y0 := Tile * BandH;
  Rows := Min(BandH, FPool.FFrame.Height - Y0);
  if FBand.Width <> W then FBand.SetSize(W, BandH);
  FBandW := W;
  FBandRows := Rows;
  FBandY0 := Y0;
  for y := 0 to BandH - 1 do FRows[y] := FBand.ScanLine[y];
  if FPool.PlainPaper then
    for y := 0 to Rows - 1 do FillDWord(FRows[y]^, W, DWord(BGRA(PaperR, PaperG, PaperB, 255)))
  else
    for y := 0 to Rows - 1 do
      Move(FPool.FPaper.ScanLine[Y0 + y]^, FRows[y]^, W * SizeOf(TBGRAPixel));
  FBand.InvalidateBitmap;

  Scene := FPool.FScene;
  for i := 0 to Scene.Count - 1 do
  begin
    P := Scene.Prims[i];
    if (P^.Y1 < Y0) or (P^.Y0 > Y0 + Rows) then Continue;
    if not Scene.LayerOn[P^.Kind] then Continue;
    DrawPrim(P, -Y0);
  end;

  // camera flash: the whole sheet lights up for a moment (the HUD stays readable)
  Fl := Round(FPool.FFlash * 235);
  if Fl > 0 then BlendRect(0, 0, W, Rows, BGRA(255, 253, 246, Fl));

  for i := 0 to FPool.FOverlayCount - 1 do
  begin
    O := @FPool.FOverlay[i];
    case O^.Kind of
      okFill:
        if (O^.Y1 >= Y0) and (O^.Y0 < Y0 + Rows) then
          BlendRect(O^.X0, O^.Y0 - Y0, O^.X1, O^.Y1 - Y0, O^.C);
      okLine:
        if (Max(O^.Y0, O^.Y1) + O^.W + 1 >= Y0) and (Min(O^.Y0, O^.Y1) - O^.W - 1 < Y0 + Rows) then
          PencilLine(O^.X0, O^.Y0 - Y0, O^.X1, O^.Y1 - Y0, O^.C, O^.W);
      okSprite:
        if (O^.Y0 + O^.Sprite.Height >= Y0) and (O^.Y0 < Y0 + Rows) then
          BlendSprite(Round(O^.X0), Round(O^.Y0) - Y0, O^.Sprite, O^.C.alpha);
    end;
  end;

  for y := 0 to Rows - 1 do
    Move(FRows[y]^, FPool.FFrame.ScanLine[Y0 + y]^, W * SizeOf(TBGRAPixel));
end;

procedure TRenderWorker.PaperTile(Tile: integer);
var
  W, H, Y0, Rows, x, y: integer;
  Px: PBGRAPixel;
  cx, cy, d, v, n, Grain: single;
begin
  W := FPool.FPaper.Width;
  H := FPool.FPaper.Height;
  Y0 := Tile * BandH;
  Rows := Min(BandH, H - Y0);
  cx := W / 2;
  cy := H / 2;
  for y := Y0 to Y0 + Rows - 1 do
  begin
    Px := FPool.FPaper.ScanLine[y];
    for x := 0 to W - 1 do
    begin
      // soft blotches + fibre streaks + per-pixel tooth, darker towards the corners
      n := ValueNoise(x / 170, y / 170) * 0.6 + ValueNoise(x / 47, y / 47) * 0.4;
      Grain := ((Hash2(x, y) and 255) / 255 - 0.5) * 7;
      v := (n - 0.5) * 9 + Grain + (ValueNoise(x / 3, y / 90) - 0.5) * 3;
      d := Sqr((x - cx) / cx) + Sqr((y - cy) / cy);
      v := v - 16 * d * Sqrt(d);
      Px^.red := EnsureRange(Round(PaperR + v), 0, 255);
      Px^.green := EnsureRange(Round(PaperG + v), 0, 255);
      Px^.blue := EnsureRange(Round(PaperB + v * 1.1), 0, 255);
      Px^.alpha := 255;
      Inc(Px);
    end;
  end;
end;

{ TRenderPool }

constructor TRenderPool.Create(AThreads: integer);
var
  i: integer;
begin
  MakeTextures;
  if AThreads <= 0 then AThreads := TThread.ProcessorCount;
  AThreads := EnsureRange(AThreads, 1, 64);
  SetLength(FWorkers, AThreads);
  for i := 0 to AThreads - 1 do FWorkers[i] := TRenderWorker.Create(Self);
end;

destructor TRenderPool.Destroy;
var
  i: integer;
begin
  for i := 0 to High(FWorkers) do
  begin
    FWorkers[i].Terminate;
    RTLEventSetEvent(FWorkers[i].FStart);
  end;
  for i := 0 to High(FWorkers) do
  begin
    FWorkers[i].WaitFor;
    FWorkers[i].Free;
  end;
  for i := 0 to TexCount - 1 do FTex[i].Free;
  for i := 0 to DecalCount - 1 do FDecal[i].Free;
  inherited Destroy;
end;

function TRenderPool.WorkerBands(i: integer): integer;
begin
  Result := FWorkers[i].FBands;
end;

function TRenderPool.WorkerBusyMs(i: integer): double;
begin
  Result := FWorkers[i].FBusyMs;
end;

function TRenderPool.OverlayCount: integer;
begin
  Result := FLastOverlay;
end;

function TRenderPool.GetThreadCount: integer;
begin
  Result := Length(FWorkers);
end;

procedure TRenderPool.Run(AJob: TJobKind; ATiles: integer);
var
  i: integer;
begin
  FJob := AJob;
  FTiles := ATiles;
  FNextTile := 0;
  for i := 0 to High(FWorkers) do RTLEventSetEvent(FWorkers[i].FStart);
  for i := 0 to High(FWorkers) do RTLEventWaitFor(FWorkers[i].FDone);
end;

procedure TRenderPool.RenderFrame(AFrame, APaper: TBGRABitmap; AScene: TCameraScene; AFlash: single);
begin
  FFrame := AFrame;
  FPaper := APaper;
  FScene := AScene;
  FFlash := AFlash;
  Run(jkFrame, (AFrame.Height + BandH - 1) div BandH);
  AFrame.InvalidateBitmap;
  FLastOverlay := FOverlayCount;
  FOverlayCount := 0;
end;

procedure TRenderPool.BuildPaper(APaper: TBGRABitmap);
begin
  FPaper := APaper;
  Run(jkPaper, (APaper.Height + BandH - 1) div BandH);
  APaper.InvalidateBitmap;
end;

function TRenderPool.NewOverlay(AKind: TOverlayKind): integer;
begin
  if FOverlayCount >= Length(FOverlay) then SetLength(FOverlay, Max(128, 2 * Length(FOverlay)));
  Result := FOverlayCount;
  Inc(FOverlayCount);
  FOverlay[Result].Kind := AKind;
  FOverlay[Result].Sprite := nil;
end;

procedure TRenderPool.AddFill(X0, Y0, X1, Y1: single; C: TBGRAPixel);
var
  i: integer;
begin
  i := NewOverlay(okFill);
  FOverlay[i].X0 := X0;
  FOverlay[i].Y0 := Y0;
  FOverlay[i].X1 := X1;
  FOverlay[i].Y1 := Y1;
  FOverlay[i].C := C;
end;

procedure TRenderPool.AddLine(X0, Y0, X1, Y1: single; C: TBGRAPixel; W: single);
var
  i: integer;
begin
  i := NewOverlay(okLine);
  FOverlay[i].X0 := X0;
  FOverlay[i].Y0 := Y0;
  FOverlay[i].X1 := X1;
  FOverlay[i].Y1 := Y1;
  FOverlay[i].C := C;
  FOverlay[i].W := W;
end;

procedure TRenderPool.AddRect(X0, Y0, X1, Y1: single; C: TBGRAPixel; W: single);
begin
  AddLine(X0, Y0, X1, Y0, C, W);
  AddLine(X1, Y0, X1, Y1, C, W);
  AddLine(X1, Y1, X0, Y1, C, W);
  AddLine(X0, Y1, X0, Y0, C, W);
end;

procedure TRenderPool.AddSprite(X, Y: integer; S: TBGRABitmap; Opacity: byte);
var
  i: integer;
begin
  i := NewOverlay(okSprite);
  FOverlay[i].X0 := X;
  FOverlay[i].Y0 := Y;
  FOverlay[i].Sprite := S;
  FOverlay[i].C := BGRA(0, 0, 0, Opacity);
end;

procedure TRenderPool.MakeTextures;
var
  i, x, y, m: integer;
  Px: PBGRAPixel;
  v, dark: single;

  // darkness of a diagonal line family with period Per (divides 64, so it tiles)
  function Diag(Coord, Per: integer): single;
  begin
    m := ((Coord mod Per) + Per) mod Per;
    if m = 0 then Result := 1
    else if (m = 1) or (m = Per - 1) then Result := 0.3
    else Result := 0;
  end;

  procedure MakeDecal(Index: integer; const AText: string; AW, AH, ASize: integer; Bold: boolean;
    const AFont: string = 'Bahnschrift');
  begin
    FDecal[Index] := TBGRABitmap.Create(AW, AH, BGRAPixelTransparent);
    FDecal[Index].FontName := AFont;
    FDecal[Index].FontHeight := ASize;
    if Bold then FDecal[Index].FontStyle := [fsBold];
    FDecal[Index].FontQuality := fqFineAntialiasing;
    FDecal[Index].TextOut(AW / 2, (AH - FDecal[Index].FontFullHeight) / 2, AText, BGRA(22, 22, 28, 235), taCenter);
  end;

begin
  for i := 0 to TexCount - 1 do
  begin
    FTex[i] := TBGRABitmap.Create(TexSize, TexSize);
    for y := 0 to TexSize - 1 do
    begin
      Px := FTex[i].ScanLine[y];
      FTexRows[i, y] := Px;
      for x := 0 to TexSize - 1 do
      begin
        // pencil pressure varies along each stroke; periodic in 64 so it tiles
        v := 0.75 + 0.25 * Sin(2 * Pi * (x - y) / TexSize * 2) * Cos(2 * Pi * (x + 2 * y) / TexSize);
        dark := ((Hash2(x * 13 + i, y * 7) and 255) / 255 - 0.5) * 6;
        case i of
          TexPaper:   dark := dark * 0.6 + 9 + 14 * v * Diag(x - y, 8);
          TexLight:   dark := dark + 55 * v * Diag(x + y, 8);
          TexMid:     dark := dark + 55 * v * Diag(x + y, 4) + 8;
          TexDark:    dark := dark + 60 * v * Diag(x + y, 4) + 42 * v * Diag(x - y, 4) + 16;
          TexRubber:  dark := dark * 2.5 + 60 * v * Diag(x + y, 4) + 45 * Diag(x - y, 4) + 45;
          TexGlass:   dark := dark + 62 + 28 * v * Diag(x - y, 4) + 12 * Diag(x + y, 8);
          TexLeather: dark := dark * 4 + 48 + 55 * Ord(Hash2(x, y * 3 + 1) and 3 = 0) + 20 * Diag(x + y, 8);
        end;
        Px^.red := EnsureRange(Round(PaperR - 4 - dark), 0, 255);
        Px^.green := EnsureRange(Round(PaperG - 4 - dark), 0, 255);
        Px^.blue := EnsureRange(Round(PaperB - 2 - dark * 0.92), 0, 255);
        Px^.alpha := 255;
        Inc(Px);
      end;
    end;
    FTex[i].InvalidateBitmap;
  end;
  MakeDecal(DecalBrand, 'Lazra', 420, 80, 58, True, 'Georgia');
  MakeDecal(DecalModel, 'LZ-1', 160, 64, 40, False);
end;

end.
