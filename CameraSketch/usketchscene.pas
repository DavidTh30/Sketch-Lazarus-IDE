unit USketchScene;

{ The camera model and its animation, turned into a flat display list.

  Every frame Build projects the model (boxes, a pentaprism, cylinders for
  the dials and the lens rings) into screen space and writes one TPrim per
  visible face or line group. The prims are sorted back to front (painter's
  algorithm) and handed to the render pool, which rasterises them on all
  cores. Text is not drawn by the workers: Build collects it in Labels and
  the window draws it on the main thread.

  Model units are centimetres: the body is 14 x 9 x 5, the lens points
  along +Z, Y is up. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes;

const
  TileH = 64;                        // band height = hatch texture size, so the hatching lines up across bands

  TexNone = -1;
  TexSolid = -2;
  TexPaper = 0;
  TexLight = 1;
  TexMid = 2;
  TexDark = 3;
  TexRubber = 4;
  TexGlass = 5;
  TexLeather = 6;
  TexCount = 7;

  DecalBrand = 0;
  DecalModel = 1;
  DecalCount = 2;

  // layers: every prim and label belongs to one (the developer window toggles them)
  okGrid = 0;
  okShadow = 1;
  okConstruct = 2;
  okModel = 3;
  okDim = 4;
  okAxis = 5;
  okAssembly = 6;
  okCallout = 7;
  okMarking = 8;
  KindCount = 9;
  KindNames: array[0..KindCount - 1] of string = ('Ground grid', 'Shadow', 'Construction lines',
    'Model', 'Dimensions', 'Centre axis', 'Assembly paths', 'Callouts / tags', 'Markings');

  // sound events raised by the animation, consumed by the window
  seAutofocus = 1;
  seShutter = 2;

  ShutterNames: array[0..7] of string = ('1/30', '1/60', '1/125', '1/250', '1/500', '1/1000', '1/2000', '1/4000');
  IsoValues: array[0..6] of integer = (100, 200, 400, 800, 1600, 3200, 6400);
  FStops: array[0..6] of single = (2.8, 4, 5.6, 8, 11, 16, 22);

type
  TVec3 = record
    X, Y, Z: single;
  end;

  TEdgeMode = (emNone, emAll, emMask);

  TPrim = record
    Layer: byte;                     // 0 paper lines, 1 the model, 2 annotation on top
    Depth: single;                   // larger = farther, drawn first
    Pts: array of TPointF;           // fill polygon / outline
    Tex: integer;                    // TexNone, TexSolid or a hatch texture index
    Solid: TBGRAPixel;
    Edge: TEdgeMode;
    EdgeMask: cardinal;              // emMask: bit i strokes Pts[i] -> Pts[i+1]
    EdgeW: single;
    EdgeC: TBGRAPixel;
    Sketchy: boolean;                // overshooting, doubled pencil strokes
    Segs: array of TPointF;          // independent strokes, in pairs
    NSeg: integer;                   // points used in Segs
    SegW: single;
    SegC: TBGRAPixel;
    Decal: integer;                  // -1 or decal texture mapped on Pts[0..3]
    Reveal: single;                  // 0..1 drawing-in progress
    Y0, Y1: single;                  // vertical extent on screen, for band culling
    Part: smallint;                  // part index, -1 for annotation and background
    Kind: byte;                      // layer (ok... constant)
  end;
  PPrim = ^TPrim;

  TLabelKind = (lkDim, lkCallout, lkTag, lkTiny);

  TSceneLabel = record
    X, Y: single;
    Text: string;
    Kind: TLabelKind;
    Alpha: single;
    Align: TAlignment;
  end;

  // What the developer window shows per object (a part or a layer)
  TObjStat = record
    Prims: integer;
    Box: TRectF;                     // screen bounds, empty when nothing drawn
    DMin, DMax: single;              // depth range
    Reveal: single;
    Occluded: boolean;               // anchor hidden by the body (assembled view)
  end;

  TPartInfo = record
    Name: string;
    Offset: TVec3;                   // where the part goes in the exploded view
    Anchor: TVec3;                   // callout point, assembled position
    Bias: single;                    // drawn this much "closer" (parts sitting on a face)
  end;

  { TCameraScene }

  TCameraScene = class
  private
    FPrims: array of TPrim;
    FCount: integer;
    FOrder: array of integer;
    FLabels: array of TSceneLabel;
    FLabelCount: integer;
    FMeasure: TBGRABitmap;
    // per build
    FCx, FCy, FFocal, FDist: single;
    FCosY, FSinY, FCosP, FSinP: single;
    FPivot, FCur, FLight: TVec3;
    FCurReveal, FCurBias: single;
    FKind: byte;
    FSupportDepth: single;           // > 0: prims are kept in front of this depth (parts standing on the top plate)
    FOnSupport: boolean;
    FPart: integer;
    FLX, FLY: single;                // lens axis
    FBoxMin, FBoxMax: TPointF;       // screen bounds of the model
    function NewPrim(ALayer: byte; ADepth: single): PPrim;
    procedure FinishPrim(P: PPrim);
    procedure AddSeg(P: PPrim; const A, B: TPointF);
    procedure AddLabel(X, Y: single; const AText: string; AKind: TLabelKind; AAlpha: single;
      AAlign: TAlignment = taCenter);
    function ToView(const P: TVec3): TVec3;
    function RotN(const N: TVec3): TVec3;
    function Proj(const V: TVec3): TPointF;
    function World(const P: TVec3): TVec3;     // model point + current part offset -> view space
    function Facing(const NV, PV: TVec3): single;
    function FromView(const V: TVec3): TVec3;
    function Occluded(const A: TVec3): boolean;
    function HatchFor(I: single; Mat: integer): integer;
    procedure BeginPart(Index: integer);
    procedure AddFace(const C: array of TVec3; Mat: integer; ADecal: integer = -1);
    procedure AddHexa(const C: array of TVec3; Mat: integer; DecalFace: integer = -1; ADecal: integer = -1);
    procedure AddBox(X0, Y0, Z0, X1, Y1, Z1: single; Mat: integer);
    procedure AddCylY(CX, CY, CZ, R, H: single; Segs: integer; Ribbed: boolean; Phase: single;
      Mat: integer; Ticks: integer = 0);
    procedure AddCylZ(Z0, Z1, R0, R1: single; Segs: integer; Ribbed: boolean; Phase: single;
      Mat: integer; Ticks: integer = 0; CapFront: boolean = True);
    procedure AddFrontElement(ZF: single);
    procedure AddExtrudeY(const Poly: array of TPointF; Y0, Y1: single; Mat: integer;
      CapTop, CapBottom: boolean);
    procedure AddLoftY(const PB, PT: array of TPointF; Y0, Y1: single; Mat: integer;
      CapTop, CapBottom: boolean);
    procedure AddTopLabels(CX, CY, CZ, R, Phase: single; const Texts: array of string;
      const Angles: array of single);
    procedure AddFaceLabels(Z, R: single; const Texts: array of string; const Angles: array of single);
    procedure AddLine3D(const Pts: array of TVec3; ALayer: byte; C: TBGRAPixel; W: single; Closed: boolean);
    procedure AddDashed(const A, B: TVec3; C: TBGRAPixel; W: single; DashDot: boolean);
    procedure AddDim(const A, B, Off: TVec3; const AText: string; Reveal: single; LabelAt: single = 0.5);
    procedure AddGround;
    procedure AddShadow;
    procedure AddConstruction;
    procedure AddCallouts;
    procedure AddRingLabels(Z, R, Phase: single; const Texts: array of string; const Angles: array of single);
    procedure SortPrims;
    procedure ComputeStats;
    function GetPrim(Index: integer): PPrim;
    function GetLabel(Index: integer): TSceneLabel;
  public
    // view
    Yaw, Pitch, Distance: single;
    YawVel, PitchVel: single;
    AutoOrbit: boolean;
    IdleTime: single;
    // state
    Time, RevealTime: single;
    Explode, ExplodeVel: single;
    ExplodeOn: boolean;
    Zoom, ZoomTarget: single;        // 0 = 24 mm, 1 = 70 mm
    Focus, FocusTarget: single;      // focus ring angle
    ShutterIdx, IsoIdx, ApertureIdx: integer;
    ShutterDial, IsoDial: single;    // current dial angles
    Aperture: single;                // iris opening 0..1
    ShotT: single;                   // seconds since the shutter was pressed, < 0 idle
    Shots: integer;
    Flash: single;
    ButtonDown: single;
    Wire, ShowLabels: boolean;
    Parts: array of TPartInfo;
    // physics / animation parameters (tunable live from the developer window)
    TimeScale: single;               // 1 = real time
    ExplodeK, ExplodeC: single;      // spring stiffness and damping
    Spread: single;                  // exploded view distance
    OrbitDamp: single;               // orbit inertia friction
    AutoSpeed, AutoDelay: single;    // auto orbit (rad/s, idle seconds)
    ZoomRate, FocusRate, DialRate: single;   // follow speeds
    FlashDecay: single;
    LayerOn: array[0..KindCount - 1] of boolean;
    PartStats: array of TObjStat;
    KindStats: array[0..KindCount - 1] of TObjStat;
    SoundEvents: integer;            // seXxx bits since the window last read them
    procedure ResetPhysics;
    constructor Create;
    destructor Destroy; override;
    procedure Update(dt: single);
    procedure Build(W, H: integer);
    procedure FireShutter;
    procedure Replay;
    function FocalMm: integer;
    property Count: integer read FCount;
    property Prims[Index: integer]: PPrim read GetPrim;   // in drawing order
    property LabelCount: integer read FLabelCount;
    property Labels[Index: integer]: TSceneLabel read GetLabel;
  end;

function V3(X, Y, Z: single): TVec3; inline;

implementation

const
  MatMetal = 0;
  MatRubber = 1;
  MatLeather = 2;
  MatKnurl = 3;
  MatTeeth = 4;                      // dial side: alternating light and dark teeth                      // light ring: the ribs do the shading

  PBody = 0; PTop = 1; PPrism = 2; PShoe = 3; PShutterDial = 4; PIsoDial = 5; PRelease = 6;
  PGrip = 7; PLug = 8; PMount = 9; PRear = 10; PZoom = 11; PScale = 12; PFocus = 13;
  PInner = 14; PHood = 15; PFront = 16; PLamp = 17; PLensBtn = 18;
  PartCount = 19;

var
  Graphite, GraphiteSoft, Construct, DimInk: TBGRAPixel;

function V3(X, Y, Z: single): TVec3;
begin
  Result.X := X;
  Result.Y := Y;
  Result.Z := Z;
end;

function VAdd(const A, B: TVec3): TVec3; inline;
begin
  Result := V3(A.X + B.X, A.Y + B.Y, A.Z + B.Z);
end;

function VSub(const A, B: TVec3): TVec3; inline;
begin
  Result := V3(A.X - B.X, A.Y - B.Y, A.Z - B.Z);
end;

function VMul(const A: TVec3; S: single): TVec3; inline;
begin
  Result := V3(A.X * S, A.Y * S, A.Z * S);
end;

function VDot(const A, B: TVec3): single; inline;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

function VCross(const A, B: TVec3): TVec3; inline;
begin
  Result := V3(A.Y * B.Z - A.Z * B.Y, A.Z * B.X - A.X * B.Z, A.X * B.Y - A.Y * B.X);
end;

function VNorm(const A: TVec3): TVec3;
var
  L: single;
begin
  L := Sqrt(VDot(A, A));
  if L < 1e-9 then Exit(V3(0, 0, 0));
  Result := VMul(A, 1 / L);
end;

function Clamp01(V: single): single; inline;
begin
  if V < 0 then Result := 0 else if V > 1 then Result := 1 else Result := V;
end;

function Smooth(V: single): single; inline;
begin
  V := Clamp01(V);
  Result := V * V * (3 - 2 * V);
end;

function Approach(Cur, Target, Rate, dt: single): single; inline;
begin
  Result := Cur + (Target - Cur) * (1 - Exp(-Rate * dt));
end;

// Rounded rectangle outline in the X/Z plane, counter-clockwise seen from above.
function RoundRectXZ(X0, Z0, X1, Z1, R: single; Seg: integer = 5): ArrayOfTPointF;
const
  CornerStart: array[0..3] of single = (0, 0.5 * Pi, Pi, 1.5 * Pi);
var
  c, i, k: integer;
  CX, CZ, A: single;
begin
  SetLength(Result, 4 * (Seg + 1));
  k := 0;
  for c := 0 to 3 do
  begin
    // corners: +X+Z... walking around the outline
    case c of
      0: begin CX := X1 - R; CZ := Z0 + R; end;
      1: begin CX := X1 - R; CZ := Z1 - R; end;
      2: begin CX := X0 + R; CZ := Z1 - R; end;
    else
      begin CX := X0 + R; CZ := Z0 + R; end;
    end;
    for i := 0 to Seg do
    begin
      A := CornerStart[c] - 0.5 * Pi + 0.5 * Pi * i / Seg;
      Result[k] := PointF(CX + R * Cos(A), CZ + R * Sin(A));
      Inc(k);
    end;
  end;
end;

// Rectangle with cut corners in the X/Z plane.
function ChamferRectXZ(X0, Z0, X1, Z1, C: single): ArrayOfTPointF;
begin
  SetLength(Result, 8);
  Result[0] := PointF(X0 + C, Z0);
  Result[1] := PointF(X1 - C, Z0);
  Result[2] := PointF(X1, Z0 + C);
  Result[3] := PointF(X1, Z1 - C);
  Result[4] := PointF(X1 - C, Z1);
  Result[5] := PointF(X0 + C, Z1);
  Result[6] := PointF(X0, Z1 - C);
  Result[7] := PointF(X0, Z0 + C);
end;

// Grip outline in the X/Z plane: straight back edge at Z0, rounded front corners.
function GripOutline(X0, Z0, X1, Z1, R: single; Seg: integer = 6): ArrayOfTPointF;
var
  i, k: integer;
  A: single;
begin
  SetLength(Result, 2 + 2 * (Seg + 1));
  Result[0] := PointF(X0, Z0);
  Result[1] := PointF(X1, Z0);
  k := 2;
  for i := 0 to Seg do
  begin
    A := 0.5 * Pi * i / Seg;
    Result[k] := PointF(X1 - R + R * Cos(A), Z1 - R + R * Sin(A));
    Inc(k);
  end;
  for i := 0 to Seg do
  begin
    A := 0.5 * Pi + 0.5 * Pi * i / Seg;
    Result[k] := PointF(X0 + R + R * Cos(A), Z1 - R + R * Sin(A));
    Inc(k);
  end;
end;

{ TCameraScene }

constructor TCameraScene.Create;
var
  i: integer;

  procedure P(Index: integer; const AName: string; const AOffset, AAnchor: TVec3; ABias: single);
  begin
    Parts[Index].Name := AName;
    Parts[Index].Offset := AOffset;
    Parts[Index].Anchor := AAnchor;
    Parts[Index].Bias := ABias;
  end;

begin
  FMeasure := TBGRABitmap.Create(4, 4);
  FMeasure.FontName := 'Bahnschrift';
  FMeasure.FontQuality := fqFineAntialiasing;
  FLX := 0.6;
  FLY := -0.2;
  SetLength(Parts, PartCount);
  P(PBody,        'BODY / LEATHERETTE',  V3(0, 0, 0),      V3(6.2, -2.2, 2.5), 0);
  P(PTop,         'TOP PLATE',           V3(0, 2.4, 0),    V3(6.4, 3.6, 2.5), 0);
  P(PPrism,       'PENTAPRISM HOUSING',  V3(0, 5.2, 0),    V3(2.2, 6.6, 1.6), 0.25);
  P(PShoe,        'HOT SHOE',            V3(0, 7.4, 0),    V3(1.3, 7.9, 0.4), 0.35);
  P(PShutterDial, 'SHUTTER SPEED DIAL',  V3(0.6, 4.0, 0),  V3(6.4, 5.4, 0.2), 0.5);
  P(PIsoDial,     'ISO DIAL',            V3(-0.6, 4.0, 0), V3(-6.2, 5.8, -0.8), 0.5);
  P(PRelease,     'SHUTTER RELEASE',     V3(-1.0, 5.8, 1.0), V3(-5.4, 5.3, 3.3), 0.6);
  P(PGrip,        'GRIP',                V3(-3.4, 0, 2.6), V3(-7.2, -1.0, 4.0), 0.15);
  P(PLug,         'STRAP LUG',           V3(3.0, 0, 0),    V3(8.3, 1.4, 0), 0.3);
  P(PMount,       'BAYONET MOUNT',       V3(0, 0, 2.6),    V3(0.6, 3.35, 2.75), 0);
  P(PRear,        'REAR BARREL',         V3(0, 0, 5.0),    V3(0.6, 3.25, 3.4), 0);
  P(PZoom,        'ZOOM RING',           V3(0, 0, 7.6),    V3(0.6, 3.55, 5.8), 0);
  P(PScale,       'DISTANCE SCALE',      V3(0, 0, 10.0),   V3(0.6, 3.3, 8.0), 0);
  P(PFocus,       'FOCUS RING',          V3(0, 0, 12.4),   V3(0.6, 3.6, 9.5), 0);
  P(PInner,       'INNER BARREL',        V3(0, 0, 14.6),   V3(0.6, 3.2, 11.0), 0);
  P(PHood,        'FILTER RING',         V3(0, 0, 16.8),   V3(0.6, 4.1, 12.3), 0);
  P(PFront,       'FRONT ELEMENT',       V3(0, 0, 19.4),   V3(-1.9, 1.6, 12.8), 0);
  P(PLamp,        'AF ASSIST LAMP',      V3(0, 0.4, 1.8),  V3(-2.9, 1.6, 2.7), 0.4);
  P(PLensBtn,     'LENS RELEASE',        V3(1.4, -0.4, 2.0), V3(4.6, -1.6, 2.8), 0.4);

  Yaw := -0.62;
  Pitch := 0.42;
  Distance := 50;
  AutoOrbit := True;
  ShutterIdx := 3;
  IsoIdx := 2;
  ApertureIdx := 0;
  ShutterDial := ShutterIdx * 0.5;
  IsoDial := IsoIdx * 0.6;
  Aperture := 1;
  Zoom := 0.25;
  ZoomTarget := 0.25;
  ShotT := -1;
  ShowLabels := True;
  ResetPhysics;
  for i := 0 to KindCount - 1 do LayerOn[i] := True;
  SetLength(PartStats, PartCount);
end;

destructor TCameraScene.Destroy;
begin
  FMeasure.Free;
  inherited Destroy;
end;

procedure TCameraScene.ResetPhysics;
begin
  TimeScale := 1;
  ExplodeK := 70;
  ExplodeC := 11;
  Spread := 0.72;
  OrbitDamp := 3.5;
  AutoSpeed := 0.16;
  AutoDelay := 2.5;
  ZoomRate := 7;
  FocusRate := 9;
  DialRate := 10;
  FlashDecay := 7;
end;

procedure TCameraScene.Replay;
begin
  RevealTime := 0;
end;

procedure TCameraScene.FireShutter;
begin
  if ShotT >= 0 then Exit;
  ShotT := 0;
  SoundEvents := SoundEvents or seAutofocus;
  // autofocus: the focus ring hunts to a new distance before the exposure
  FocusTarget := FocusTarget + (0.8 + Random * 1.4) * (1 - 2 * Random(2));
end;

function TCameraScene.FocalMm: integer;
begin
  Result := Round(24 + 46 * Zoom);
end;

procedure TCameraScene.Update(dt: single);
var
  Stop, A: single;
begin
  dt := dt * TimeScale;
  Time := Time + dt;
  RevealTime := RevealTime + dt;
  IdleTime := IdleTime + dt;

  // orbit: drag inertia, then a slow automatic sway when left alone
  Yaw := Yaw + YawVel * dt;
  Pitch := Pitch + PitchVel * dt;
  YawVel := YawVel * Exp(-OrbitDamp * dt);
  PitchVel := PitchVel * Exp(-OrbitDamp * dt);
  if AutoOrbit and (IdleTime > AutoDelay) then
  begin
    A := Smooth((IdleTime - AutoDelay) / 2);
    Yaw := Yaw + dt * AutoSpeed * A;
    Pitch := Approach(Pitch, 0.42 + 0.1 * Sin(Time * 0.35), 0.8 * A, dt);
  end;
  Pitch := EnsureRange(Pitch, 0.06, 1.25);

  // exploded view: under-damped spring, it overshoots a little and settles
  A := ExplodeK * (Ord(ExplodeOn) - Explode) - ExplodeC * ExplodeVel;
  ExplodeVel := ExplodeVel + A * dt;
  Explode := Explode + ExplodeVel * dt;

  Zoom := Approach(Zoom, ZoomTarget, ZoomRate, dt);
  Focus := Approach(Focus, FocusTarget, FocusRate, dt);
  ShutterDial := Approach(ShutterDial, ShutterIdx * 0.5, DialRate, dt);
  IsoDial := Approach(IsoDial, IsoIdx * 0.6, DialRate, dt);

  // shutter sequence: press, focus, stop down, expose, reopen, release
  Stop := 2.8 / FStops[ApertureIdx];
  if ShotT >= 0 then
  begin
    ShotT := ShotT + dt;
    if ShotT < 0.55 then
      ButtonDown := Approach(ButtonDown, 1, 30, dt)
    else
      ButtonDown := Approach(ButtonDown, 0, 14, dt);
    if ShotT < 0.30 then
      Aperture := Approach(Aperture, 1, 20, dt)
    else if ShotT < 0.42 then
      Aperture := Approach(Aperture, Stop, 28, dt)
    else if ShotT < 0.52 then
      Aperture := Approach(Aperture, 0.04, 40, dt)
    else
      Aperture := Approach(Aperture, 1, 9, dt);
    if (ShotT >= 0.42) and (ShotT - dt < 0.42) then
    begin
      Flash := 1;
      Inc(Shots);
      SoundEvents := SoundEvents or seShutter;
    end;
    if ShotT > 1.1 then ShotT := -1;
  end
  else
  begin
    ButtonDown := Approach(ButtonDown, 0, 14, dt);
    Aperture := Approach(Aperture, 1, 9, dt);
  end;
  Flash := Flash * Exp(-FlashDecay * dt);
  if Flash < 0.01 then Flash := 0;
end;

{ ------------------------------------------------------------ prims }

function TCameraScene.NewPrim(ALayer: byte; ADepth: single): PPrim;
begin
  if FCount >= Length(FPrims) then
    SetLength(FPrims, Max(256, Length(FPrims) * 2));
  Result := @FPrims[FCount];
  Inc(FCount);
  Result^.Layer := ALayer;
  // parts standing on the top plate are always drawn after the plate's top face
  // (smooth compression into [S - 1, S - 0.01): their order among themselves is kept)
  if FOnSupport and (ALayer = 1) and (ADepth > FSupportDepth - 1) then
    ADepth := FSupportDepth - 1 + (1 - Exp(-(ADepth - FSupportDepth + 1))) * 0.99;
  Result^.Depth := ADepth;
  Result^.Tex := TexNone;
  Result^.Edge := emNone;
  Result^.EdgeMask := 0;
  Result^.EdgeW := 1.25;
  Result^.EdgeC := Graphite;
  Result^.Sketchy := False;
  Result^.NSeg := 0;
  Result^.SegW := 0.8;
  Result^.SegC := GraphiteSoft;
  Result^.Decal := -1;
  Result^.Reveal := FCurReveal;
  Result^.Part := FPart;
  Result^.Kind := FKind;
  if Length(Result^.Pts) <> 0 then SetLength(Result^.Pts, 0);
end;

procedure TCameraScene.AddSeg(P: PPrim; const A, B: TPointF);
begin
  if P^.NSeg + 2 > Length(P^.Segs) then
    SetLength(P^.Segs, Max(16, Length(P^.Segs) * 2));
  P^.Segs[P^.NSeg] := A;
  P^.Segs[P^.NSeg + 1] := B;
  Inc(P^.NSeg, 2);
end;

procedure TCameraScene.FinishPrim(P: PPrim);
var
  i: integer;
  Y0, Y1, Pad: single;
begin
  Y0 := 1e9;
  Y1 := -1e9;
  for i := 0 to High(P^.Pts) do
  begin
    if P^.Pts[i].Y < Y0 then Y0 := P^.Pts[i].Y;
    if P^.Pts[i].Y > Y1 then Y1 := P^.Pts[i].Y;
  end;
  for i := 0 to P^.NSeg - 1 do
  begin
    if P^.Segs[i].Y < Y0 then Y0 := P^.Segs[i].Y;
    if P^.Segs[i].Y > Y1 then Y1 := P^.Segs[i].Y;
  end;
  Pad := Max(P^.EdgeW, P^.SegW) + 4;   // stroke width + sketch overshoot
  P^.Y0 := Y0 - Pad;
  P^.Y1 := Y1 + Pad;
end;

procedure TCameraScene.AddLabel(X, Y: single; const AText: string; AKind: TLabelKind;
  AAlpha: single; AAlign: TAlignment);
begin
  if AAlpha <= 0.01 then Exit;
  if FLabelCount >= Length(FLabels) then
    SetLength(FLabels, Max(64, Length(FLabels) * 2));
  FLabels[FLabelCount].X := X;
  FLabels[FLabelCount].Y := Y;
  FLabels[FLabelCount].Text := AText;
  FLabels[FLabelCount].Kind := AKind;
  FLabels[FLabelCount].Alpha := Clamp01(AAlpha);
  FLabels[FLabelCount].Align := AAlign;
  Inc(FLabelCount);
end;

function TCameraScene.GetPrim(Index: integer): PPrim;
begin
  Result := @FPrims[FOrder[Index]];
end;

function TCameraScene.GetLabel(Index: integer): TSceneLabel;
begin
  Result := FLabels[Index];
end;

{ ------------------------------------------------------------ projection }

function TCameraScene.RotN(const N: TVec3): TVec3;
var
  X, Z: single;
begin
  // yaw around Y, then pitch around X
  X := N.X * FCosY + N.Z * FSinY;
  Z := -N.X * FSinY + N.Z * FCosY;
  Result.X := X;
  Result.Y := N.Y * FCosP - Z * FSinP;
  Result.Z := N.Y * FSinP + Z * FCosP;
end;

function TCameraScene.ToView(const P: TVec3): TVec3;
begin
  Result := RotN(VSub(P, FPivot));
end;

function TCameraScene.World(const P: TVec3): TVec3;
begin
  Result := ToView(VAdd(P, FCur));
end;

function TCameraScene.Proj(const V: TVec3): TPointF;
var
  D: single;
begin
  D := Max(1, FDist - V.Z);
  Result.X := FCx + FFocal * V.X / D;
  Result.Y := FCy - FFocal * V.Y / D;
end;

function TCameraScene.Facing(const NV, PV: TVec3): single;
begin
  // > 0 when the face looks at the eye, which sits at (0, 0, FDist) in view space
  Result := NV.X * -PV.X + NV.Y * -PV.Y + NV.Z * (FDist - PV.Z);
end;

function TCameraScene.HatchFor(I: single; Mat: integer): integer;
begin
  case Mat of
    MatRubber:
      if I > 0.5 then Result := TexMid
      else if I > 0.05 then Result := TexDark
      else Result := TexRubber;
    MatKnurl:
      if I > 0.45 then Result := TexPaper
      else if I > 0.05 then Result := TexLight
      else if I > -0.3 then Result := TexMid
      else Result := TexDark;
    MatLeather:
      if I > 0.35 then Result := TexLeather
      else if I > -0.25 then Result := TexDark
      else Result := TexRubber;
  else
    if I > 0.55 then Result := TexPaper
    else if I > 0.25 then Result := TexLight
    else if I > -0.1 then Result := TexMid
    else Result := TexDark;
  end;
end;

procedure TCameraScene.BeginPart(Index: integer);
var
  Delay: single;
begin
  FPart := Index;
  FCur := VMul(Parts[Index].Offset, Explode * Spread);
  FKind := okModel;
  FCurBias := Parts[Index].Bias;
  // parts are drawn in by order: body first, the lens front last
  Delay := 0.3 + Index * 0.13;
  FCurReveal := Clamp01((RevealTime - Delay) / 0.9);
end;

{ ------------------------------------------------------------ geometry }

procedure TCameraScene.AddFace(const C: array of TVec3; Mat: integer; ADecal: integer);
var
  V: array[0..7] of TVec3;
  N, NV, Ctr: TVec3;
  P: PPrim;
  i, Cnt: integer;
  F, D: single;
begin
  Cnt := Length(C);
  Ctr := V3(0, 0, 0);
  for i := 0 to Cnt - 1 do
  begin
    V[i] := World(C[i]);
    Ctr := VAdd(Ctr, V[i]);
  end;
  Ctr := VMul(Ctr, 1 / Cnt);
  // corners are listed counter-clockwise seen from outside
  N := VNorm(VCross(VSub(C[1], C[0]), VSub(C[2], C[0])));
  NV := RotN(N);
  F := Facing(NV, Ctr);
  if (F <= 0) and not Wire then Exit;
  D := FDist - Ctr.Z - FCurBias;
  P := NewPrim(1, D);
  SetLength(P^.Pts, Cnt);
  for i := 0 to Cnt - 1 do
    P^.Pts[i] := Proj(V[i]);
  P^.Edge := emAll;
  P^.Sketchy := True;
  if Wire then
  begin
    if F <= 0 then P^.EdgeC := BGRA(70, 80, 100, 70) else P^.EdgeC := BGRA(40, 50, 70, 200);
    P^.EdgeW := 1;
  end
  else
  begin
    P^.Tex := HatchFor(VDot(NV, FLight), Mat);
    P^.Decal := ADecal;
  end;
  FinishPrim(P);
end;

procedure TCameraScene.AddHexa(const C: array of TVec3; Mat: integer; DecalFace: integer; ADecal: integer);
const
  // corners 0..3 bottom, 4..7 top, both counter-clockwise seen from above
  Faces: array[0..5, 0..3] of integer = (
    (0, 3, 2, 1), (4, 5, 6, 7),
    (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7));
var
  f: integer;
begin
  for f := 0 to 5 do
    if f = DecalFace then
      AddFace([C[Faces[f, 0]], C[Faces[f, 1]], C[Faces[f, 2]], C[Faces[f, 3]]], Mat, ADecal)
    else
      AddFace([C[Faces[f, 0]], C[Faces[f, 1]], C[Faces[f, 2]], C[Faces[f, 3]]], Mat);
end;

procedure TCameraScene.AddBox(X0, Y0, Z0, X1, Y1, Z1: single; Mat: integer);
begin
  // bottom: front-left, front-right, back-right, back-left (counter-clockwise from above)
  AddHexa([V3(X0, Y0, Z1), V3(X1, Y0, Z1), V3(X1, Y0, Z0), V3(X0, Y0, Z0),
           V3(X0, Y1, Z1), V3(X1, Y1, Z1), V3(X1, Y1, Z0), V3(X0, Y1, Z0)], Mat);
end;

// Vertical cylinder (dial, button) standing on (CX, CY, CZ).
procedure TCameraScene.AddCylY(CX, CY, CZ, R, H: single; Segs: integer; Ribbed: boolean;
  Phase: single; Mat: integer; Ticks: integer);
var
  B, T: array of TVec3;
  NV: array of TVec3;
  Vis: array of boolean;
  i, j: integer;
  A: single;
  P: PPrim;
  Ctr, TopC: TVec3;
  Pts2: array of TPointF;
begin
  SetLength(B, Segs);
  SetLength(T, Segs);
  SetLength(NV, Segs);
  SetLength(Vis, Segs);
  for i := 0 to Segs - 1 do
  begin
    A := Phase + 2 * Pi * i / Segs;
    B[i] := World(V3(CX + R * Cos(A), CY, CZ - R * Sin(A)));
    T[i] := World(V3(CX + R * Cos(A), CY + H, CZ - R * Sin(A)));
  end;
  for i := 0 to Segs - 1 do
  begin
    A := Phase + 2 * Pi * (i + 0.5) / Segs;
    NV[i] := RotN(V3(Cos(A), 0, -Sin(A)));
    j := (i + 1) mod Segs;
    Ctr := VMul(VAdd(VAdd(B[i], B[j]), VAdd(T[i], T[j])), 0.25);
    Vis[i] := Facing(NV[i], Ctr) > 0;
  end;
  // side
  for i := 0 to Segs - 1 do
  begin
    if not Vis[i] and not Wire then Continue;
    j := (i + 1) mod Segs;
    Ctr := VMul(VAdd(VAdd(B[i], B[j]), VAdd(T[i], T[j])), 0.25);
    P := NewPrim(1, FDist - Ctr.Z - FCurBias);
    SetLength(P^.Pts, 4);
    P^.Pts[0] := Proj(B[i]);
    P^.Pts[1] := Proj(B[j]);
    P^.Pts[2] := Proj(T[j]);
    P^.Pts[3] := Proj(T[i]);
    P^.Edge := emMask;
    P^.EdgeMask := 1 or 4;                         // bottom and top rim
    if not Vis[(i + Segs - 1) mod Segs] then P^.EdgeMask := P^.EdgeMask or 8;   // silhouette
    if not Vis[j] then P^.EdgeMask := P^.EdgeMask or 2;
    if Wire then
    begin
      P^.EdgeC := BGRA(40, 50, 70, IfThen(Vis[i], 180, 60));
      P^.EdgeW := 0.9;
    end
    else
    begin
      P^.Tex := HatchFor(VDot(NV[i], FLight), Mat);
      // chunky dial teeth: every other facet two hatch levels darker
      if (Mat = MatTeeth) and Odd(i) then P^.Tex := Min(TexDark, P^.Tex + 2);
    end;
    if Ribbed then AddSeg(P, P^.Pts[0], P^.Pts[3]);
    FinishPrim(P);
  end;
  // top cap
  TopC := World(V3(CX, CY + H, CZ));
  if (Facing(RotN(V3(0, 1, 0)), TopC) > 0) or Wire then
  begin
    P := NewPrim(1, FDist - TopC.Z - FCurBias - 0.05);
    SetLength(Pts2, Segs);
    for i := 0 to Segs - 1 do Pts2[i] := Proj(T[i]);
    P^.Pts := Pts2;
    P^.Edge := emAll;
    if not Wire then P^.Tex := HatchFor(VDot(RotN(V3(0, 1, 0)), FLight), MatMetal);
    if Ticks > 0 then
      for i := 0 to Segs - 1 do
        if i mod (Segs div Ticks) = 0 then
        begin
          A := Phase + 2 * Pi * i / Segs;
          AddSeg(P, Proj(World(V3(CX + R * 0.62 * Cos(A), CY + H, CZ - R * 0.62 * Sin(A)))),
                    Proj(World(V3(CX + R * 0.9 * Cos(A), CY + H, CZ - R * 0.9 * Sin(A)))));
        end;
    if Ticks > 0 then
      for i := 0 to Segs - 1 do
      begin
        A := 2 * Pi * i / Segs;
        j := i + 1;
        AddSeg(P, Proj(World(V3(CX + R * 0.55 * Cos(A), CY + H, CZ - R * 0.55 * Sin(A)))),
          Proj(World(V3(CX + R * 0.55 * Cos(2 * Pi * j / Segs), CY + H, CZ - R * 0.55 * Sin(2 * Pi * j / Segs)))));
      end;
    if Ribbed then
      for i := 0 to Segs - 1 do
        if not Odd(i) then
        begin
          A := Phase + 2 * Pi * i / Segs;
          AddSeg(P, Proj(World(V3(CX + R * 0.84 * Cos(A), CY + H, CZ - R * 0.84 * Sin(A)))),
                    Proj(World(V3(CX + R * 0.98 * Cos(A), CY + H, CZ - R * 0.98 * Sin(A)))));
        end;
    FinishPrim(P);
  end;
end;

// Lens ring along +Z around the lens axis, from Z0 (radius R0) to Z1 (radius R1).
procedure TCameraScene.AddCylZ(Z0, Z1, R0, R1: single; Segs: integer; Ribbed: boolean;
  Phase: single; Mat: integer; Ticks: integer; CapFront: boolean);
var
  B, T: array of TVec3;
  NV: array of TVec3;
  Vis: array of boolean;
  i, j: integer;
  A, Slope: single;
  P: PPrim;
  Ctr, FrontC, NF: TVec3;
  Pts2: array of TPointF;
begin
  SetLength(B, Segs);
  SetLength(T, Segs);
  SetLength(NV, Segs);
  SetLength(Vis, Segs);
  Slope := (R0 - R1) / Max(0.01, Z1 - Z0);
  for i := 0 to Segs - 1 do
  begin
    A := Phase + 2 * Pi * i / Segs;
    B[i] := World(V3(FLX + R0 * Cos(A), FLY + R0 * Sin(A), Z0));
    T[i] := World(V3(FLX + R1 * Cos(A), FLY + R1 * Sin(A), Z1));
  end;
  for i := 0 to Segs - 1 do
  begin
    A := Phase + 2 * Pi * (i + 0.5) / Segs;
    NV[i] := RotN(VNorm(V3(Cos(A), Sin(A), Slope)));
    j := (i + 1) mod Segs;
    Ctr := VMul(VAdd(VAdd(B[i], B[j]), VAdd(T[i], T[j])), 0.25);
    Vis[i] := Facing(NV[i], Ctr) > 0;
  end;
  for i := 0 to Segs - 1 do
  begin
    if not Vis[i] and not Wire then Continue;
    j := (i + 1) mod Segs;
    Ctr := VMul(VAdd(VAdd(B[i], B[j]), VAdd(T[i], T[j])), 0.25);
    P := NewPrim(1, FDist - Ctr.Z - FCurBias);
    SetLength(P^.Pts, 4);
    P^.Pts[0] := Proj(B[i]);
    P^.Pts[1] := Proj(B[j]);
    P^.Pts[2] := Proj(T[j]);
    P^.Pts[3] := Proj(T[i]);
    P^.Edge := emMask;
    P^.EdgeMask := 1 or 4;
    if not Vis[(i + Segs - 1) mod Segs] then P^.EdgeMask := P^.EdgeMask or 8;
    if not Vis[j] then P^.EdgeMask := P^.EdgeMask or 2;
    if Wire then
    begin
      P^.EdgeC := BGRA(40, 50, 70, IfThen(Vis[i], 170, 50));
      P^.EdgeW := 0.9;
    end
    else
      P^.Tex := HatchFor(VDot(NV[i], FLight), Mat);
    if Ribbed then
    begin
      AddSeg(P, P^.Pts[0], P^.Pts[3]);
      if Segs > 100 then
      begin
        P^.SegC := BGRA(30, 30, 38, 175);
        P^.SegW := 0.9;
      end;
    end;
    if (Ticks > 0) and (i mod (Segs div Ticks) = 0) then
    begin
      // engraved scale: short ticks from the front rim, every fourth one long
      A := 0.35 + 0.3 * Ord(i mod (4 * (Segs div Ticks)) = 0);
      AddSeg(P, P^.Pts[3], PointF(P^.Pts[3].X + (P^.Pts[0].X - P^.Pts[3].X) * A,
                                  P^.Pts[3].Y + (P^.Pts[0].Y - P^.Pts[3].Y) * A));
    end;
    FinishPrim(P);
  end;
  FrontC := World(V3(FLX, FLY, Z0));
  NF := RotN(V3(0, 0, -1));
  if (Facing(NF, FrontC) > 0) and not Wire then
  begin
    P := NewPrim(1, FDist - FrontC.Z - FCurBias);
    SetLength(Pts2, Segs);
    for i := 0 to Segs - 1 do Pts2[Segs - 1 - i] := Proj(B[i]);
    P^.Pts := Pts2;
    P^.Edge := emAll;
    P^.Tex := HatchFor(VDot(NF, FLight), MatMetal);
    FinishPrim(P);
  end;
  if not CapFront then Exit;
  FrontC := World(V3(FLX, FLY, Z1));
  NF := RotN(V3(0, 0, 1));
  if (Facing(NF, FrontC) > 0) or Wire then
  begin
    P := NewPrim(1, FDist - FrontC.Z - FCurBias);
    SetLength(Pts2, Segs);
    for i := 0 to Segs - 1 do Pts2[i] := Proj(T[i]);
    P^.Pts := Pts2;
    P^.Edge := emAll;
    if not Wire then P^.Tex := HatchFor(VDot(NF, FLight), MatMetal);
    FinishPrim(P);
  end;
end;

// Glass, inner elements, iris and reflections, inside the front ring that ends at ZF.
procedure TCameraScene.AddFrontElement(ZF: single);
const
  Segs = 64;
  Blades = 9;
  RGlass = 3.65;
var
  P: PPrim;
  C, NF: TVec3;
  i: integer;
  A, R, Rot, Open: single;
  Pts2: array of TPointF;

  function Ring(Z, Rad, Ang: single): TPointF;
  begin
    Result := Proj(World(V3(FLX + Rad * Cos(Ang), FLY + Rad * Sin(Ang), Z)));
  end;

  procedure Circle(Z, Rad: single; Dest: PPrim);
  var
    k: integer;
  begin
    for k := 0 to Segs - 1 do
      AddSeg(Dest, Ring(Z, Rad, 2 * Pi * k / Segs), Ring(Z, Rad, 2 * Pi * (k + 1) / Segs));
  end;

  procedure Arc(Z, Rad, A0, A1: single; Dest: PPrim);
  var
    k: integer;
  begin
    for k := 0 to 11 do
      AddSeg(Dest, Ring(Z, Rad, A0 + (A1 - A0) * k / 12), Ring(Z, Rad, A0 + (A1 - A0) * (k + 1) / 12));
  end;

begin
  C := World(V3(FLX, FLY, ZF));
  NF := RotN(V3(0, 0, 1));
  if Facing(NF, C) <= 0 then Exit;
  // glass: light, with the rims of the elements behind it
  P := NewPrim(1, FDist - C.Z - FCurBias - 0.05);
  SetLength(Pts2, Segs);
  for i := 0 to Segs - 1 do Pts2[i] := Ring(ZF - 0.25, RGlass, 2 * Pi * i / Segs);
  P^.Pts := Pts2;
  P^.Tex := TexGlass;
  P^.Edge := emAll;
  P^.EdgeW := 1.5;
  P^.SegC := BGRA(40, 40, 48, 150);
  P^.SegW := 0.9;
  Circle(ZF - 0.25, RGlass - 0.25, P);
  Circle(ZF - 0.7, 3.2, P);
  Circle(ZF - 1.2, 2.75, P);
  FinishPrim(P);

  // iris, deep inside: a soft dark disc and the opening
  Open := Clamp01(Aperture);
  R := 2.3;
  P := NewPrim(1, FDist - C.Z - FCurBias - 0.1);
  SetLength(Pts2, Segs);
  for i := 0 to Segs - 1 do Pts2[i] := Ring(ZF - 1.7, R, 2 * Pi * i / Segs);
  P^.Pts := Pts2;
  P^.Tex := TexSolid;
  P^.Solid := BGRA(60, 62, 72, 95);
  P^.SegC := BGRA(40, 40, 50, 120);
  P^.SegW := 0.8;
  Rot := 0.9 * (1 - Open);
  for i := 0 to Blades - 1 do
  begin
    // one line per blade, from the opening edge out to the ring
    A := Rot + 2 * Pi * i / Blades;
    AddSeg(P, Ring(ZF - 1.7, Max(0.05, R * 0.8 * Open), A), Ring(ZF - 1.7, R * 0.98, A + 0.9));
  end;
  FinishPrim(P);

  P := NewPrim(1, FDist - C.Z - FCurBias - 0.15);
  SetLength(P^.Pts, Blades);
  for i := 0 to Blades - 1 do
    P^.Pts[i] := Ring(ZF - 1.7, Max(0.04, R * 0.8 * Open), Rot + 2 * Pi * i / Blades);
  P^.Tex := TexSolid;
  P^.Solid := BGRA(20, 20, 28, 150 + Round(80 * (1 - Open)));
  P^.Edge := emAll;
  P^.EdgeW := 0.8;
  P^.EdgeC := BGRA(30, 30, 40, 160);
  FinishPrim(P);

  // reflections: dark crescent at the bottom right, bright window and arcs top left
  P := NewPrim(1, FDist - C.Z - FCurBias - 0.2);
  SetLength(P^.Pts, 24);
  for i := 0 to 11 do
  begin
    A := -1.9 + 2.2 * i / 11;
    P^.Pts[i] := Ring(ZF - 0.25, RGlass - 0.3, A);
    P^.Pts[23 - i] := Ring(ZF - 0.25, RGlass - 1.0 + 0.4 * Abs(i - 5.5) / 5.5, A);
  end;
  P^.Tex := TexSolid;
  P^.Solid := BGRA(30, 30, 38, 120);
  FinishPrim(P);

  P := NewPrim(1, FDist - C.Z - FCurBias - 0.25);
  P^.SegC := BGRA(255, 255, 255, 230);
  P^.SegW := 2.4;
  Arc(ZF - 0.25, 3.1, 1.9, 2.9, P);
  Arc(ZF - 0.25, 2.6, 2.05, 2.6, P);
  SetLength(P^.Pts, 12);
  for i := 0 to 5 do
  begin
    A := 2.0 + 0.7 * i / 5;
    P^.Pts[i] := Ring(ZF - 0.7, 2.35, A);
    P^.Pts[11 - i] := Ring(ZF - 0.7, 1.45, A);
  end;
  P^.Tex := TexSolid;
  P^.Solid := BGRA(255, 255, 255, 120);
  FinishPrim(P);

  // engraving on the front ring
  AddFaceLabels(ZF, 3.98, ['LAZRA', 'ZOOM', '24-70mm', '1:2.8', #$C3#$98'82', 'MACRO'],
    [1.7, 1.15, 0.55, -0.1, -0.75, 2.45]);
end;

// Extruded prism along Y: Poly is the outline in the X/Z plane (convex).
procedure TCameraScene.AddExtrudeY(const Poly: array of TPointF; Y0, Y1: single; Mat: integer;
  CapTop, CapBottom: boolean);
begin
  AddLoftY(Poly, Poly, Y0, Y1, Mat, CapTop, CapBottom);
end;

// Loft along Y from outline PB at Y0 to outline PT at Y1 (same point count,
// both convex in the X/Z plane). Side faces are shaded one by one like a
// cylinder; sharp corners and the silhouette get lines along the side, the
// rims get the top and bottom outlines.
procedure TCameraScene.AddLoftY(const PB, PT: array of TPointF; Y0, Y1: single; Mat: integer;
  CapTop, CapBottom: boolean);
var
  n, i, j, h: integer;
  B, T, NV, NM: array of TVec3;
  Vis: array of boolean;
  Cx, Cz: single;
  Ctr, NC, MB0, MB1, MT0, Mid: TVec3;
  P: PPrim;
  Pts2: array of TPointF;
begin
  n := Length(PB);
  SetLength(B, n);
  SetLength(T, n);
  SetLength(NV, n);
  SetLength(NM, n);
  SetLength(Vis, n);
  Cx := 0;
  Cz := 0;
  for i := 0 to n - 1 do
  begin
    Cx := Cx + (PB[i].X + PT[i].X) / (2 * n);
    Cz := Cz + (PB[i].Y + PT[i].Y) / (2 * n);
    B[i] := World(V3(PB[i].X, Y0, PB[i].Y));
    T[i] := World(V3(PT[i].X, Y1, PT[i].Y));
  end;
  for i := 0 to n - 1 do
  begin
    j := (i + 1) mod n;
    // side normal from the face itself (it leans in on a loft), pointing away from the centre
    MB0 := V3(PB[i].X, Y0, PB[i].Y);
    MB1 := V3(PB[j].X, Y0, PB[j].Y);
    MT0 := V3(PT[i].X, Y1, PT[i].Y);
    NM[i] := VNorm(VCross(VSub(MB1, MB0), VSub(MT0, MB0)));
    Mid := VMul(VAdd(VAdd(MB0, MB1), VAdd(MT0, V3(PT[j].X, Y1, PT[j].Y))), 0.25);
    if VDot(NM[i], VSub(Mid, V3(Cx, (Y0 + Y1) / 2, Cz))) < 0 then NM[i] := VMul(NM[i], -1);
    NV[i] := RotN(NM[i]);
    Ctr := VMul(VAdd(VAdd(B[i], B[j]), VAdd(T[i], T[j])), 0.25);
    Vis[i] := Facing(NV[i], Ctr) > 0;
  end;
  for i := 0 to n - 1 do
  begin
    if not Vis[i] and not Wire then Continue;
    j := (i + 1) mod n;
    h := (i + n - 1) mod n;
    Ctr := VMul(VAdd(VAdd(B[i], B[j]), VAdd(T[i], T[j])), 0.25);
    P := NewPrim(1, FDist - Ctr.Z - FCurBias);
    SetLength(P^.Pts, 4);
    P^.Pts[0] := Proj(B[i]);
    P^.Pts[1] := Proj(B[j]);
    P^.Pts[2] := Proj(T[j]);
    P^.Pts[3] := Proj(T[i]);
    P^.Edge := emMask;
    P^.EdgeMask := 1 or 4;
    if not Vis[h] or (VDot(NM[h], NM[i]) < 0.8) then P^.EdgeMask := P^.EdgeMask or 8;
    if not Vis[j] or (VDot(NM[j], NM[i]) < 0.8) then P^.EdgeMask := P^.EdgeMask or 2;
    P^.Sketchy := True;
    if Wire then
    begin
      P^.EdgeC := BGRA(40, 50, 70, IfThen(Vis[i], 180, 60));
      P^.EdgeW := 0.9;
    end
    else
      P^.Tex := HatchFor(VDot(NV[i], FLight), Mat);
    FinishPrim(P);
  end;
  for h := 0 to 1 do
  begin
    if (h = 0) and not CapTop then Continue;
    if (h = 1) and not CapBottom then Continue;
    NC := RotN(V3(0, 1 - 2 * h, 0));
    if h = 0 then Ctr := World(V3(Cx, Y1, Cz)) else Ctr := World(V3(Cx, Y0, Cz));
    if (Facing(NC, Ctr) <= 0) and not Wire then Continue;
    P := NewPrim(1, FDist - Ctr.Z - FCurBias);
    if (h = 0) and not FOnSupport then FSupportDepth := Min(FSupportDepth, P^.Depth);
    SetLength(Pts2, n);
    for i := 0 to n - 1 do
      if h = 0 then Pts2[i] := Proj(T[i]) else Pts2[i] := Proj(B[i]);
    P^.Pts := Pts2;
    P^.Edge := emAll;
    if not Wire then P^.Tex := HatchFor(VDot(NC, FLight), MatMetal);
    FinishPrim(P);
  end;
end;

// Markings on the top of a dial (rotating with it).
procedure TCameraScene.AddTopLabels(CX, CY, CZ, R, Phase: single; const Texts: array of string;
  const Angles: array of single);
var
  i: integer;
  A, F: single;
  V: TVec3;
  S: TPointF;
begin
  V := World(V3(CX, CY, CZ));
  F := Facing(RotN(V3(0, 1, 0)), V) / Max(1, FDist - V.Z);
  if F < 0.15 then Exit;
  for i := 0 to High(Texts) do
  begin
    A := Phase + Angles[i];
    // the prism or the body may stand between the eye and the dial
    if Occluded(VAdd(V3(CX + R * Cos(A), CY, CZ - R * Sin(A)), FCur)) then Continue;
    S := Proj(World(V3(CX + R * Cos(A), CY, CZ - R * Sin(A))));
    AddLabel(S.X, S.Y, Texts[i], lkTiny, FCurReveal * Smooth((F - 0.15) / 0.25) * (1 - Clamp01(Explode * 3)));
  end;
end;

// Engraving on a front-facing ring face of the lens.
procedure TCameraScene.AddFaceLabels(Z, R: single; const Texts: array of string; const Angles: array of single);
var
  i: integer;
  F: single;
  V: TVec3;
  S: TPointF;
begin
  V := World(V3(FLX, FLY, Z));
  F := Facing(RotN(V3(0, 0, 1)), V) / Max(1, FDist - V.Z);
  if F < 0.2 then Exit;
  for i := 0 to High(Texts) do
  begin
    if Occluded(VAdd(V3(FLX + R * Cos(Angles[i]), FLY + R * Sin(Angles[i]), Z), FCur)) then Continue;
    S := Proj(World(V3(FLX + R * Cos(Angles[i]), FLY + R * Sin(Angles[i]), Z)));
    AddLabel(S.X, S.Y, Texts[i], lkTiny, FCurReveal * Smooth((F - 0.2) / 0.3) * (1 - Clamp01(Explode * 3)));
  end;
end;

procedure TCameraScene.AddLine3D(const Pts: array of TVec3; ALayer: byte; C: TBGRAPixel; W: single;
  Closed: boolean);
var
  P: PPrim;
  i, n: integer;
  D: single;
begin
  n := Length(Pts);
  D := 0;
  for i := 0 to n - 1 do D := D + FDist - World(Pts[i]).Z;
  P := NewPrim(ALayer, D / n - FCurBias);
  P^.SegC := C;
  P^.SegW := W;
  for i := 0 to n - 2 + Ord(Closed) do
    AddSeg(P, Proj(World(Pts[i])), Proj(World(Pts[(i + 1) mod n])));
  FinishPrim(P);
end;

procedure TCameraScene.AddDashed(const A, B: TVec3; C: TBGRAPixel; W: single; DashDot: boolean);
var
  P: PPrim;
  S, E, D: TPointF;
  L, T, Step: single;
begin
  S := Proj(ToView(A));
  E := Proj(ToView(B));
  D := E - S;
  L := Sqrt(D.X * D.X + D.Y * D.Y);
  if L < 2 then Exit;
  P := NewPrim(2, 0);
  P^.SegC := C;
  P^.SegW := W;
  T := 0;
  while T < L do
  begin
    Step := Min(14, L - T);
    AddSeg(P, S + D * (T / L), S + D * ((T + Step) / L));
    T := T + 18;
    if DashDot and (T + 2 < L) then
    begin
      AddSeg(P, S + D * (T / L), S + D * ((T + 1.5) / L));
      T := T + 4;
    end;
  end;
  FinishPrim(P);
end;

// Dimension: extension lines from A and B along Off, a dimension line with arrows, the value.
procedure TCameraScene.AddDim(const A, B, Off: TVec3; const AText: string; Reveal: single; LabelAt: single);
var
  P: PPrim;
  A0, A1, B0, B1, D, N, M: TPointF;
  L: single;

  procedure Arrow(const Tip, Dir: TPointF);
  var
    Q: PPrim;
  begin
    Q := NewPrim(2, 0);
    Q^.Reveal := Reveal;
    SetLength(Q^.Pts, 3);
    Q^.Pts[0] := Tip;
    Q^.Pts[1] := Tip + Dir * 9 + PointF(-Dir.Y, Dir.X) * 2.6;
    Q^.Pts[2] := Tip + Dir * 9 - PointF(-Dir.Y, Dir.X) * 2.6;
    Q^.Tex := TexSolid;
    Q^.Solid := DimInk;
    FinishPrim(Q);
  end;

begin
  if Reveal <= 0 then Exit;
  A0 := Proj(ToView(VAdd(A, VMul(Off, 0.18))));
  A1 := Proj(ToView(VAdd(A, VMul(Off, 1.15))));
  B0 := Proj(ToView(VAdd(B, VMul(Off, 0.18))));
  B1 := Proj(ToView(VAdd(B, VMul(Off, 1.15))));
  P := NewPrim(2, 0);
  P^.Reveal := Reveal;
  P^.SegC := DimInk;
  P^.SegW := 0.85;
  AddSeg(P, A0, A1);
  AddSeg(P, B0, B1);
  A1 := Proj(ToView(VAdd(A, Off)));
  B1 := Proj(ToView(VAdd(B, Off)));
  AddSeg(P, A1, B1);
  FinishPrim(P);
  D := B1 - A1;
  L := Sqrt(D.X * D.X + D.Y * D.Y);
  if L < 30 then Exit;
  D := D * (1 / L);
  Arrow(A1, D);
  Arrow(B1, D * -1);
  M := A1 + (B1 - A1) * LabelAt;
  N := PointF(-D.Y, D.X);
  if N.Y > 0 then N := N * -1;       // label above the line
  AddLabel(M.X + N.X * 13, M.Y + N.Y * 13, AText, lkDim, Smooth((Reveal - 0.6) / 0.4));
end;

procedure TCameraScene.AddGround;
const
  G = -4.5;
var
  i: integer;
  X, Z, A: single;
  C: TBGRAPixel;
begin
  FPart := -1;
  FKind := okGrid;
  FCur := V3(0, 0, 0);
  FCurBias := 0;
  FCurReveal := Clamp01(RevealTime / 0.8);
  for i := -12 to 12 do
  begin
    X := i * 2.2;
    A := 1 - Abs(i) / 13;
    C := BGRA(80, 95, 120, Round(55 * A * A));
    if C.alpha < 4 then Continue;
    AddLine3D([V3(X, G, -18), V3(X, G, -9), V3(X, G, 0), V3(X, G, 9), V3(X, G, 18), V3(X, G, 27)], 0, C, 0.7, False);
  end;
  for i := -8 to 12 do
  begin
    Z := i * 2.2;
    A := 1 - Abs(i - 2) / 11;
    C := BGRA(80, 95, 120, Round(55 * A * A));
    if C.alpha < 4 then Continue;
    AddLine3D([V3(-26, G, Z), V3(-13, G, Z), V3(0, G, Z), V3(13, G, Z), V3(26, G, Z)], 0, C, 0.7, False);
  end;
  for i := FCount - 1 downto 0 do
    if FPrims[i].Layer = 0 then FPrims[i].Depth := 3e9;
end;

// Hatched shadow on the ground: convex hull of the model's corners projected along the light.
// View space -> model space (inverse pitch, inverse yaw, add the pivot).
function TCameraScene.FromView(const V: TVec3): TVec3;
var
  Y, Z, X: single;
begin
  Y := V.Y * FCosP + V.Z * FSinP;
  Z := -V.Y * FSinP + V.Z * FCosP;
  X := V.X * FCosY - Z * FSinY;
  Z := V.X * FSinY + Z * FCosY;
  Result := VAdd(V3(X, Y, Z), FPivot);
end;

// Is the assembled point A hidden from the eye by the body, grip, prism or lens?
// Ray / box slab tests; a point on a box surface facing the eye is not hidden.
function TCameraScene.Occluded(const A: TVec3): boolean;

  function HitsBox(const O, D: TVec3; X0, Y0, Z0, X1, Y1, Z1: single): boolean;
  var
    TEnter, TExit, T0, T1, T: single;

    procedure Slab(O1, D1, Lo, Hi: single);
    begin
      if Abs(D1) < 1e-9 then
      begin
        if (O1 < Lo) or (O1 > Hi) then TEnter := 2;
        Exit;
      end;
      T0 := (Lo - O1) / D1;
      T1 := (Hi - O1) / D1;
      if T0 > T1 then
      begin
        T := T0; T0 := T1; T1 := T;
      end;
      if T0 > TEnter then TEnter := T0;
      if T1 < TExit then TExit := T1;
    end;

  begin
    TEnter := 0;
    TExit := 1;
    Slab(O.X, D.X, X0, X1);
    Slab(O.Y, D.Y, Y0, Y1);
    Slab(O.Z, D.Z, Z0, Z1);
    Result := (TEnter < TExit) and (TEnter < 0.985);
  end;

var
  E, D: TVec3;
  ZF: single;
begin
  E := FromView(V3(0, 0, FDist));
  D := VSub(A, E);
  ZF := 13.0 + 2.8 * Zoom;
  Result := HitsBox(E, D, -7, -4.5, -2.5, 7, 4.5, 2.5) or
    HitsBox(E, D, -6.8, -4.5, 2.5, -4.1, 4.4, 4.5) or
    HitsBox(E, D, -2.4, 4.5, -1.6, 2.4, 7.2, 1.8) or
    HitsBox(E, D, -2.5, 4.8, 2.4, 2.5, 5.7, 2.9) or
    HitsBox(E, D, 0.6 - 3.5, -0.2 - 3.5, 2.5, 0.6 + 3.5, -0.2 + 3.5, ZF);
end;

procedure TCameraScene.AddShadow;
const
  G = -4.5;
var
  L: TVec3;
  Src: array of TVec3;
  Pts, Hull: array of TPointF;
  i, j, k, n: integer;
  T, Ext: single;
  P: PPrim;
  Tmp: TPointF;

  function Cross(const O, A, B: TPointF): single;
  begin
    Result := (A.X - O.X) * (B.Y - O.Y) - (A.Y - O.Y) * (B.X - O.X);
  end;

begin
  FPart := -1;
  FKind := okShadow;
  // the light is fixed in view space; bring it back into model space
  L := FLight;
  T := L.Y * FCosP + L.Z * FSinP;              // inverse pitch
  L.Z := -L.Y * FSinP + L.Z * FCosP;
  L.Y := T;
  T := L.X * FCosY - L.Z * FSinY;              // inverse yaw
  L.Z := L.X * FSinY + L.Z * FCosY;
  L.X := T;
  if L.Y < 0.25 then L.Y := 0.25;
  Ext := 13.0 + 2.8 * Zoom;
  Src := nil;
  SetLength(Src, 0);
  for i := 0 to 7 do
  begin
    SetLength(Src, Length(Src) + 1);
    Src[High(Src)] := V3(IfThen(i and 1 = 0, -7.4, 7.5), IfThen(i and 2 = 0, -4.5, 7.9),
      IfThen(i and 4 = 0, -2.5, 4.6));
  end;
  for i := 0 to 11 do
  begin
    SetLength(Src, Length(Src) + 1);
    Src[High(Src)] := V3(FLX + 4.3 * Cos(i * Pi / 6), FLY + 4.3 * Sin(i * Pi / 6), Ext);
  end;
  n := Length(Src);
  SetLength(Pts, n);
  FCur := V3(0, 0, 0);
  for i := 0 to n - 1 do
  begin
    T := (Src[i].Y - G) / L.Y;
    Pts[i] := Proj(ToView(V3(Src[i].X - L.X * T, G, Src[i].Z - L.Z * T)));
  end;
  // monotone chain hull
  for i := 1 to n - 1 do
  begin
    Tmp := Pts[i];
    j := i - 1;
    while (j >= 0) and ((Pts[j].X > Tmp.X) or ((Pts[j].X = Tmp.X) and (Pts[j].Y > Tmp.Y))) do
    begin
      Pts[j + 1] := Pts[j];
      Dec(j);
    end;
    Pts[j + 1] := Tmp;
  end;
  SetLength(Hull, 2 * n);
  k := 0;
  for i := 0 to n - 1 do
  begin
    while (k >= 2) and (Cross(Hull[k - 2], Hull[k - 1], Pts[i]) <= 0) do Dec(k);
    Hull[k] := Pts[i];
    Inc(k);
  end;
  j := k + 1;
  for i := n - 2 downto 0 do
  begin
    while (k >= j) and (Cross(Hull[k - 2], Hull[k - 1], Pts[i]) <= 0) do Dec(k);
    Hull[k] := Pts[i];
    Inc(k);
  end;
  if k < 4 then Exit;
  FCurReveal := Clamp01((RevealTime - 2.2) / 0.8);
  P := NewPrim(0, 2e9);
  SetLength(P^.Pts, k - 1);
  for i := 0 to k - 2 do P^.Pts[i] := Hull[i];
  P^.Tex := TexLight;
  P^.Edge := emAll;
  P^.EdgeW := 0.7;
  P^.EdgeC := BGRA(60, 60, 70, 60);
  FinishPrim(P);
end;

// Long perspective guide lines through the body edges, like the underdrawing of a sketch.
procedure TCameraScene.AddConstruction;
const
  E: array[0..11, 0..1] of integer = ((0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4),
    (0, 4), (1, 5), (2, 6), (3, 7));
var
  C: array[0..7] of TVec3;
  i: integer;
  A, B, D: TVec3;
  P: PPrim;
begin
  FPart := -1;
  FKind := okConstruct;
  FCur := V3(0, 0, 0);
  FCurBias := 0;
  FCurReveal := Clamp01((RevealTime - 0.1) / 1.2);
  C[0] := V3(-7, -4.5, 2.5); C[1] := V3(7, -4.5, 2.5); C[2] := V3(7, -4.5, -2.5); C[3] := V3(-7, -4.5, -2.5);
  C[4] := V3(-7, 4.5, 2.5);  C[5] := V3(7, 4.5, 2.5);  C[6] := V3(7, 4.5, -2.5);  C[7] := V3(-7, 4.5, -2.5);
  P := NewPrim(0, 1e9);
  P^.SegC := Construct;
  P^.SegW := 0.8;
  for i := 0 to 11 do
  begin
    A := C[E[i, 0]];
    B := C[E[i, 1]];
    D := VSub(B, A);
    AddSeg(P, Proj(ToView(VSub(A, VMul(D, 0.55)))), Proj(ToView(VAdd(B, VMul(D, 0.55)))));
  end;
  FinishPrim(P);
end;

procedure TCameraScene.AddRingLabels(Z, R, Phase: single; const Texts: array of string;
  const Angles: array of single);
var
  i: integer;
  A, F: single;
  V, NV: TVec3;
  S: TPointF;
begin
  for i := 0 to High(Texts) do
  begin
    A := Phase + Angles[i];
    V := World(V3(FLX + R * Cos(A), FLY + R * Sin(A), Z));
    NV := RotN(V3(Cos(A), Sin(A), 0));
    F := Facing(NV, V) / Max(1, FDist - V.Z);
    if F < 0.35 then Continue;
    if Occluded(VAdd(V3(FLX + R * Cos(A), FLY + R * Sin(A), Z), FCur)) then Continue;
    S := Proj(V);
    AddLabel(S.X, S.Y, Texts[i], lkTiny, FCurReveal * Smooth((F - 0.35) / 0.3) * (1 - Clamp01(Explode * 3)));
  end;
end;

procedure TCameraScene.AddCallouts;
type
  TCall = record
    A, L: TPointF;
    Part: integer;
    Right: boolean;
  end;
var
  Calls: array of TCall;
  i, j, k, n: integer;
  Mid, D, S: TPointF;
  Len, Alpha, Gap: single;
  P: PPrim;
  Ex: single;
  Tmp: TCall;
  Text: string;
  Kind: TLabelKind;
begin
  FPart := -1;
  FKind := okCallout;
  Ex := Clamp01(Explode);
  Alpha := Max(Smooth((Ex - 0.35) / 0.4), Ord(ShowLabels) * 0.85);
  if Alpha <= 0 then Exit;
  Mid := PointF((FBoxMin.X + FBoxMax.X) / 2, (FBoxMin.Y + FBoxMax.Y) / 2);
  SetLength(Calls, PartCount);
  n := 0;
  for i := 0 to PartCount - 1 do
  begin
    if (Ex < 0.3) and not (i in [PPrism, PShutterDial, PIsoDial, PRelease, PGrip, PZoom, PFocus, PFront, PLug, PMount]) then
      Continue;
    // assembled: no tag for a part hidden behind the camera body or lens
    if (Ex < 0.3) and Occluded(Parts[i].Anchor) then Continue;
    FCur := VMul(Parts[i].Offset, Explode * Spread);
    S := Proj(World(Parts[i].Anchor));
    Calls[n].A := S;
    Calls[n].Part := i;
    D := S - Mid;
    Len := Sqrt(D.X * D.X + D.Y * D.Y);
    if Len < 1 then D := PointF(1, 0) else D := D * (1 / Len);
    Calls[n].Right := D.X >= 0;
    Calls[n].L := S + D * (40 + 30 * Ex);
    Inc(n);
  end;
  // keep labels on each side apart vertically
  for i := 1 to n - 1 do
  begin
    Tmp := Calls[i];
    j := i - 1;
    while (j >= 0) and (Calls[j].L.Y > Tmp.L.Y) do
    begin
      Calls[j + 1] := Calls[j];
      Dec(j);
    end;
    Calls[j + 1] := Tmp;
  end;
  Gap := IfThen(Ex >= 0.3, 22, 26);
  for i := 1 to n - 1 do
  begin
    // previous label on the same side
    k := i - 1;
    while (k >= 0) and (Calls[k].Right <> Calls[i].Right) do Dec(k);
    if (k >= 0) and (Calls[i].L.Y - Calls[k].L.Y < Gap) then
      Calls[i].L.Y := Calls[k].L.Y + Gap;
  end;
  for i := 0 to n - 1 do
  begin
    FCurReveal := Clamp01((RevealTime - 2.6 - i * 0.06) / 0.5) * Alpha;
    if FCurReveal <= 0 then Continue;
    P := NewPrim(2, 0);
    P^.SegC := DimInk;
    P^.SegW := 0.8;
    S := Calls[i].L + PointF(IfThen(Calls[i].Right, 16, -16), 0);
    AddSeg(P, Calls[i].A, Calls[i].L);
    AddSeg(P, Calls[i].L, S);
    SetLength(P^.Pts, 8);
    for j := 0 to 7 do
      P^.Pts[j] := Calls[i].A + PointF(2.4 * Cos(j * Pi / 4), 2.4 * Sin(j * Pi / 4));
    P^.Tex := TexSolid;
    P^.Solid := DimInk;
    FinishPrim(P);
    if Ex >= 0.3 then
      Text := Format('%.2d  %s', [Calls[i].Part + 1, Parts[Calls[i].Part].Name])
    else
      Text := IntToStr(Calls[i].Part + 1);
    if Ex >= 0.3 then Kind := lkCallout else Kind := lkTag;
    if Calls[i].Right then
      AddLabel(S.X + 3, S.Y, Text, Kind, FCurReveal, taLeftJustify)
    else
      AddLabel(S.X - 3, S.Y, Text, Kind, FCurReveal, taRightJustify);
  end;
end;

procedure TCameraScene.SortPrims;

  function Less(A, B: integer): boolean; inline;
  begin
    if FPrims[A].Layer <> FPrims[B].Layer then
      Result := FPrims[A].Layer < FPrims[B].Layer
    else
      Result := FPrims[A].Depth > FPrims[B].Depth;
  end;

  procedure QSort(L, R: integer);
  var
    i, j, Pv, T: integer;
  begin
    repeat
      i := L;
      j := R;
      Pv := FOrder[(L + R) shr 1];
      repeat
        while Less(FOrder[i], Pv) do Inc(i);
        while Less(Pv, FOrder[j]) do Dec(j);
        if i <= j then
        begin
          T := FOrder[i];
          FOrder[i] := FOrder[j];
          FOrder[j] := T;
          Inc(i);
          Dec(j);
        end;
      until i > j;
      if L < j then QSort(L, j);
      L := i;
    until i >= R;
  end;

var
  i: integer;
begin
  if Length(FOrder) < FCount then SetLength(FOrder, Length(FPrims));
  for i := 0 to FCount - 1 do FOrder[i] := i;
  if FCount > 1 then QSort(0, FCount - 1);
end;

procedure TCameraScene.Build(W, H: integer);
var
  Ex, Ext, ZI, ZF: single;
  i, k, First: integer;
  DimR: single;
begin
  FCount := 0;
  FLabelCount := 0;
  FOnSupport := False;
  FSupportDepth := 1e9;
  Ex := Explode;
  FCx := W * 0.5;
  FCy := H * 0.52;
  FFocal := Min(W, H * 1.35) * 1.55;
  FDist := Distance + 34 * Clamp01(Ex);
  FCosY := Cos(Yaw);
  FSinY := Sin(Yaw);
  FCosP := Cos(Pitch);
  FSinP := Sin(Pitch);
  FPivot := V3(0.4, 0.6 + 2.6 * Ex, 4.2 + 7.5 * Ex);
  FLight := VNorm(V3(-0.5, 0.72, 0.48));
  Ext := 2.8 * Zoom;

  AddGround;
  if not Wire then AddShadow;
  AddConstruction;

  First := FCount;
  // ---- body: rounded plates and a leatherette band set back a little
  BeginPart(PBody);
  AddExtrudeY(RoundRectXZ(-7, -2.5, 7, 2.5, 1.0), -4.5, -3.9, MatMetal, False, True);
  AddExtrudeY(RoundRectXZ(-6.9, -2.4, 6.9, 2.4, 0.95), -3.9, 2.6, MatLeather, False, False);
  BeginPart(PTop);
  AddExtrudeY(RoundRectXZ(-7, -2.5, 7, 2.5, 1.0), 2.6, 4.15, MatMetal, False, False);
  AddExtrudeY(RoundRectXZ(-6.8, -2.3, 6.8, 2.3, 0.85), 4.15, 4.5, MatMetal, True, False);
  // the top plate wraps forward over the grip as a raised deck for the shutter release
  AddExtrudeY(GripOutline(-7.0, 2.45, -3.9, 4.7, 1.3), 2.6, 4.15, MatMetal, False, False);
  AddExtrudeY(GripOutline(-6.8, 2.3, -4.1, 4.5, 1.15), 4.15, 4.5, MatMetal, True, False);
  AddFace([V3(-7.0, 2.6, 1.5), V3(-7.0, 2.6, 2.45), V3(-7.0, 4.15, 2.45), V3(-7.0, 4.15, 1.5)], MatMetal);
  FOnSupport := True;
  BeginPart(PPrism);
  // housing in three tiers with chamfered corners: an upright base, the sloping
  // prism hood, a bevelled roof
  AddLoftY(ChamferRectXZ(-3.0, -2.3, 3.0, 2.5, 0.45), ChamferRectXZ(-2.9, -2.2, 2.9, 2.35, 0.45),
    4.5, 5.5, MatMetal, False, False);
  AddLoftY(ChamferRectXZ(-2.9, -2.2, 2.9, 2.35, 0.45), ChamferRectXZ(-2.0, -1.3, 2.0, 1.35, 0.35),
    5.5, 7.05, MatMetal, False, False);
  AddLoftY(ChamferRectXZ(-2.0, -1.3, 2.0, 1.35, 0.35), ChamferRectXZ(-1.7, -1.05, 1.7, 1.1, 0.3),
    7.05, 7.4, MatMetal, True, False);
  // name plate: a ledge standing out over the lens mount, the brand on its face
  AddHexa([V3(-2.7, 4.75, 3.0), V3(2.7, 4.75, 3.0), V3(2.7, 4.75, 2.35), V3(-2.7, 4.75, 2.35),
           V3(-2.6, 5.75, 2.85), V3(2.6, 5.75, 2.85), V3(2.6, 5.75, 2.3), V3(-2.6, 5.75, 2.3)],
    MatMetal, 2, DecalBrand);
  // rubber eyecup and the viewfinder window at the back
  AddExtrudeY(RoundRectXZ(-1.8, -3.05, 1.8, -2.15, 0.35), 5.0, 6.7, MatRubber, True, True);
  AddBox(-1.15, 5.4, -3.12, 1.15, 6.3, -3.05, MatRubber);
  BeginPart(PShoe);
  // hot shoe: base plate, two rails, three contacts
  AddBox(-1.45, 7.4, -1.0, 1.45, 7.55, 1.05, MatMetal);
  AddBox(-1.45, 7.55, -1.0, -0.95, 7.85, 1.05, MatMetal);
  AddBox(0.95, 7.55, -1.0, 1.45, 7.85, 1.05, MatMetal);
  AddCylY(0, 7.55, 0.1, 0.18, 0.05, 12, False, 0, MatMetal);
  AddCylY(-0.45, 7.55, 0.45, 0.13, 0.05, 12, False, 0, MatMetal);
  AddCylY(0.45, 7.55, 0.45, 0.13, 0.05, 12, False, 0, MatMetal);
  BeginPart(PShutterDial);
  AddCylY(4.6, 4.5, 0.2, 2.2, 0.15, 64, False, 0, MatMetal);
  AddCylY(4.6, 4.65, 0.2, 2.0, 0.95, 60, True, ShutterDial, MatTeeth, 8);
  AddCylY(4.6, 5.6, 0.2, 0.75, 0.3, 40, True, ShutterDial, MatTeeth, 0);
  AddTopLabels(4.6, 5.6, 0.2, 1.48, ShutterDial, ['60', '125', '250', '500', '1000', 'B'],
    [0.9, 0.3, -0.3, -0.9, -1.5, 1.6]);
  BeginPart(PIsoDial);
  AddCylY(-4.9, 4.5, -0.8, 1.7, 0.15, 56, False, 0, MatMetal);
  AddCylY(-4.9, 4.65, -0.8, 1.5, 0.65, 48, True, IsoDial, MatTeeth, 7);
  AddCylY(-4.9, 5.3, -0.8, 0.95, 0.45, 40, True, IsoDial, MatTeeth, 0);
  AddTopLabels(-4.9, 5.3, -0.8, 1.2, IsoDial, ['100', '400', '1600'], [0.2, -0.7, -1.6]);
  BeginPart(PRelease);
  AddCylY(-5.4, 4.5, 3.3, 0.95, 0.3, 40, True, 0, MatTeeth);
  AddCylY(-5.4, 4.8, 3.3, 0.55, 0.5 - 0.3 * ButtonDown, 28, False, 0, MatMetal);
  AddBox(-6.55, 4.5, 3.0, -6.15, 4.72, 3.6, MatMetal);        // power switch lever
  AddCylY(-3.5, 4.5, 1.7, 0.36, 0.28, 20, False, 0, MatMetal);  // function buttons
  AddCylY(-6.3, 4.5, 1.2, 0.32, 0.25, 20, False, 0, MatMetal);
  FOnSupport := False;
  BeginPart(PGrip);
  // flat back against the body front, rounded towards the hand
  AddExtrudeY(GripOutline(-6.9, 2.45, -3.9, 4.7, 1.3), -4.3, 2.6, MatRubber, False, False);
  // the body's rounded front-left corner leaves a notch behind the grip:
  // close it with a side panel flush with the leatherette
  AddFace([V3(-6.9, -4.3, 1.45), V3(-6.9, -4.3, 2.45), V3(-6.9, 2.6, 2.45), V3(-6.9, 2.6, 1.45)], MatLeather);
  BeginPart(PLug);
  AddBox(7, 2.2, -0.35, 7.5, 3.2, 0.35, MatMetal);
  AddLine3D([V3(7.5, 2.7, 0), V3(8.4, 1.3, 0.7), V3(8.4, 1.3, -0.7)], 1, Graphite, 1.6, True);
  AddLine3D([V3(8.2, 1.5, 0.5), V3(8.9, 0.2, 0.3), V3(8.9, 0.2, -0.3), V3(8.2, 1.5, -0.5)], 1, Graphite, 1.3, True);

  // ---- lens: light metal rings, the grip rings carry dense fine knurling
  BeginPart(PMount);
  AddCylZ(2.5, 3.0, 3.55, 3.55, 64, False, 0, MatMetal, 32);
  BeginPart(PRear);
  AddCylZ(3.0, 3.9, 3.4, 3.45, 64, False, 0, MatMetal);
  BeginPart(PZoom);
  AddCylZ(3.9, 7.6, 3.75, 3.75, 150, True, Zoom * 1.4, MatKnurl);
  AddRingLabels(7.35, 3.78, Zoom * 1.4, ['24', '35', '50', '70'], [1.9, 1.55, 1.2, 0.85]);
  BeginPart(PScale);
  AddCylZ(7.6, 8.4, 3.5, 3.5, 72, False, 0, MatMetal, 36);
  AddRingLabels(8.0, 3.52, Focus, [#$E2#$88#$9E, '10', '5', '3', '2', '1.5', '1', '0.8'],
    [2.6, 2.35, 2.1, 1.85, 1.6, 1.35, 1.1, 0.85]);
  BeginPart(PFocus);
  AddCylZ(8.4, 10.6, 3.8, 3.8, 160, True, Focus, MatKnurl);
  BeginPart(PInner);
  ZI := 10.6 + 0.5 + Ext;
  AddCylZ(10.6, ZI, 3.45, 3.45, 64, False, 0, MatMetal, 0);
  BeginPart(PHood);
  AddCylZ(ZI, ZI + 0.7, 3.55, 4.25, 72, False, 0, MatMetal, 0, False);
  ZF := ZI + 1.9;
  AddCylZ(ZI + 0.7, ZF, 4.3, 4.3, 120, True, 0, MatMetal, 0);
  BeginPart(PFront);
  AddFrontElement(ZF);

  // ---- small round parts off the lens axis: move the axis for them
  FLX := -2.9; FLY := 1.6;
  BeginPart(PLamp);
  AddCylZ(2.4, 2.8, 0.4, 0.35, 20, False, 0, MatMetal);
  FLX := 4.6; FLY := -1.6;
  BeginPart(PLensBtn);
  AddCylZ(2.4, 2.9, 0.6, 0.55, 24, False, 0, MatMetal);
  FLX := 0.6; FLY := -0.2;

  // screen bounds of the model, for the callout layout
  FBoxMin := PointF(1e9, 1e9);
  FBoxMax := PointF(-1e9, -1e9);
  for i := First to FCount - 1 do
    for k := 0 to High(FPrims[i].Pts) do
    begin
      FBoxMin.X := Min(FBoxMin.X, FPrims[i].Pts[k].X);
      FBoxMin.Y := Min(FBoxMin.Y, FPrims[i].Pts[k].Y);
      FBoxMax.X := Max(FBoxMax.X, FPrims[i].Pts[k].X);
      FBoxMax.Y := Max(FBoxMax.Y, FPrims[i].Pts[k].Y);
    end;

  // ---- annotation
  DimR := Clamp01((RevealTime - 3.0) / 0.9) * (1 - Smooth(Ex * 2.5));
  // the dimensions are laid out for a front view: fade them as the front turns away
  DimR := DimR * Smooth((Facing(RotN(V3(0, 0, 1)), ToView(V3(0, 0, 2.5))) / FDist - 0.05) / 0.3);
  FPart := -1;
  FKind := okDim;
  if (DimR > 0) and not Wire then
  begin
    FCur := V3(0, 0, 0);
    AddDim(V3(-7, 4.5, -2.5), V3(7, 4.5, -2.5), V3(0, 4.6, 0), '140', DimR, 0.3);
    AddDim(V3(7, -4.5, -2.5), V3(7, 4.5, -2.5), V3(3.6, 0, -0.8), '90', DimR, 0.62);
    AddDim(V3(FLX, FLY - 4.3, 2.5), V3(FLX, FLY - 4.3, ZF), V3(3.6, -0.2, 0),
      Format('%.1f', [(ZF - 2.5) * 10]), DimR);
  end;
  // lens axis as a dash-dot centre line
  FKind := okAxis;
  FCurReveal := Clamp01((RevealTime - 2.8) / 0.6);
  if FCurReveal > 0 then
    AddDashed(V3(FLX, FLY, -4), V3(FLX, FLY, ZF + 4 + 14 * Clamp01(Ex)), Construct, 0.8, True);
  // exploded view: dashed assembly paths from each part back to its seat
  FKind := okAssembly;
  if Ex > 0.05 then
  begin
    FCurReveal := Clamp01(Ex);
    for i := 0 to PartCount - 1 do
      if (Parts[i].Offset.X <> 0) or (Parts[i].Offset.Y <> 0) then
        AddDashed(Parts[i].Anchor, VAdd(Parts[i].Anchor, VMul(Parts[i].Offset, Ex * Spread)),
          BGRA(80, 95, 125, Round(150 * Clamp01(Ex))), 0.8, False);
  end;
  AddCallouts;
  SortPrims;
  ComputeStats;
end;

// Per part and per layer: prim count, screen bounds, depth range, reveal.
procedure TCameraScene.ComputeStats;

  procedure Clear(var S: TObjStat);
  begin
    S.Prims := 0;
    S.Box := RectF(1e9, 1e9, -1e9, -1e9);
    S.DMin := 1e9;
    S.DMax := -1e9;
    S.Reveal := 0;
    S.Occluded := False;
  end;

  procedure Add(var S: TObjStat; const P: TPrim);
  var
    k: integer;

    procedure Pt(const Q: TPointF);
    begin
      if Q.X < S.Box.Left then S.Box.Left := Q.X;
      if Q.Y < S.Box.Top then S.Box.Top := Q.Y;
      if Q.X > S.Box.Right then S.Box.Right := Q.X;
      if Q.Y > S.Box.Bottom then S.Box.Bottom := Q.Y;
    end;

  begin
    Inc(S.Prims);
    for k := 0 to High(P.Pts) do Pt(P.Pts[k]);
    for k := 0 to P.NSeg - 1 do Pt(P.Segs[k]);
    if P.Layer = 1 then
    begin
      S.DMin := Min(S.DMin, P.Depth);
      S.DMax := Max(S.DMax, P.Depth);
    end;
    S.Reveal := Max(S.Reveal, P.Reveal);
  end;

var
  i: integer;
begin
  for i := 0 to PartCount - 1 do Clear(PartStats[i]);
  for i := 0 to KindCount - 1 do Clear(KindStats[i]);
  for i := 0 to FCount - 1 do
  begin
    if FPrims[i].Part >= 0 then Add(PartStats[FPrims[i].Part], FPrims[i]);
    Add(KindStats[FPrims[i].Kind], FPrims[i]);
  end;
  if Explode < 0.3 then
    for i := 0 to PartCount - 1 do PartStats[i].Occluded := Occluded(Parts[i].Anchor);
end;

initialization
  Graphite := BGRA(34, 34, 40, 225);
  GraphiteSoft := BGRA(40, 40, 48, 140);
  Construct := BGRA(70, 95, 135, 75);
  DimInk := BGRA(46, 52, 66, 200);
end.
