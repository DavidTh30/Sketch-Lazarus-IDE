program SketchEditor;

{ LZ Sketch Editor - edit a model made of boxes, cylinders and lofts, annotate
  it and sketch over it, all drawn as a pencil study with BGRABitmap on every
  core and shown through OpenGL at 60 Hz. The renderer is shared with Camera
  Sketch (../CameraSketch: uprimtypes, urenderpool, uexport, ulog).

  Command line: SketchEditor [file.sketch.json]
                SketchEditor --selftest <folder>   drive every mode, then quit }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  SysUtils, Forms, UModel, UDocScene, UEditor;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TEditorForm, EditorForm);
  if (ParamCount = 1) and FileExists(ParamStr(1)) then
  begin
    EditorForm.Doc.LoadFromFile(ParamStr(1));
    EditorForm.FileName := ParamStr(1);
  end;
  Application.Run;
end.
