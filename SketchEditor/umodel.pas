unit UModel;

{ Sketch Editor document: everything that is saved.

  Shapes       3D parts of the model: rounded box, cylinder / cone, loft
               (a chamfered block whose top is smaller than its bottom).
               Each has a name, position, rotation (degrees, applied X then
               Y then Z), scale, material, depth bias and its own sizes.
  Annotations  dimensions, labels and numbered callouts anchored to points
               in model space; they follow the view.
  Sketch       freehand layers drawn on the sheet in screen pixels: pencil
               lines, straight lines, ellipses and hatching.

  Units are centimetres, Y up. Files are JSON (*.sketch.json). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Contnrs, fpjson, jsonparser, BGRABitmapTypes;

type
  TVec3 = record
    X, Y, Z: single;
  end;

  TShapeKind = (skBox, skCylinder, skLoft);
  TMaterial = (mtMetal, mtRubber, mtLeather, mtKnurl, mtTeeth, mtGlass);

const
  ShapeKindNames: array[TShapeKind] of string = ('Box', 'Cylinder', 'Loft');
  MaterialNames: array[TMaterial] of string = ('Metal', 'Rubber', 'Leatherette', 'Knurled', 'Dial teeth', 'Glass');

type

  { TShape }

  TShape = class
  public
    Name: string;
    Kind: TShapeKind;
    Pos, Rot, Scale: TVec3;
    Mat: TMaterial;
    Visible: boolean;
    DepthBias: single;               // painter's order nudge: > 0 draws it later (in front)
    // box: Size, corner radius of the vertical edges
    Size: TVec3;
    Radius: single;
    // cylinder along local Y, centred on Pos
    RBottom, RTop, Height: single;
    Segments: integer;
    Ribbed: boolean;
    Ticks: integer;
    // loft along local Y: bottom W x D, top W x D (shifted along Z), chamfered corners
    BW, BD, TW, TD, TopShift, Chamfer: single;
    constructor Create(AKind: TShapeKind);
    function Clone: TShape;
    procedure ToJSON(O: TJSONObject);
    procedure FromJSON(O: TJSONObject);
  end;

  TAnnotKind = (akDimension, akLabel, akCallout);

const
  AnnotKindNames: array[TAnnotKind] of string = ('Dimension', 'Label', 'Callout');

type

  { TAnnot }

  TAnnot = class
  public
    Kind: TAnnotKind;
    Text: string;                    // dimension: empty = measured length in mm
    A, B, Offset: TVec3;             // dimension A-B moved by Offset; label/callout anchor A
    DX, DY: single;                  // callout: label position relative to the anchor, pixels
    Number: integer;                 // callout tag number
    Visible: boolean;
    constructor Create(AKind: TAnnotKind);
    function Clone: TAnnot;
    function Caption: string;
    procedure ToJSON(O: TJSONObject);
    procedure FromJSON(O: TJSONObject);
  end;

  TStrokeKind = (stLine, stHatch);   // polyline / a set of hatch segments

  { TStroke }

  TStroke = class
  public
    Kind: TStrokeKind;
    Pts: array of TPointF;           // stLine: polyline; stHatch: segment pairs
    Width: single;
    Ink: single;                     // 0..1 darkness
    Sketchy: boolean;                // overshooting doubled pencil line (ruled strokes)
    constructor Create(AKind: TStrokeKind);
    function Clone: TStroke;
    procedure ToJSON(O: TJSONObject);
    procedure FromJSON(O: TJSONObject);
  end;

  { TSketchLayer }

  TSketchLayer = class
  public
    Name: string;
    Visible, Locked: boolean;
    Strokes: TFPObjectList;
    constructor Create(const AName: string);
    destructor Destroy; override;
    function Clone: TSketchLayer;
    function StrokeCount: integer;
    function Stroke(i: integer): TStroke;
  end;

  { TSketchDoc }

  TSketchDoc = class
  public
    Title: string;
    Shapes, Annots, Layers: TFPObjectList;
    ActiveLayer: integer;
    VP1, VP2: TPointF;               // perspective guide vanishing points (sheet pixels)
    // saved view
    ViewYaw, ViewPitch, ViewDist: single;
    ViewTarget: TVec3;
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function ShapeCount: integer;
    function Shape(i: integer): TShape;
    function AnnotCount: integer;
    function Annot(i: integer): TAnnot;
    function LayerCount: integer;
    function Layer(i: integer): TSketchLayer;
    function ToJSONString: string;
    procedure FromJSONString(const S: string);
    procedure SaveToFile(const FileName: string);
    procedure LoadFromFile(const FileName: string);
    procedure LoadCameraPreset;
    function NextCalloutNumber: integer;
    function UniqueName(const Base: string): string;
  end;

function V3(X, Y, Z: single): TVec3; inline;

implementation

function V3(X, Y, Z: single): TVec3;
begin
  Result.X := X;
  Result.Y := Y;
  Result.Z := Z;
end;

function VecJSON(const V: TVec3): TJSONArray;
begin
  Result := TJSONArray.Create([V.X, V.Y, V.Z]);
end;

function JSONVec(O: TJSONObject; const Key: string; const Def: TVec3): TVec3;
var
  A: TJSONArray;
begin
  Result := Def;
  if (O.Find(Key) = nil) or not (O.Find(Key) is TJSONArray) then Exit;
  A := TJSONArray(O.Find(Key));
  if A.Count >= 3 then Result := V3(A.Floats[0], A.Floats[1], A.Floats[2]);
end;

{ TShape }

constructor TShape.Create(AKind: TShapeKind);
begin
  Kind := AKind;
  Name := ShapeKindNames[AKind];
  Scale := V3(1, 1, 1);
  Visible := True;
  Size := V3(4, 2, 3);
  Radius := 0;
  RBottom := 1.5;
  RTop := 1.5;
  Height := 2;
  Segments := 40;
  BW := 4;
  BD := 3;
  TW := 2.6;
  TD := 1.8;
  Chamfer := 0.3;
end;

function TShape.Clone: TShape;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    ToJSON(O);
    Result := TShape.Create(Kind);
    Result.FromJSON(O);
  finally
    O.Free;
  end;
end;

procedure TShape.ToJSON(O: TJSONObject);
begin
  O.Add('name', Name);
  O.Add('kind', ShapeKindNames[Kind]);
  O.Add('pos', VecJSON(Pos));
  O.Add('rot', VecJSON(Rot));
  O.Add('scale', VecJSON(Scale));
  O.Add('material', MaterialNames[Mat]);
  O.Add('visible', Visible);
  O.Add('depthBias', DepthBias);
  case Kind of
    skBox:
      begin
        O.Add('size', VecJSON(Size));
        O.Add('radius', Radius);
      end;
    skCylinder:
      begin
        O.Add('rBottom', RBottom);
        O.Add('rTop', RTop);
        O.Add('height', Height);
        O.Add('segments', Segments);
        O.Add('ribbed', Ribbed);
        O.Add('ticks', Ticks);
      end;
    skLoft:
      begin
        O.Add('height', Height);
        O.Add('bottom', TJSONArray.Create([BW, BD]));
        O.Add('top', TJSONArray.Create([TW, TD]));
        O.Add('topShift', TopShift);
        O.Add('chamfer', Chamfer);
      end;
  end;
end;

procedure TShape.FromJSON(O: TJSONObject);
var
  K: TShapeKind;
  M: TMaterial;
  A: TJSONArray;
begin
  for K := Low(TShapeKind) to High(TShapeKind) do
    if SameText(O.Get('kind', ''), ShapeKindNames[K]) then Kind := K;
  Name := O.Get('name', ShapeKindNames[Kind]);
  Pos := JSONVec(O, 'pos', V3(0, 0, 0));
  Rot := JSONVec(O, 'rot', V3(0, 0, 0));
  Scale := JSONVec(O, 'scale', V3(1, 1, 1));
  for M := Low(TMaterial) to High(TMaterial) do
    if SameText(O.Get('material', ''), MaterialNames[M]) then Mat := M;
  Visible := O.Get('visible', True);
  DepthBias := O.Get('depthBias', 0.0);
  Size := JSONVec(O, 'size', Size);
  Radius := O.Get('radius', Radius);
  RBottom := O.Get('rBottom', RBottom);
  RTop := O.Get('rTop', RTop);
  Height := O.Get('height', Height);
  Segments := O.Get('segments', Segments);
  Ribbed := O.Get('ribbed', Ribbed);
  Ticks := O.Get('ticks', Ticks);
  if O.Find('bottom') is TJSONArray then
  begin
    A := TJSONArray(O.Find('bottom'));
    BW := A.Floats[0];
    BD := A.Floats[1];
  end;
  if O.Find('top') is TJSONArray then
  begin
    A := TJSONArray(O.Find('top'));
    TW := A.Floats[0];
    TD := A.Floats[1];
  end;
  TopShift := O.Get('topShift', TopShift);
  Chamfer := O.Get('chamfer', Chamfer);
end;

{ TAnnot }

constructor TAnnot.Create(AKind: TAnnotKind);
begin
  Kind := AKind;
  Visible := True;
  DX := 60;
  DY := -40;
  if AKind = akLabel then Text := 'Label';
end;

function TAnnot.Clone: TAnnot;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    ToJSON(O);
    Result := TAnnot.Create(Kind);
    Result.FromJSON(O);
  finally
    O.Free;
  end;
end;

function TAnnot.Caption: string;
begin
  case Kind of
    akDimension: if Text <> '' then Result := 'Dimension ' + Text else Result := 'Dimension (measured)';
    akLabel: Result := 'Label "' + Text + '"';
  else
    Result := Format('Callout %d %s', [Number, Text]);
  end;
end;

procedure TAnnot.ToJSON(O: TJSONObject);
begin
  O.Add('kind', AnnotKindNames[Kind]);
  O.Add('text', Text);
  O.Add('a', VecJSON(A));
  O.Add('b', VecJSON(B));
  O.Add('offset', VecJSON(Offset));
  O.Add('dx', DX);
  O.Add('dy', DY);
  O.Add('number', Number);
  O.Add('visible', Visible);
end;

procedure TAnnot.FromJSON(O: TJSONObject);
var
  K: TAnnotKind;
begin
  for K := Low(TAnnotKind) to High(TAnnotKind) do
    if SameText(O.Get('kind', ''), AnnotKindNames[K]) then Kind := K;
  Text := O.Get('text', '');
  A := JSONVec(O, 'a', V3(0, 0, 0));
  B := JSONVec(O, 'b', V3(0, 0, 0));
  Offset := JSONVec(O, 'offset', V3(0, 0, 0));
  DX := O.Get('dx', 60.0);
  DY := O.Get('dy', -40.0);
  Number := O.Get('number', 0);
  Visible := O.Get('visible', True);
end;

{ TStroke }

constructor TStroke.Create(AKind: TStrokeKind);
begin
  Kind := AKind;
  Width := 1.3;
  Ink := 0.85;
end;

function TStroke.Clone: TStroke;
begin
  Result := TStroke.Create(Kind);
  Result.Pts := Copy(Pts);
  Result.Width := Width;
  Result.Ink := Ink;
  Result.Sketchy := Sketchy;
end;

procedure TStroke.ToJSON(O: TJSONObject);
var
  A: TJSONArray;
  i: integer;
begin
  if Kind = stHatch then O.Add('kind', 'hatch') else O.Add('kind', 'line');
  O.Add('width', Width);
  O.Add('ink', Ink);
  O.Add('sketchy', Sketchy);
  A := TJSONArray.Create;
  // whole pixels and tenths are plenty for a hand drawing
  for i := 0 to High(Pts) do
  begin
    A.Add(Round(Pts[i].X * 10) / 10);
    A.Add(Round(Pts[i].Y * 10) / 10);
  end;
  O.Add('pts', A);
end;

procedure TStroke.FromJSON(O: TJSONObject);
var
  A: TJSONArray;
  i: integer;
begin
  if O.Get('kind', 'line') = 'hatch' then Kind := stHatch else Kind := stLine;
  Width := O.Get('width', 1.3);
  Ink := O.Get('ink', 0.85);
  Sketchy := O.Get('sketchy', False);
  if O.Find('pts') is TJSONArray then
  begin
    A := TJSONArray(O.Find('pts'));
    SetLength(Pts, A.Count div 2);
    for i := 0 to High(Pts) do
      Pts[i] := PointF(A.Floats[2 * i], A.Floats[2 * i + 1]);
  end;
end;

{ TSketchLayer }

constructor TSketchLayer.Create(const AName: string);
begin
  Name := AName;
  Visible := True;
  Strokes := TFPObjectList.Create(True);
end;

destructor TSketchLayer.Destroy;
begin
  Strokes.Free;
  inherited Destroy;
end;

function TSketchLayer.Clone: TSketchLayer;
var
  i: integer;
begin
  Result := TSketchLayer.Create(Name);
  Result.Visible := Visible;
  Result.Locked := Locked;
  for i := 0 to StrokeCount - 1 do Result.Strokes.Add(Stroke(i).Clone);
end;

function TSketchLayer.StrokeCount: integer;
begin
  Result := Strokes.Count;
end;

function TSketchLayer.Stroke(i: integer): TStroke;
begin
  Result := TStroke(Strokes[i]);
end;

{ TSketchDoc }

constructor TSketchDoc.Create;
begin
  Shapes := TFPObjectList.Create(True);
  Annots := TFPObjectList.Create(True);
  Layers := TFPObjectList.Create(True);
  Clear;
end;

destructor TSketchDoc.Destroy;
begin
  Shapes.Free;
  Annots.Free;
  Layers.Free;
  inherited Destroy;
end;

procedure TSketchDoc.Clear;
begin
  Title := 'Untitled';
  Shapes.Clear;
  Annots.Clear;
  Layers.Clear;
  Layers.Add(TSketchLayer.Create('Sketch 1'));
  ActiveLayer := 0;
  VP1 := PointF(-300, 260);
  VP2 := PointF(1500, 260);
  ViewYaw := -0.62;
  ViewPitch := 0.42;
  ViewDist := 50;
  ViewTarget := V3(0.4, 0.6, 4.2);
end;

function TSketchDoc.ShapeCount: integer;
begin
  Result := Shapes.Count;
end;

function TSketchDoc.Shape(i: integer): TShape;
begin
  Result := TShape(Shapes[i]);
end;

function TSketchDoc.AnnotCount: integer;
begin
  Result := Annots.Count;
end;

function TSketchDoc.Annot(i: integer): TAnnot;
begin
  Result := TAnnot(Annots[i]);
end;

function TSketchDoc.LayerCount: integer;
begin
  Result := Layers.Count;
end;

function TSketchDoc.Layer(i: integer): TSketchLayer;
begin
  Result := TSketchLayer(Layers[i]);
end;

function TSketchDoc.NextCalloutNumber: integer;
var
  i: integer;
begin
  Result := 1;
  for i := 0 to AnnotCount - 1 do
    if Annot(i).Kind = akCallout then Result := Max(Result, Annot(i).Number + 1);
end;

function TSketchDoc.UniqueName(const Base: string): string;
var
  n, i: integer;
  Taken: boolean;
begin
  n := 1;
  repeat
    Result := Format('%s %d', [Base, n]);
    Taken := False;
    for i := 0 to ShapeCount - 1 do
      if SameText(Shape(i).Name, Result) then Taken := True;
    Inc(n);
  until not Taken;
end;

function TSketchDoc.ToJSONString: string;
var
  Root, O: TJSONObject;
  Arr, LA: TJSONArray;
  i, j: integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('format', 'lz-sketch-editor');
    Root.Add('version', 1);
    Root.Add('title', Title);
    Root.Add('view', TJSONObject.Create(['yaw', ViewYaw, 'pitch', ViewPitch, 'distance', ViewDist,
      'target', VecJSON(ViewTarget)]));
    Arr := TJSONArray.Create;
    for i := 0 to ShapeCount - 1 do
    begin
      O := TJSONObject.Create;
      Shape(i).ToJSON(O);
      Arr.Add(O);
    end;
    Root.Add('shapes', Arr);
    Arr := TJSONArray.Create;
    for i := 0 to AnnotCount - 1 do
    begin
      O := TJSONObject.Create;
      Annot(i).ToJSON(O);
      Arr.Add(O);
    end;
    Root.Add('annotations', Arr);
    Arr := TJSONArray.Create;
    for i := 0 to LayerCount - 1 do
    begin
      LA := TJSONArray.Create;
      for j := 0 to Layer(i).StrokeCount - 1 do
      begin
        O := TJSONObject.Create;
        Layer(i).Stroke(j).ToJSON(O);
        LA.Add(O);
      end;
      Arr.Add(TJSONObject.Create(['name', Layer(i).Name, 'visible', Layer(i).Visible, 'locked', Layer(i).Locked,
        'strokes', LA]));
    end;
    Root.Add('layers', Arr);
    Root.Add('activeLayer', ActiveLayer);
    Root.Add('vanishingPoints', TJSONArray.Create([VP1.X, VP1.Y, VP2.X, VP2.Y]));
    Result := Root.FormatJSON([foSingleLineArray], 1);
  finally
    Root.Free;
  end;
end;

procedure TSketchDoc.FromJSONString(const S: string);
var
  D: TJSONData;
  Root, O, V: TJSONObject;
  Arr, LA, VP: TJSONArray;
  i, j: integer;
  Sh: TShape;
  An: TAnnot;
  L: TSketchLayer;
  St: TStroke;
begin
  D := GetJSON(S);
  try
    if not (D is TJSONObject) then raise Exception.Create('not a sketch document');
    Root := TJSONObject(D);
    Shapes.Clear;
    Annots.Clear;
    Layers.Clear;
    Title := Root.Get('title', 'Untitled');
    if Root.Find('view') is TJSONObject then
    begin
      V := TJSONObject(Root.Find('view'));
      ViewYaw := V.Get('yaw', -0.62);
      ViewPitch := V.Get('pitch', 0.42);
      ViewDist := V.Get('distance', 50.0);
      ViewTarget := JSONVec(V, 'target', V3(0, 0, 0));
    end;
    if Root.Find('shapes') is TJSONArray then
    begin
      Arr := TJSONArray(Root.Find('shapes'));
      for i := 0 to Arr.Count - 1 do
      begin
        Sh := TShape.Create(skBox);
        Sh.FromJSON(Arr.Objects[i]);
        Shapes.Add(Sh);
      end;
    end;
    if Root.Find('annotations') is TJSONArray then
    begin
      Arr := TJSONArray(Root.Find('annotations'));
      for i := 0 to Arr.Count - 1 do
      begin
        An := TAnnot.Create(akLabel);
        An.FromJSON(Arr.Objects[i]);
        Annots.Add(An);
      end;
    end;
    if Root.Find('layers') is TJSONArray then
    begin
      Arr := TJSONArray(Root.Find('layers'));
      for i := 0 to Arr.Count - 1 do
      begin
        O := Arr.Objects[i];
        L := TSketchLayer.Create(O.Get('name', 'Sketch'));
        L.Visible := O.Get('visible', True);
        L.Locked := O.Get('locked', False);
        if O.Find('strokes') is TJSONArray then
        begin
          LA := TJSONArray(O.Find('strokes'));
          for j := 0 to LA.Count - 1 do
          begin
            St := TStroke.Create(stLine);
            St.FromJSON(LA.Objects[j]);
            L.Strokes.Add(St);
          end;
        end;
        Layers.Add(L);
      end;
    end;
    if Layers.Count = 0 then Layers.Add(TSketchLayer.Create('Sketch 1'));
    ActiveLayer := EnsureRange(Root.Get('activeLayer', 0), 0, Layers.Count - 1);
    if Root.Find('vanishingPoints') is TJSONArray then
    begin
      VP := TJSONArray(Root.Find('vanishingPoints'));
      if VP.Count >= 4 then
      begin
        VP1 := PointF(VP.Floats[0], VP.Floats[1]);
        VP2 := PointF(VP.Floats[2], VP.Floats[3]);
      end;
    end;
  finally
    D.Free;
  end;
end;

procedure TSketchDoc.SaveToFile(const FileName: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := ToJSONString;
    L.SaveToFile(FileName);
  finally
    L.Free;
  end;
end;

procedure TSketchDoc.LoadFromFile(const FileName: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(FileName);
    FromJSONString(L.Text);
  finally
    L.Free;
  end;
end;

// The LZ-1 camera of the Camera Sketch program, rebuilt from editable shapes.
procedure TSketchDoc.LoadCameraPreset;

  function Add(AKind: TShapeKind; const AName: string; const APos: TVec3; AMat: TMaterial): TShape;
  begin
    Result := TShape.Create(AKind);
    Result.Name := AName;
    Result.Pos := APos;
    Result.Mat := AMat;
    Shapes.Add(Result);
  end;

  function Box(const AName: string; const APos, ASize: TVec3; ARadius: single; AMat: TMaterial): TShape;
  begin
    Result := Add(skBox, AName, APos, AMat);
    Result.Size := ASize;
    Result.Radius := ARadius;
  end;

  function Cyl(const AName: string; const APos: TVec3; R0, R1, H: single; Segs: integer; ARibbed: boolean;
    AMat: TMaterial; ATicks: integer = 0; LensAxis: boolean = False): TShape;
  begin
    Result := Add(skCylinder, AName, APos, AMat);
    Result.RBottom := R0;
    Result.RTop := R1;
    Result.Height := H;
    Result.Segments := Segs;
    Result.Ribbed := ARibbed;
    Result.Ticks := ATicks;
    if LensAxis then Result.Rot := V3(90, 0, 0);    // local Y -> world +Z
  end;

  function Loft(const AName: string; const APos: TVec3; ABW, ABD, ATW, ATD, H, C: single): TShape;
  begin
    Result := Add(skLoft, AName, APos, mtMetal);
    Result.BW := ABW;
    Result.BD := ABD;
    Result.TW := ATW;
    Result.TD := ATD;
    Result.Height := H;
    Result.Chamfer := C;
  end;

  procedure Dim(const A, B, Off: TVec3; const T: string);
  var
    An: TAnnot;
  begin
    An := TAnnot.Create(akDimension);
    An.A := A;
    An.B := B;
    An.Offset := Off;
    An.Text := T;
    Annots.Add(An);
  end;

  procedure Call(const A: TVec3; ADX, ADY: single; const T: string);
  var
    An: TAnnot;
  begin
    An := TAnnot.Create(akCallout);
    An.A := A;
    An.DX := ADX;
    An.DY := ADY;
    An.Text := T;
    An.Number := NextCalloutNumber;
    Annots.Add(An);
  end;

const
  LX = 0.6;
  LY = -0.2;
begin
  Clear;
  Title := 'LZ-1 camera';
  Box('Bottom plate', V3(0, -4.2, 0), V3(14, 0.6, 5), 1.0, mtMetal);
  Box('Body leatherette', V3(0, -0.65, 0), V3(13.8, 6.5, 4.8), 0.95, mtLeather);
  Box('Top plate', V3(0, 3.375, 0), V3(14, 1.55, 5), 1.0, mtMetal);
  Box('Top deck', V3(0, 4.325, 0), V3(13.6, 0.35, 4.6), 0.85, mtMetal);
  Box('Grip', V3(-5.4, -0.85, 3.55), V3(3.0, 6.9, 2.3), 0.9, mtRubber);
  Box('Grip deck', V3(-5.45, 3.55, 3.55), V3(3.1, 1.9, 2.3), 0.9, mtMetal).DepthBias := 0.1;
  Loft('Prism base', V3(0, 5.0, 0.1), 6.0, 4.8, 5.8, 4.55, 1.0, 0.45).DepthBias := 0.3;
  Loft('Prism hood', V3(0, 6.275, 0.05), 5.8, 4.55, 4.0, 2.65, 1.55, 0.4).DepthBias := 0.3;
  Loft('Prism roof', V3(0, 7.225, 0.025), 4.0, 2.65, 3.4, 2.15, 0.35, 0.3).DepthBias := 0.35;
  Box('Name plate', V3(0, 5.25, 2.65), V3(5.4, 1.0, 0.65), 0, mtMetal).DepthBias := 0.4;
  Box('Eyecup', V3(0, 5.85, -2.6), V3(3.6, 1.7, 0.9), 0.35, mtRubber).DepthBias := 0.3;
  Box('Hot shoe', V3(0, 7.475, 0.025), V3(2.9, 0.15, 2.05), 0, mtMetal).DepthBias := 0.45;
  Box('Shoe rail L', V3(-1.2, 7.7, 0.025), V3(0.5, 0.3, 2.05), 0, mtMetal).DepthBias := 0.5;
  Box('Shoe rail R', V3(1.2, 7.7, 0.025), V3(0.5, 0.3, 2.05), 0, mtMetal).DepthBias := 0.5;
  Cyl('Shutter dial skirt', V3(4.6, 4.575, 0.2), 2.2, 2.2, 0.15, 64, False, mtMetal).DepthBias := 0.4;
  Cyl('Shutter dial', V3(4.6, 5.125, 0.2), 2.0, 2.0, 0.95, 60, True, mtTeeth, 8).DepthBias := 0.5;
  Cyl('Shutter dial knob', V3(4.6, 5.75, 0.2), 0.75, 0.75, 0.3, 40, True, mtTeeth).DepthBias := 0.6;
  Cyl('ISO dial skirt', V3(-4.9, 4.575, -0.8), 1.7, 1.7, 0.15, 56, False, mtMetal).DepthBias := 0.4;
  Cyl('ISO dial', V3(-4.9, 4.975, -0.8), 1.5, 1.5, 0.65, 48, True, mtTeeth, 7).DepthBias := 0.5;
  Cyl('ISO dial knob', V3(-4.9, 5.525, -0.8), 0.95, 0.95, 0.45, 40, True, mtTeeth).DepthBias := 0.6;
  Cyl('Release collar', V3(-5.4, 4.65, 3.3), 0.95, 0.95, 0.3, 40, True, mtTeeth).DepthBias := 0.5;
  Cyl('Shutter button', V3(-5.4, 5.05, 3.3), 0.55, 0.55, 0.5, 28, False, mtMetal).DepthBias := 0.6;
  Box('Strap lug', V3(7.25, 2.7, 0), V3(0.5, 1.0, 0.7), 0, mtMetal);
  Cyl('AF lamp', V3(-2.9, 1.6, 2.6), 0.4, 0.35, 0.4, 20, False, mtMetal, 0, True).DepthBias := 0.2;
  Cyl('Lens release', V3(4.6, -1.6, 2.65), 0.6, 0.55, 0.5, 24, False, mtMetal, 0, True).DepthBias := 0.2;
  Cyl('Bayonet mount', V3(LX, LY, 2.75), 3.55, 3.55, 0.5, 64, False, mtMetal, 32, True);
  Cyl('Rear barrel', V3(LX, LY, 3.45), 3.4, 3.45, 0.9, 64, False, mtMetal, 0, True);
  Cyl('Zoom ring', V3(LX, LY, 5.75), 3.75, 3.75, 3.7, 150, True, mtKnurl, 0, True);
  Cyl('Distance scale', V3(LX, LY, 8.0), 3.5, 3.5, 0.8, 72, False, mtMetal, 36, True);
  Cyl('Focus ring', V3(LX, LY, 9.5), 3.8, 3.8, 2.2, 160, True, mtKnurl, 0, True);
  Cyl('Inner barrel', V3(LX, LY, 11.2), 3.45, 3.45, 1.2, 64, False, mtMetal, 0, True);
  Cyl('Filter flare', V3(LX, LY, 12.15), 3.55, 4.25, 0.7, 72, False, mtMetal, 0, True);
  Cyl('Front ring', V3(LX, LY, 13.1), 4.3, 4.3, 1.2, 120, True, mtMetal, 0, True);
  Cyl('Front glass', V3(LX, LY, 13.6), 3.65, 3.65, 0.1, 64, False, mtGlass, 0, True).DepthBias := 0.1;
  Dim(V3(-7, 4.5, -2.5), V3(7, 4.5, -2.5), V3(0, 4.6, 0), '140');
  Dim(V3(7, -4.5, -2.5), V3(7, 4.5, -2.5), V3(3.6, 0, -0.8), '90');
  Dim(V3(LX, LY - 4.3, 2.5), V3(LX, LY - 4.3, 13.7), V3(3.6, -0.2, 0), '');
  Call(V3(2.0, 6.6, 1.6), 70, -40, 'Pentaprism');
  Call(V3(6.4, 5.6, 0.2), 70, -30, 'Shutter dial');
  Call(V3(LX, LY + 3.8, 9.5), -80, -60, 'Focus ring');
  Call(V3(-6.6, -1.0, 4.2), -70, 20, 'Grip');
  Layers.Clear;
  Layers.Add(TSketchLayer.Create('Construction'));
  Layers.Add(TSketchLayer.Create('Sketch'));
  ActiveLayer := 1;
end;

end.
