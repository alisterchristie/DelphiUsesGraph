program DelphiUsesGraph;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.IOUtils,
  UsesGraphGenerator in 'UsesGraphGenerator.pas';

var
  Generator: TUsesGraphGenerator;
  ProjectFile, OutputFile: string;
  IncludeRTL: Boolean;
  I: Integer;
begin
  try
    if (ParamCount < 1) or (ParamStr(1) = '-h') or (ParamStr(1) = '--help') then
    begin
      ShowHelp;
      Exit;
    end;

    ProjectFile := ParamStr(1);
    OutputFile := 'uses_graph.dot';
    IncludeRTL := False;

    // Parse additional arguments
    for I := 2 to ParamCount do
    begin
      if SameText(ParamStr(I), '-rtl') then
        IncludeRTL := True
      else if not ParamStr(I).StartsWith('-') then
        OutputFile := ParamStr(I);
    end;

    if not TFile.Exists(ProjectFile) then
    begin
      Writeln('Error: Project file does not exist: ', ProjectFile);
      ExitCode := 1;
      Exit;
    end;

    if not SameText(TPath.GetExtension(ProjectFile), '.dpr') then
    begin
      Writeln('Error: File must be a Delphi project file (.dpr)');
      ExitCode := 1;
      Exit;
    end;

    Generator := TUsesGraphGenerator.Create;
    try
      Generator.Generate(ProjectFile, OutputFile, IncludeRTL);
      Writeln;
      Writeln('Done! To visualize:');
      Writeln('  dot -Tpng ', OutputFile, ' -o uses_graph.png');
      Writeln('  dot -Tsvg ', OutputFile, ' -o uses_graph.svg');
    finally
      Generator.Free;
    end;

  except
    on E: Exception do
    begin
      Writeln('Error: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
