unit UDocScene;

{ Turns a TSketchDoc into the display list the multi-core render pool draws.

  Shapes become rings of points (bottom / top outline), then side faces and
  two caps, transformed (scale, rotate X-Y-Z, move) into the world, culled,
  hatched by their angle to the light and sorted back to front. Edges are
  "hard" (always drawn when the face shows: rims, sharp corners) or "soft"
  (drawn only where the neighbouring face is turned away: the silhouette of
  a cylinder or a rounded corner).

  Draw groups (TPrim.Layer): 0 grid, 1 model, 2 annotations, 3+ sketch
  layers in order, 250 perspective guides. Text is returned in Labels for
  the window to draw.

  Picking: the face under a pixel (front-most first), and the 3D point
  where the view ray meets that face, snapped to a corner nearby. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes, UPrimTypes, UModel;

const
  kGrid = 0;
  kModel = 1;
  kAnnot = 2;
  kSketch = 3;
  kGuide = 4;

type
  TVec3Array = array of TVec3;
  TBoolArray = array of boolean;

  TEdLabelKind = (elDim, elLabel, elTag, elCallout);

  TEdLabel = record
    X, Y: single;
    Text: string;
    Kind: TEdLabelKind;
    Align: TAlignment;
    Highlight: boolean;
  end;

  TObjBox = record
    Prims: integer;
    Box: TRectF;                     // screen bounds; Right < Left when nothing is drawn
  end;

  TFaceRef = record
    Shape: integer;
    Verts: array of TVec3;           // world corners, for picking and snapping
    N: TVec3;
  end;

  { TDocScene }

  TDocScene = class(TPrimSource)
  private
    FPrims: array of TPrim;
    FFaces: array of TFaceRef;       // per prim (model faces only)
    FCount: integer;
    FOrder: array of integer;
    FCx, FCy, FFocal, FDist: single;
    FCosY, FSinY, FCosP, FSinP: single;
    FLight: TVec3;
    FPart: integer;
    FKind: byte;
    FMinY: single;
    function NewPrim(ALayer: byte; ADepth: single): PPrim;
    procedure AddSeg(P: PPrim; const A, B: TPointF);
    procedure FinishPrim(P: PPrim);
    procedure AddShape(Doc: TSketchDoc; Index: integer);
    procedure AddGrid;
    procedure AddAnnot(Doc: TSketchDoc; Index: integer);
    procedure AddLabel(X, Y: single; const AText: string; AKind: TEdLabelKind; AAlign: TAlignment;
      AHighlight: boolean);
    procedure AddLayerStrokes(Doc: TSketchDoc; L: integer);
    procedure AddGuides(Doc: TSketchDoc);
    procedure Sort;
    procedure Stats(Doc: TSketchDoc);
  public
    // view
    Yaw, Pitch, Dist: single;
    Target: TVec3;
    // what to show
    Wire, ShowGrid, ShowModel, ShowAnnots, ShowSketch, ShowGuides: boolean;
    SelShape, SelAnnot: integer;
    // results
    Labels: array of TEdLabel;
    LabelCount: integer;
    ShapeBoxes, AnnotBoxes: array of TObjBox;
    AnnotHandles: array of TPointF;  // where an annotation is grabbed
    ModelFaces: integer;
    constructor Create;
    procedure Build(Doc: TSketchDoc; W, H: integer);
    function PrimCount: integer; override;
    function PrimAt(Index: integer): PPrim; override;
    function ToView(const P: TVec3): TVec3;
    function FromView(const V: TVec3): TVec3;
    function Project(const P: TVec3): TPointF;
    function PickShape(X, Y: single): integer;
    function PickPoint(X, Y: single; out Hit: TVec3; out ShapeIdx: integer): boolean;
    // world vector for a screen drag of (DX, DY) pixels at the depth of point P
    function ScreenDeltaToWorld(const P: TVec3; DX, DY: single): TVec3;
    procedure ViewBasis(out Right, Up, Forw: TVec3);
    procedure FrameShapes(Doc: TSketchDoc; OnlyShape: integer = -1);
  end;

// geometry helpers shared with the editor
function VAdd(const A, B: TVec3): TVec3; inline;
function VSub(const A, B: TVec3): TVec3; inline;
function VMul(const A: TVec3; S: single): TVec3; inline;
function VDot(const A, B: TVec3): single; inline;
function VCross(const A, B: TVec3): TVec3; inline;
function VLen(const A: TVec3): single; inline;
function VNorm(const A: TVec3): TVec3;
function RotateEuler(const V, RotDeg: TVec3): TVec3;
function ShapeToWorld(S: TShape; const L: TVec3): TVec3;
procedure ShapeRings(S: TShape; out Bottom, Top: TVec3Array; out Soft: TBoolArray);

implementation

var
  Graphite, GraphiteSoft, SelInk, DimInk, GridInk: TBGRAPixel;

function VAdd(const A, B: TVec3): TVec3;
begin
  Result := V3(A.X + B.X, A.Y + B.Y, A.Z + B.Z);
end;

function VSub(const A, B: TVec3): TVec3;
begin
  Result := V3(A.X - B.X, A.Y - B.Y, A.Z - B.Z);
end;

function VMul(const A: TVec3; S: single): TVec3;
begin
  Result := V3(A.X * S, A.Y * S, A.Z * S);
end;

function VDot(const A, B: TVec3): single;
begin
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

function VCross(const A, B: TVec3): TVec3;
begin
  Result := V3(A.Y * B.Z - A.Z * B.Y, A.Z * B.X - A.X * B.Z, A.X * B.Y - A.Y * B.X);
end;

function VLen(const A: TVec3): single;
begin
  Result := Sqrt(VDot(A, A));
end;

function VNorm(const A: TVec3): TVec3;
var
  L: single;
begin
  L := VLen(A);
  if L < 1e-9 then Exit(V3(0, 0, 0));
  Result := VMul(A, 1 / L);
end;

// rotate about X, then Y, then Z (degrees)
function RotateEuler(const V, RotDeg: TVec3): TVec3;
var
  c, s, y, z, x: single;
begin
  Result := V;
  if RotDeg.X <> 0 then
  begin
    c := Cos(DegToRad(RotDeg.X));
    s := Sin(DegToRad(RotDeg.X));
    y := Result.Y * c - Result.Z * s;
    z := Result.Y * s + Result.Z * c;
    Result.Y := y;
    Result.Z := z;
  end;
  if RotDeg.Y <> 0 then
  begin
    c := Cos(DegToRad(RotDeg.Y));
    s := Sin(DegToRad(RotDeg.Y));
    x := Result.X * c + Result.Z * s;
    z := -Result.X * s + Result.Z * c;
    Result.X := x;
    Result.Z := z;
  end;
  if RotDeg.Z <> 0 then
  begin
    c := Cos(DegToRad(RotDeg.Z));
    s := Sin(DegToRad(RotDeg.Z));
    x := Result.X * c - Result.Y * s;
    y := Result.X * s + Result.Y * c;
    Result.X := x;
    Result.Y := y;
  end;
end;

function ShapeToWorld(S: TShape; const L: TVec3): TVec3;
begin
  Result := VAdd(S.Pos, RotateEuler(V3(L.X * S.Scale.X, L.Y * S.Scale.Y, L.Z * S.Scale.Z), S.Rot));
end;

// Outline of a shape at its bottom (y = -h/2) and top (y = +h/2), local coordinates.
// Soft[i]: the side edge through point i is smooth (drawn only on the silhouette).
procedure ShapeRings(S: TShape; out Bottom, Top: TVec3Array; out Soft: TBoolArray);
var
  n, i, c, k, Seg: integer;
  H, R, A, CX, CZ, W, D, Ch: single;
  Pts: array of TPointF;

  procedure ChamferRect(AW, AD, AC, Shift: single; Y: single; var Ring: TVec3Array);
  var
    C2: single;
  begin
    C2 := Min(AC, Min(AW, AD) * 0.45);
    SetLength(Ring, 8);
    Ring[0] := V3(-AW / 2 + C2, Y, -AD / 2 + Shift);
    Ring[1] := V3(AW / 2 - C2, Y, -AD / 2 + Shift);
    Ring[2] := V3(AW / 2, Y, -AD / 2 + C2 + Shift);
    Ring[3] := V3(AW / 2, Y, AD / 2 - C2 + Shift);
    Ring[4] := V3(AW / 2 - C2, Y, AD / 2 + Shift);
    Ring[5] := V3(-AW / 2 + C2, Y, AD / 2 + Shift);
    Ring[6] := V3(-AW / 2, Y, AD / 2 - C2 + Shift);
    Ring[7] := V3(-AW / 2, Y, -AD / 2 + C2 + Shift);
  end;

begin
  case S.Kind of
    skBox:
      begin
        H := S.Size.Y / 2;
        W := S.Size.X;
        D := S.Size.Z;
        R := EnsureRange(S.Radius, 0, Min(W, D) * 0.5 - 0.001);
        if R <= 0.001 then
        begin
          SetLength(Pts, 4);
          Pts[0] := PointF(-W / 2, -D / 2);
          Pts[1] := PointF(W / 2, -D / 2);
          Pts[2] := PointF(W / 2, D / 2);
          Pts[3] := PointF(-W / 2, D / 2);
        end
        else
        begin
          Seg := 5;
          SetLength(Pts, 4 * (Seg + 1));
          k := 0;
          for c := 0 to 3 do
          begin
            case c of
              0: begin CX := W / 2 - R; CZ := -D / 2 + R; end;
              1: begin CX := W / 2 - R; CZ := D / 2 - R; end;
              2: begin CX := -W / 2 + R; CZ := D / 2 - R; end;
            else
              begin CX := -W / 2 + R; CZ := -D / 2 + R; end;
            end;
            for i := 0 to Seg do
            begin
              A := c * 0.5 * Pi - 0.5 * Pi + 0.5 * Pi * i / Seg;
              Pts[k] := PointF(CX + R * Cos(A), CZ + R * Sin(A));
              Inc(k);
            end;
          end;
        end;
        n := Length(Pts);
        SetLength(Bottom, n);
        SetLength(Top, n);
        SetLength(Soft, n);
        for i := 0 to n - 1 do
        begin
          Bottom[i] := V3(Pts[i].X, -H, Pts[i].Y);
          Top[i] := V3(Pts[i].X, H, Pts[i].Y);
          // rounded: the arcs meet the flat sides tangentially, so no edge is sharp
          Soft[i] := R > 0.001;
        end;
      end;
    skCylinder:
      begin
        n := Max(3, S.Segments);
        H := S.Height / 2;
        SetLength(Bottom, n);
        SetLength(Top, n);
        SetLength(Soft, n);
        for i := 0 to n - 1 do
        begin
          A := 2 * Pi * i / n;
          Bottom[i] := V3(S.RBottom * Cos(A), -H, -S.RBottom * Sin(A));
          Top[i] := V3(S.RTop * Cos(A), H, -S.RTop * Sin(A));
          Soft[i] := True;
        end;
      end;
  else
    begin
      H := S.Height / 2;
      Ch := Max(0, S.Chamfer);
      ChamferRect(S.BW, S.BD, Ch, 0, -H, Bottom);
      ChamferRect(S.TW, S.TD, Ch * Min(S.TW / Max(0.01, S.BW), S.TD / Max(0.01, S.BD)), S.TopShift, H, Top);
      SetLength(Soft, 8);
      for i := 0 to 7 do Soft[i] := False;
    end;
  end;
end;

function Clamp01(V: single): single; inline;
begin
  if V < 0 then Result := 0 else if V > 1 then Result := 1 else Result := V;
end;

function HatchFor(I: single; Mat: TMaterial): integer;
begin
  case Mat of
    mtRubber:
      if I > 0.5 then Result := TexMid
      else if I > 0.05 then Result := TexDark
      else Result := TexRubber;
    mtLeather:
      if I > 0.35 then Result := TexLeather
      else if I > -0.25 then Result := TexDark
      else Result := TexRubber;
    mtGlass:
      Result := TexGlass;
    mtKnurl:
      if I > 0.45 then Result := TexPaper
      else if I > 0.05 then Result := TexLight
      else if I > -0.3 then Result := TexMid
      else Result := TexDark;
  else
    if I > 0.55 then Result := TexPaper
    else if I > 0.25 then Result := TexLight
    else if I > -0.1 then Result := TexMid
    else Result := TexDark;
  end;
end;

{ TDocScene }

constructor TDocScene.Create;
begin
  Yaw := -0.62;
  Pitch := 0.42;
  Dist := 50;
  ShowGrid := True;
  ShowModel := True;
  ShowAnnots := True;
  ShowSketch := True;
  SelShape := -1;
  SelAnnot := -1;
end;

function TDocScene.PrimCount: integer;
begin
  Result := FCount;
end;

function TDocScene.PrimAt(Index: integer): PPrim;
begin
  Result := @FPrims[FOrder[Index]];
end;

function TDocScene.NewPrim(ALayer: byte; ADepth: single): PPrim;
begin
  if FCount >= Length(FPrims) then
  begin
    SetLength(FPrims, Max(512, Length(FPrims) * 2));
    SetLength(FFaces, Length(FPrims));
  end;
  Result := @FPrims[FCount];
  FFaces[FCount].Shape := -1;
  Inc(FCount);
  Result^.Layer := ALayer;
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
  Result^.Reveal := 1;
  Result^.Part := FPart;
  Result^.Kind := FKind;
  if Length(Result^.Pts) <> 0 then SetLength(Result^.Pts, 0);
end;

procedure TDocScene.AddSeg(P: PPrim; const A, B: TPointF);
begin
  if P^.NSeg + 2 > Length(P^.Segs) then SetLength(P^.Segs, Max(16, Length(P^.Segs) * 2));
  P^.Segs[P^.NSeg] := A;
  P^.Segs[P^.NSeg + 1] := B;
  Inc(P^.NSeg, 2);
end;

procedure TDocScene.FinishPrim(P: PPrim);
var
  i: integer;
  Y0, Y1, Pad: single;
begin
  Y0 := 1e9;
  Y1 := -1e9;
  for i := 0 to High(P^.Pts) do
  begin
    Y0 := Min(Y0, P^.Pts[i].Y);
    Y1 := Max(Y1, P^.Pts[i].Y);
  end;
  for i := 0 to P^.NSeg - 1 do
  begin
    Y0 := Min(Y0, P^.Segs[i].Y);
    Y1 := Max(Y1, P^.Segs[i].Y);
  end;
  Pad := Max(P^.EdgeW, P^.SegW) + 4;
  P^.Y0 := Y0 - Pad;
  P^.Y1 := Y1 + Pad;
end;

procedure TDocScene.AddLabel(X, Y: single; const AText: string; AKind: TEdLabelKind; AAlign: TAlignment;
  AHighlight: boolean);
begin
  if LabelCount >= Length(Labels) then SetLength(Labels, Max(32, 2 * Length(Labels)));
  Labels[LabelCount].X := X;
  Labels[LabelCount].Y := Y;
  Labels[LabelCount].Text := AText;
  Labels[LabelCount].Kind := AKind;
  Labels[LabelCount].Align := AAlign;
  Labels[LabelCount].Highlight := AHighlight;
  Inc(LabelCount);
end;

{ ------------------------------------------------------------ projection }

function TDocScene.ToView(const P: TVec3): TVec3;
var
  Q: TVec3;
  X, Z: single;
begin
  Q := VSub(P, Target);
  X := Q.X * FCosY + Q.Z * FSinY;
  Z := -Q.X * FSinY + Q.Z * FCosY;
  Result.X := X;
  Result.Y := Q.Y * FCosP - Z * FSinP;
  Result.Z := Q.Y * FSinP + Z * FCosP;
end;

function TDocScene.FromView(const V: TVec3): TVec3;
var
  Y, Z, X: single;
begin
  Y := V.Y * FCosP + V.Z * FSinP;
  Z := -V.Y * FSinP + V.Z * FCosP;
  X := V.X * FCosY - Z * FSinY;
  Z := V.X * FSinY + Z * FCosY;
  Result := VAdd(V3(X, Y, Z), Target);
end;

function TDocScene.Project(const P: TVec3): TPointF;
var
  V: TVec3;
  D: single;
begin
  V := ToView(P);
  D := Max(0.5, FDist - V.Z);
  Result.X := FCx + FFocal * V.X / D;
  Result.Y := FCy - FFocal * V.Y / D;
end;

procedure TDocScene.ViewBasis(out Right, Up, Forw: TVec3);
var
  O: TVec3;
begin
  O := FromView(V3(0, 0, 0));
  Right := VSub(FromView(V3(1, 0, 0)), O);
  Up := VSub(FromView(V3(0, 1, 0)), O);
  Forw := VSub(FromView(V3(0, 0, -1)), O);
end;

function TDocScene.ScreenDeltaToWorld(const P: TVec3; DX, DY: single): TVec3;
var
  R, U, F: TVec3;
  D: single;
begin
  ViewBasis(R, U, F);
  D := Max(0.5, FDist - ToView(P).Z) / FFocal;
  Result := VAdd(VMul(R, DX * D), VMul(U, -DY * D));
end;

{ ------------------------------------------------------------ building }

procedure TDocScene.AddShape(Doc: TSketchDoc; Index: integer);
var
  S: TShape;
  Bm, Tm, BW, TWv: TVec3Array;
  Soft: TBoolArray;
  n, i, j, h, f, Faces: integer;
  NV, Vis: array of boolean;
  Nrm: array of TVec3;
  Ctr, FC, CapN, CapC: TVec3;
  P: PPrim;
  I_: single;
  Edge: TBGRAPixel;
  Tick: integer;

  function FaceNormal(const A, B, C: TVec3; const Mid: TVec3): TVec3;
  begin
    Result := VNorm(VCross(VSub(B, A), VSub(C, A)));
    // convex shapes: the normal points away from the centre
    if VDot(Result, VSub(Mid, Ctr)) < 0 then Result := VMul(Result, -1);
  end;

  function Facing(const NW, PW: TVec3): boolean;
  var
    NV3, PV: TVec3;
  begin
    // view space: the eye sits at (0, 0, FDist)
    NV3 := VSub(ToView(VAdd(PW, NW)), ToView(PW));
    PV := ToView(PW);
    Result := NV3.X * -PV.X + NV3.Y * -PV.Y + NV3.Z * (FDist - PV.Z) > 0;
  end;

  procedure KeepFace(P: PPrim; const V: array of TVec3; const NW: TVec3);
  var
    k: integer;
  begin
    FFaces[FCount - 1].Shape := Index;
    SetLength(FFaces[FCount - 1].Verts, Length(V));
    for k := 0 to High(V) do FFaces[FCount - 1].Verts[k] := V[k];
    FFaces[FCount - 1].N := NW;
  end;

begin
  S := Doc.Shape(Index);
  if not S.Visible then Exit;
  FPart := Index;
  FKind := kModel;
  ShapeRings(S, Bm, Tm, Soft);
  n := Length(Bm);
  SetLength(BW, n);
  SetLength(TWv, n);
  Ctr := S.Pos;
  for i := 0 to n - 1 do
  begin
    BW[i] := ShapeToWorld(S, Bm[i]);
    TWv[i] := ShapeToWorld(S, Tm[i]);
    FMinY := Min(FMinY, Min(BW[i].Y, TWv[i].Y));
  end;
  SetLength(Vis, n);
  SetLength(Nrm, n);
  for i := 0 to n - 1 do
  begin
    j := (i + 1) mod n;
    FC := VMul(VAdd(VAdd(BW[i], BW[j]), VAdd(TWv[i], TWv[j])), 0.25);
    if VLen(VSub(BW[j], BW[i])) > 1e-5 then
      Nrm[i] := FaceNormal(BW[i], BW[j], TWv[i], FC)
    else
      Nrm[i] := FaceNormal(TWv[i], TWv[j], BW[i], FC);
    Vis[i] := Facing(Nrm[i], FC);
  end;
  if Index = SelShape then Edge := SelInk else Edge := Graphite;
  Tick := 0;
  if S.Ticks > 0 then Tick := Max(1, n div S.Ticks);
  Faces := 0;
  // sides
  for i := 0 to n - 1 do
  begin
    if not Vis[i] and not Wire then Continue;
    j := (i + 1) mod n;
    h := (i + n - 1) mod n;
    FC := VMul(VAdd(VAdd(BW[i], BW[j]), VAdd(TWv[i], TWv[j])), 0.25);
    P := NewPrim(1, FDist - ToView(FC).Z - S.DepthBias);
    KeepFace(P, [BW[i], BW[j], TWv[j], TWv[i]], Nrm[i]);
    SetLength(P^.Pts, 4);
    P^.Pts[0] := Project(BW[i]);
    P^.Pts[1] := Project(BW[j]);
    P^.Pts[2] := Project(TWv[j]);
    P^.Pts[3] := Project(TWv[i]);
    P^.Edge := emMask;
    P^.EdgeMask := 1 or 4;                                       // rims
    if not Soft[i] or not Vis[h] then P^.EdgeMask := P^.EdgeMask or 8;
    if not Soft[j] or not Vis[j] then P^.EdgeMask := P^.EdgeMask or 2;
    P^.EdgeC := Edge;
    P^.Sketchy := not Soft[i];
    if Wire then
    begin
      P^.EdgeMask := 15;
      if not Vis[i] then P^.EdgeC := BGRA(60, 70, 100, 60);
      P^.EdgeW := 0.9;
    end
    else
    begin
      I_ := VDot(VSub(ToView(VAdd(FC, Nrm[i])), ToView(FC)), FLight);
      P^.Tex := HatchFor(I_, S.Mat);
      if (S.Mat = mtTeeth) and Odd(i) then P^.Tex := Min(TexDark, P^.Tex + 2);
    end;
    if S.Ribbed then
    begin
      AddSeg(P, P^.Pts[0], P^.Pts[3]);
      P^.SegC := BGRA(30, 30, 38, 160);
      P^.SegW := 0.9;
    end;
    if (Tick > 0) and (i mod Tick = 0) then
      AddSeg(P, P^.Pts[3], PointF(P^.Pts[3].X + (P^.Pts[0].X - P^.Pts[3].X) * 0.45,
        P^.Pts[3].Y + (P^.Pts[0].Y - P^.Pts[3].Y) * 0.45));
    FinishPrim(P);
    Inc(Faces);
  end;
  // caps: their outline is drawn where the side next to it is turned away
  for f := 0 to 1 do
  begin
    CapC := V3(0, 0, 0);
    for i := 0 to n - 1 do
      if f = 0 then CapC := VAdd(CapC, TWv[i]) else CapC := VAdd(CapC, BW[i]);
    CapC := VMul(CapC, 1 / n);
    if f = 0 then CapN := FaceNormal(TWv[0], TWv[1], TWv[2], CapC)
    else CapN := FaceNormal(BW[0], BW[1], BW[2], CapC);
    if VLen(CapN) < 0.5 then
      if f = 0 then CapN := VNorm(VSub(CapC, Ctr)) else CapN := VNorm(VSub(CapC, Ctr));
    if not Facing(CapN, CapC) and not Wire then Continue;
    if f = 0 then
    begin
      // degenerate top (cone to a point): nothing to draw
      if VLen(VSub(TWv[0], TWv[n div 2])) < 1e-4 then Continue;
    end
    else if VLen(VSub(BW[0], BW[n div 2])) < 1e-4 then Continue;
    P := NewPrim(1, FDist - ToView(CapC).Z - S.DepthBias - 0.01);
    SetLength(P^.Pts, n);
    for i := 0 to n - 1 do
      if f = 0 then P^.Pts[i] := Project(TWv[i]) else P^.Pts[i] := Project(BW[i]);
    if f = 0 then KeepFace(P, TWv, CapN) else KeepFace(P, BW, CapN);
    // the rim is outlined where the side next to it is turned away (the sides draw the rest)
    P^.SegC := Edge;
    P^.SegW := 1.25;
    P^.Sketchy := S.Kind <> skCylinder;
    for i := 0 to n - 1 do
      if not Vis[i] then AddSeg(P, P^.Pts[i], P^.Pts[(i + 1) mod n]);
    if Wire then
    begin
      P^.Edge := emAll;
      P^.EdgeW := 0.9;
    end
    else
      P^.Tex := HatchFor(VDot(VSub(ToView(VAdd(CapC, CapN)), ToView(CapC)), FLight), S.Mat);
    if (S.Kind = skCylinder) and S.Ribbed and (S.Mat = mtTeeth) and (f = 0) then
      // knurled crown on a dial top
      for i := 0 to n - 1 do
        if not Odd(i) then
          AddSeg(P, Project(ShapeToWorld(S, VMul(V3(Tm[i].X, 0, Tm[i].Z), 0.84) )),
            Project(ShapeToWorld(S, V3(Tm[i].X * 0.98, Tm[i].Y, Tm[i].Z * 0.98))));
    FinishPrim(P);
    Inc(Faces);
  end;
  Inc(ModelFaces, Faces);
end;

procedure TDocScene.AddGrid;
var
  i: integer;
  X, Z, A, G: single;
  P: PPrim;
  C: TBGRAPixel;
begin
  FPart := -1;
  FKind := kGrid;
  G := FMinY;
  for i := -12 to 12 do
  begin
    X := i * 2;
    A := 1 - Abs(i) / 13;
    C := GridInk;
    C.alpha := Round(C.alpha * A * A);
    P := NewPrim(0, 1e9);
    P^.SegC := C;
    P^.SegW := 0.7;
    AddSeg(P, Project(V3(X + Target.X, G, -24 + Target.Z)), Project(V3(X + Target.X, G, 0 + Target.Z)));
    AddSeg(P, Project(V3(X + Target.X, G, 0 + Target.Z)), Project(V3(X + Target.X, G, 24 + Target.Z)));
    FinishPrim(P);
    Z := i * 2;
    P := NewPrim(0, 1e9);
    P^.SegC := C;
    P^.SegW := 0.7;
    AddSeg(P, Project(V3(-24 + Target.X, G, Z + Target.Z)), Project(V3(0 + Target.X, G, Z + Target.Z)));
    AddSeg(P, Project(V3(0 + Target.X, G, Z + Target.Z)), Project(V3(24 + Target.X, G, Z + Target.Z)));
    FinishPrim(P);
  end;
end;

procedure TDocScene.AddAnnot(Doc: TSketchDoc; Index: integer);
var
  An: TAnnot;
  P: PPrim;
  A0, A1, B0, B1, D, M, N, S, L, E: TPointF;
  Len: single;
  T: string;
  Sel: boolean;
  Ink: TBGRAPixel;

  procedure Arrow(const Tip, Dir: TPointF);
  var
    Q: PPrim;
  begin
    Q := NewPrim(2, -Index);
    SetLength(Q^.Pts, 3);
    Q^.Pts[0] := Tip;
    Q^.Pts[1] := Tip + Dir * 9 + PointF(-Dir.Y, Dir.X) * 2.6;
    Q^.Pts[2] := Tip + Dir * 9 - PointF(-Dir.Y, Dir.X) * 2.6;
    Q^.Tex := TexSolid;
    Q^.Solid := Ink;
    FinishPrim(Q);
  end;

  procedure Dot(const C: TPointF);
  var
    Q: PPrim;
    k: integer;
  begin
    Q := NewPrim(2, -Index);
    SetLength(Q^.Pts, 8);
    for k := 0 to 7 do Q^.Pts[k] := C + PointF(2.6 * Cos(k * Pi / 4), 2.6 * Sin(k * Pi / 4));
    Q^.Tex := TexSolid;
    Q^.Solid := Ink;
    FinishPrim(Q);
  end;

begin
  An := Doc.Annot(Index);
  if not An.Visible then Exit;
  FPart := Index;
  FKind := kAnnot;
  Sel := Index = SelAnnot;
  if Sel then Ink := SelInk else Ink := DimInk;
  case An.Kind of
    akDimension:
      begin
        A0 := Project(VAdd(An.A, VMul(An.Offset, 0.15)));
        A1 := Project(VAdd(An.A, VMul(An.Offset, 1.12)));
        B0 := Project(VAdd(An.B, VMul(An.Offset, 0.15)));
        B1 := Project(VAdd(An.B, VMul(An.Offset, 1.12)));
        P := NewPrim(2, -Index);
        P^.SegC := Ink;
        P^.SegW := 0.85;
        AddSeg(P, A0, A1);
        AddSeg(P, B0, B1);
        A1 := Project(VAdd(An.A, An.Offset));
        B1 := Project(VAdd(An.B, An.Offset));
        AddSeg(P, A1, B1);
        FinishPrim(P);
        D := B1 - A1;
        Len := Sqrt(D.X * D.X + D.Y * D.Y);
        M := (A1 + B1) * 0.5;
        if Len > 24 then
        begin
          D := D * (1 / Len);
          Arrow(A1, D);
          Arrow(B1, D * -1);
          N := PointF(-D.Y, D.X);
          if N.Y > 0 then N := N * -1;
          M := M + N * 13;
        end;
        T := An.Text;
        if T = '' then T := FormatFloat('0.#', VLen(VSub(An.B, An.A)) * 10);
        AddLabel(M.X, M.Y, T, elDim, taCenter, Sel);
        AnnotHandles[Index] := M;
      end;
    akLabel:
      begin
        S := Project(An.A);
        Dot(S);
        AddLabel(S.X + 7, S.Y, An.Text, elLabel, taLeftJustify, Sel);
        AnnotHandles[Index] := S;
      end;
    akCallout:
      begin
        S := Project(An.A);
        L := S + PointF(An.DX, An.DY);
        if An.DX >= 0 then E := L + PointF(16, 0) else E := L - PointF(16, 0);
        P := NewPrim(2, -Index);
        P^.SegC := Ink;
        P^.SegW := 0.8;
        AddSeg(P, S, L);
        AddSeg(P, L, E);
        FinishPrim(P);
        Dot(S);
        if An.Text <> '' then T := Format('%d  %s', [An.Number, An.Text]) else T := IntToStr(An.Number);
        if An.DX >= 0 then
          AddLabel(E.X + 3, E.Y, T, elCallout, taLeftJustify, Sel)
        else
          AddLabel(E.X - 3, E.Y, T, elCallout, taRightJustify, Sel);
        AnnotHandles[Index] := E;
      end;
  end;
end;

procedure TDocScene.AddLayerStrokes(Doc: TSketchDoc; L: integer);
var
  Ly: TSketchLayer;
  St: TStroke;
  P: PPrim;
  i, k: integer;
begin
  Ly := Doc.Layer(L);
  if not Ly.Visible then Exit;
  FKind := kSketch;
  for i := 0 to Ly.StrokeCount - 1 do
  begin
    St := Ly.Stroke(i);
    if Length(St.Pts) < 2 then Continue;
    FPart := i;
    P := NewPrim(Min(249, 3 + L), -i);
    P^.SegW := St.Width;
    P^.SegC := BGRA(28, 28, 36, Round(255 * Clamp01(St.Ink)));
    P^.Sketchy := St.Sketchy;
    if St.Kind = stHatch then
    begin
      k := 0;
      while k + 1 <= High(St.Pts) do
      begin
        AddSeg(P, St.Pts[k], St.Pts[k + 1]);
        Inc(k, 2);
      end;
    end
    else
      for k := 0 to High(St.Pts) - 1 do AddSeg(P, St.Pts[k], St.Pts[k + 1]);
    FinishPrim(P);
  end;
end;

// Two-point perspective: horizon through both vanishing points and a fan of rays from each.
procedure TDocScene.AddGuides(Doc: TSketchDoc);
var
  P: PPrim;
  k, v: integer;
  O, D: TPointF;
  A, Base: single;
begin
  FPart := -1;
  FKind := kGuide;
  P := NewPrim(250, 0);
  P^.SegC := BGRA(60, 110, 200, 90);
  P^.SegW := 0.8;
  D := Doc.VP2 - Doc.VP1;
  A := Sqrt(D.X * D.X + D.Y * D.Y);
  if A > 1 then
  begin
    D := D * (1 / A);
    AddSeg(P, Doc.VP1 - D * 4000, Doc.VP2 + D * 4000);
  end;
  for v := 0 to 1 do
  begin
    if v = 0 then O := Doc.VP1 else O := Doc.VP2;
    if v = 0 then Base := 0 else Base := Pi;
    for k := -8 to 8 do
    begin
      A := Base + k * 0.07;
      AddSeg(P, O, O + PointF(Cos(A), Sin(A)) * 3000);
    end;
  end;
  FinishPrim(P);
end;

procedure TDocScene.Sort;

  function Less(A, B: integer): boolean; inline;
  begin
    if FPrims[A].Layer <> FPrims[B].Layer then
      Result := FPrims[A].Layer < FPrims[B].Layer
    else if FPrims[A].Depth <> FPrims[B].Depth then
      Result := FPrims[A].Depth > FPrims[B].Depth
    else
      Result := A < B;               // stable: keeps the building order
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

procedure TDocScene.Stats(Doc: TSketchDoc);

  procedure Grow(var B: TObjBox; const P: TPrim);
  var
    k: integer;

    procedure Pt(const Q: TPointF);
    begin
      B.Box.Left := Min(B.Box.Left, Q.X);
      B.Box.Top := Min(B.Box.Top, Q.Y);
      B.Box.Right := Max(B.Box.Right, Q.X);
      B.Box.Bottom := Max(B.Box.Bottom, Q.Y);
    end;

  begin
    Inc(B.Prims);
    for k := 0 to High(P.Pts) do Pt(P.Pts[k]);
    for k := 0 to P.NSeg - 1 do Pt(P.Segs[k]);
  end;

var
  i: integer;
begin
  for i := 0 to High(ShapeBoxes) do
  begin
    ShapeBoxes[i].Prims := 0;
    ShapeBoxes[i].Box := RectF(1e9, 1e9, -1e9, -1e9);
  end;
  for i := 0 to High(AnnotBoxes) do
  begin
    AnnotBoxes[i].Prims := 0;
    AnnotBoxes[i].Box := RectF(1e9, 1e9, -1e9, -1e9);
  end;
  for i := 0 to FCount - 1 do
    if FPrims[i].Part >= 0 then
      case FPrims[i].Kind of
        kModel: if FPrims[i].Part <= High(ShapeBoxes) then Grow(ShapeBoxes[FPrims[i].Part], FPrims[i]);
        kAnnot: if FPrims[i].Part <= High(AnnotBoxes) then Grow(AnnotBoxes[FPrims[i].Part], FPrims[i]);
      end;
end;

procedure TDocScene.Build(Doc: TSketchDoc; W, H: integer);
var
  i: integer;
begin
  FCount := 0;
  LabelCount := 0;
  ModelFaces := 0;
  FCx := W * 0.5;
  FCy := H * 0.5;
  FFocal := Min(W, H * 1.35) * 1.55;
  FDist := Dist;
  FCosY := Cos(Yaw);
  FSinY := Sin(Yaw);
  FCosP := Cos(Pitch);
  FSinP := Sin(Pitch);
  FLight := VNorm(V3(-0.5, 0.72, 0.48));
  FMinY := 1e9;
  SetLength(ShapeBoxes, Doc.ShapeCount);
  SetLength(AnnotBoxes, Doc.AnnotCount);
  SetLength(AnnotHandles, Doc.AnnotCount);
  if ShowModel then
    for i := 0 to Doc.ShapeCount - 1 do AddShape(Doc, i);
  if FMinY > 1e8 then FMinY := 0;
  if ShowGrid then AddGrid;
  if ShowAnnots then
    for i := 0 to Doc.AnnotCount - 1 do AddAnnot(Doc, i);
  if ShowSketch then
    for i := 0 to Doc.LayerCount - 1 do AddLayerStrokes(Doc, i);
  if ShowGuides then AddGuides(Doc);
  Sort;
  Stats(Doc);
end;

{ ------------------------------------------------------------ picking }

function PointInPoly(const Pts: array of TPointF; X, Y: single): boolean;
var
  i, j: integer;
begin
  Result := False;
  j := High(Pts);
  for i := 0 to High(Pts) do
  begin
    if ((Pts[i].Y > Y) <> (Pts[j].Y > Y)) and
      (X < (Pts[j].X - Pts[i].X) * (Y - Pts[i].Y) / (Pts[j].Y - Pts[i].Y) + Pts[i].X) then
      Result := not Result;
    j := i;
  end;
end;

function TDocScene.PickShape(X, Y: single): integer;
var
  i, k: integer;
  P: PPrim;
begin
  // front-most first: the drawing order backwards
  for i := FCount - 1 downto 0 do
  begin
    k := FOrder[i];
    P := @FPrims[k];
    if (P^.Kind = kModel) and (FFaces[k].Shape >= 0) and (Length(P^.Pts) >= 3) and PointInPoly(P^.Pts, X, Y) then
      Exit(FFaces[k].Shape);
  end;
  Result := -1;
end;

function TDocScene.PickPoint(X, Y: single; out Hit: TVec3; out ShapeIdx: integer): boolean;
var
  i, k, v: integer;
  P: PPrim;
  E, Far, Dir: TVec3;
  T, Den, Best, Dd: single;
  S: TPointF;
begin
  Result := False;
  ShapeIdx := -1;
  for i := FCount - 1 downto 0 do
  begin
    k := FOrder[i];
    P := @FPrims[k];
    if (P^.Kind <> kModel) or (FFaces[k].Shape < 0) or (Length(P^.Pts) < 3) or not PointInPoly(P^.Pts, X, Y) then
      Continue;
    // a corner within 10 px wins
    Best := 100;
    for v := 0 to High(FFaces[k].Verts) do
    begin
      S := Project(FFaces[k].Verts[v]);
      Dd := Sqr(S.X - X) + Sqr(S.Y - Y);
      if Dd < Best then
      begin
        Best := Dd;
        Hit := FFaces[k].Verts[v];
        Result := True;
      end;
    end;
    ShapeIdx := FFaces[k].Shape;
    if Result then Exit;
    // otherwise: the view ray through the pixel meets the face plane
    E := FromView(V3(0, 0, FDist));
    Far := FromView(V3((X - FCx) / FFocal * FDist, -(Y - FCy) / FFocal * FDist, 0));
    Dir := VSub(Far, E);
    Den := VDot(Dir, FFaces[k].N);
    if Abs(Den) < 1e-6 then Exit;
    T := VDot(VSub(FFaces[k].Verts[0], E), FFaces[k].N) / Den;
    Hit := VAdd(E, VMul(Dir, T));
    Exit(True);
  end;
end;

procedure TDocScene.FrameShapes(Doc: TSketchDoc; OnlyShape: integer);
var
  i, k: integer;
  Bm, Tm: TVec3Array;
  Soft: TBoolArray;
  Lo, Hi, Q: TVec3;
  Any: boolean;
begin
  Any := False;
  Lo := V3(1e9, 1e9, 1e9);
  Hi := V3(-1e9, -1e9, -1e9);
  for i := 0 to Doc.ShapeCount - 1 do
    if (OnlyShape < 0) or (i = OnlyShape) then
    begin
      ShapeRings(Doc.Shape(i), Bm, Tm, Soft);
      for k := 0 to High(Bm) do
      begin
        Q := ShapeToWorld(Doc.Shape(i), Bm[k]);
        Lo := V3(Min(Lo.X, Q.X), Min(Lo.Y, Q.Y), Min(Lo.Z, Q.Z));
        Hi := V3(Max(Hi.X, Q.X), Max(Hi.Y, Q.Y), Max(Hi.Z, Q.Z));
        Q := ShapeToWorld(Doc.Shape(i), Tm[k]);
        Lo := V3(Min(Lo.X, Q.X), Min(Lo.Y, Q.Y), Min(Lo.Z, Q.Z));
        Hi := V3(Max(Hi.X, Q.X), Max(Hi.Y, Q.Y), Max(Hi.Z, Q.Z));
        Any := True;
      end;
    end;
  if not Any then
  begin
    Target := V3(0, 0, 0);
    Dist := 50;
    Exit;
  end;
  Target := VMul(VAdd(Lo, Hi), 0.5);
  Dist := Max(8, VLen(VSub(Hi, Lo)) * 1.9);
end;

initialization
  Graphite := BGRA(34, 34, 40, 225);
  GraphiteSoft := BGRA(40, 40, 48, 140);
  SelInk := BGRA(30, 90, 210, 235);
  DimInk := BGRA(46, 52, 66, 200);
  GridInk := BGRA(80, 95, 120, 60);
end.
