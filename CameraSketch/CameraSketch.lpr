program CameraSketch;

{ LZ-1 Camera Sketch - an animated pencil drawing of a camera, after a
  technical sketch. The scene is in usketchscene.pas, the multi-core
  rasteriser in urenderpool.pas, the window and OpenGL output in umain.pas. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, USketchScene, URenderPool, UMain;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
