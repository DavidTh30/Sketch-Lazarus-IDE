unit UAudio;

{ Sound effects, synthesised at start-up (no sound files): 16-bit mono WAV
  images in memory, played with PlaySound(SND_MEMORY or SND_ASYNC).
  PlaySound plays one sound at a time; a new one cuts the previous one,
  which suits short mechanical clicks. Volume is baked into the samples,
  so changing it rebuilds the buffers (after stopping playback). }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, MMSystem,{$ENDIF}
  Classes, SysUtils, Math;

type
  TSound = (sndShutter, sndAutofocus, sndDial, sndWhoosh, sndTick);

const
  SoundNames: array[TSound] of string = ('Shutter click', 'Autofocus beep', 'Dial detent', 'Explode whoosh',
    'Zoom tick');
  SampleRate = 44100;

type

  { TAudio }

  TAudio = class
  private
    FWav: array[TSound] of TBytes;
    FVolume: single;
    FEnabled: boolean;
    procedure SetVolume(AValue: single);
    procedure Build;
    function Synth(S: TSound): TBytes;
  public
    SoundOn: array[TSound] of boolean;
    PlayCount: array[TSound] of integer;
    LastSound: string;
    constructor Create;
    destructor Destroy; override;
    procedure Play(S: TSound; Force: boolean = False);
    procedure Stop;
    function DurationMs(S: TSound): integer;
    function ByteSize(S: TSound): integer;
    property Volume: single read FVolume write SetVolume;
    property Enabled: boolean read FEnabled write FEnabled;
  end;

implementation

uses
  ULog;

constructor TAudio.Create;
var
  S: TSound;
begin
  FEnabled := True;
  FVolume := 0.6;
  for S := Low(TSound) to High(TSound) do SoundOn[S] := True;
  SoundOn[sndTick] := False;         // zoom ticks are many; off by default
  Build;
end;

destructor TAudio.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TAudio.Stop;
begin
  {$IFDEF WINDOWS}
  PlaySound(nil, 0, 0);
  {$ENDIF}
end;

procedure TAudio.SetVolume(AValue: single);
begin
  AValue := EnsureRange(AValue, 0, 1);
  if Abs(AValue - FVolume) < 0.005 then Exit;
  FVolume := AValue;
  Stop;                              // the buffer being played is about to change
  Build;
end;

procedure TAudio.Build;
var
  S: TSound;
begin
  for S := Low(TSound) to High(TSound) do FWav[S] := Synth(S);
end;

function TAudio.DurationMs(S: TSound): integer;
begin
  Result := (Length(FWav[S]) - 44) div 2 * 1000 div SampleRate;
end;

function TAudio.ByteSize(S: TSound): integer;
begin
  Result := Length(FWav[S]);
end;

procedure TAudio.Play(S: TSound; Force: boolean);
begin
  if not Force and (not FEnabled or not SoundOn[S]) then Exit;
  Inc(PlayCount[S]);
  LastSound := SoundNames[S];
  {$IFDEF WINDOWS}
  PlaySound(PChar(@FWav[S][0]), 0, SND_MEMORY or SND_ASYNC or SND_NODEFAULT);
  {$ENDIF}
  Log('audio', 'play ' + SoundNames[S]);
end;

// Short mechanical sounds from noise bursts, decaying sines and a sweep.
function TAudio.Synth(S: TSound): TBytes;
var
  Smp: array of single;
  n, i: integer;
  t, v, Seed, Lp, Peak: single;
  R: cardinal;

  function Noise: single;
  begin
    R := R * 1664525 + 1013904223;
    Result := ((R shr 8) and $FFFF) / 32768 - 1;
  end;

  // click: filtered noise with a sharp attack and fast decay, starting at T0 (s)
  procedure Click(T0, Decay, Gain, Tone: single);
  var
    k, k0: integer;
    e: single;
  begin
    k0 := Round(T0 * SampleRate);
    Lp := 0;
    for k := k0 to n - 1 do
    begin
      e := Exp(-(k - k0) / SampleRate / Decay);
      if e < 0.001 then Break;
      Lp := Lp + (Noise - Lp) * Tone;
      Smp[k] := Smp[k] + Lp * e * Gain;
    end;
  end;

  procedure Sine(T0, Dur, Freq, Gain, Decay: single);
  var
    k, k0, k1: integer;
    tt, e: single;
  begin
    k0 := Round(T0 * SampleRate);
    k1 := Min(n - 1, k0 + Round(Dur * SampleRate));
    for k := k0 to k1 do
    begin
      tt := (k - k0) / SampleRate;
      e := Min(1, tt / 0.002) * Exp(-tt / Decay);        // 2 ms attack
      Smp[k] := Smp[k] + Sin(2 * Pi * Freq * tt) * e * Gain;
    end;
  end;

begin
  R := 12345 + Ord(S) * 7919;
  case S of
    sndShutter:   n := Round(0.22 * SampleRate);
    sndAutofocus: n := Round(0.16 * SampleRate);
    sndDial:      n := Round(0.04 * SampleRate);
    sndWhoosh:    n := Round(0.45 * SampleRate);
  else
    n := Round(0.02 * SampleRate);
  end;
  SetLength(Smp, n);
  case S of
    sndShutter:
      begin
        // mirror up, first curtain, second curtain, plus a low body thump
        Click(0.000, 0.012, 1.0, 0.55);
        Sine(0.000, 0.08, 140, 0.35, 0.03);
        Click(0.045, 0.008, 0.7, 0.8);
        Click(0.085, 0.015, 0.9, 0.5);
        Sine(0.085, 0.10, 110, 0.3, 0.04);
      end;
    sndAutofocus:
      begin
        Sine(0.000, 0.045, 2730, 0.35, 0.05);
        Sine(0.075, 0.045, 2730, 0.35, 0.05);
      end;
    sndDial:
      begin
        Click(0.0, 0.004, 0.8, 0.9);
        Sine(0.0, 0.03, 2100, 0.25, 0.008);
      end;
    sndWhoosh:
      begin
        Lp := 0;
        for i := 0 to n - 1 do
        begin
          t := i / n;
          // band of noise whose brightness sweeps up and down
          Seed := 0.02 + 0.25 * Sin(Pi * t);
          Lp := Lp + (Noise - Lp) * Seed;
          Smp[i] := Lp * Sin(Pi * t) * 1.4;
        end;
      end;
    sndTick:
      Click(0.0, 0.002, 0.5, 0.9);
  end;
  // normalise to the volume
  Peak := 1e-6;
  for i := 0 to n - 1 do Peak := Max(Peak, Abs(Smp[i]));
  // RIFF header + data
  SetLength(Result, 44 + n * 2);
  Move(PChar('RIFF')^, Result[0], 4);
  PLongWord(@Result[4])^ := 36 + n * 2;
  Move(PChar('WAVEfmt ')^, Result[8], 8);
  PLongWord(@Result[16])^ := 16;
  PWord(@Result[20])^ := 1;                    // PCM
  PWord(@Result[22])^ := 1;                    // mono
  PLongWord(@Result[24])^ := SampleRate;
  PLongWord(@Result[28])^ := SampleRate * 2;
  PWord(@Result[32])^ := 2;
  PWord(@Result[34])^ := 16;
  Move(PChar('data')^, Result[36], 4);
  PLongWord(@Result[40])^ := n * 2;
  for i := 0 to n - 1 do
  begin
    v := Smp[i] / Peak * FVolume * 0.9;
    PSmallInt(@Result[44 + i * 2])^ := Round(EnsureRange(v, -1, 1) * 32767);
  end;
end;

end.
