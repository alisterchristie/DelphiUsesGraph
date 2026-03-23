unit UsesGraphGenerator;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.RegularExpressions;

type
  TUnitSection = (usInterface, usImplementation);

  TUnitDependency = record
    UnitName: string;
    InterfaceUses: TArray<string>;
    ImplementationUses: TArray<string>;
  end;

  TProjectFileReference = record
    UnitName: string;
    FilePath: string;
  end;

  TUsesGraphGenerator = class
  private
    FProjectUnits: TDictionary<string, TUnitDependency>;
    FIncludeRTL: Boolean;
    FProjectFile: string;
    FProjectDir: string;

    function StripComments(const ASource: string): string;
    function ExtractUnitName(const ASource: string): string;
    function ExtractUsesClause(const ASource: string; ASection: TUnitSection): TArray<string>;
    function ExtractProjectFileReferences(const ASource: string): TArray<TProjectFileReference>;
    function ParseUnit(const AFileName: string): TUnitDependency;
    procedure ScanProjectFiles(const AProjectFile: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Generate(const AProjectFile, AOutputFile: string; AIncludeRTL: Boolean);
    procedure WriteDotFile(const AFileName: string);
    procedure WriteStats;
  end;

procedure ShowHelp;

implementation

{ TUsesGraphGenerator }

constructor TUsesGraphGenerator.Create;
begin
  inherited;
  FProjectUnits := TDictionary<string, TUnitDependency>.Create;
end;

destructor TUsesGraphGenerator.Destroy;
begin
  FProjectUnits.Free;
  inherited;
end;

function TUsesGraphGenerator.StripComments(const ASource: string): string;
var
  I: Integer;
  InLineComment: Boolean;
  InBraceComment: Boolean;
  InParenComment: Boolean;
  InString: Boolean;
  C, NextC: Char;
  Builder: TStringBuilder;
begin
  Builder := TStringBuilder.Create;
  try
    InLineComment := False;
    InBraceComment := False;
    InParenComment := False;
    InString := False;
    I := 1;

    while I <= Length(ASource) do
    begin
      C := ASource[I];
      NextC := #0;
      if I < Length(ASource) then
        NextC := ASource[I + 1];

      // Handle line endings for line comments
      if InLineComment then
      begin
        if (C = #13) or (C = #10) then
        begin
          InLineComment := False;
          Builder.Append(C);
        end;
        Inc(I);
        Continue;
      end;

      // Handle brace comments { }
      if InBraceComment then
      begin
        if C = '}' then
          InBraceComment := False;
        Inc(I);
        Continue;
      end;

      // Handle paren comments (* *)
      if InParenComment then
      begin
        if (C = '*') and (NextC = ')') then
        begin
          InParenComment := False;
          Inc(I, 2);
          Continue;
        end;
        Inc(I);
        Continue;
      end;

      // Handle strings
      if InString then
      begin
        Builder.Append(C);
        if C = '''' then
          InString := False;
        Inc(I);
        Continue;
      end;

      // Check for comment starts
      if C = '''' then
      begin
        InString := True;
        Builder.Append(C);
        Inc(I);
        Continue;
      end;

      if (C = '/') and (NextC = '/') then
      begin
        InLineComment := True;
        Inc(I, 2);
        Continue;
      end;

      if (C = '{') and (NextC <> '$') then  // Skip compiler directives
      begin
        InBraceComment := True;
        Inc(I);
        Continue;
      end;

      if (C = '(') and (NextC = '*') then
      begin
        InParenComment := True;
        Inc(I, 2);
        Continue;
      end;

      Builder.Append(C);
      Inc(I);
    end;

    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function TUsesGraphGenerator.ExtractUnitName(const ASource: string): string;
var
  Match: TMatch;
begin
  Result := '';
  Match := TRegEx.Match(ASource, '(?i)^\s*unit\s+([a-z_][a-z0-9_.]*)\s*;');
  if Match.Success then
    Result := Match.Groups[1].Value;
end;

function TUsesGraphGenerator.ExtractUsesClause(const ASource: string; ASection: TUnitSection): TArray<string>;
var
  SectionStart, UsesStart, UsesEnd: Integer;
  UsesText: string;
  Units: TStringList;
  UnitName: string;
  Pattern: string;
begin
  Result := [];
  Units := TStringList.Create;
  try
    Units.Duplicates := dupIgnore;
    Units.Sorted := True;

    // Find section start
    case ASection of
      usInterface: Pattern := '(?i)\binterface\b';
      usImplementation: Pattern := '(?i)\bimplementation\b';
    end;

    SectionStart := 0;
    var SectionMatch := TRegEx.Match(ASource, Pattern);
    if SectionMatch.Success then
      SectionStart := SectionMatch.Index;

    if SectionStart = 0 then
      Exit;

    // Find "uses" after section start
    var UsesMatch := TRegEx.Match(ASource.Substring(SectionStart - 1), '(?i)\buses\b');
    if not UsesMatch.Success then
      Exit;
    UsesStart := SectionStart + UsesMatch.Index - 1;

    // Make sure we don't cross into implementation section when looking for interface uses
    if ASection = usInterface then
    begin
      var ImplMatch := TRegEx.Match(ASource, '(?i)\bimplementation\b');
      if ImplMatch.Success and (ImplMatch.Index < UsesStart) then
        Exit;
    end;

    // Find the semicolon that ends the uses clause
    UsesEnd := Pos(';', ASource, UsesStart);
    if UsesEnd = 0 then
      Exit;

    UsesText := Copy(ASource, UsesStart, UsesEnd - UsesStart);

    // Remove "uses" keyword and clean up
    UsesText := TRegEx.Replace(UsesText, '(?i)^\s*uses\s+', '');
    UsesText := StringReplace(UsesText, #13, ' ', [rfReplaceAll]);
    UsesText := StringReplace(UsesText, #10, ' ', [rfReplaceAll]);

    // Handle "in 'path'" syntax
    UsesText := TRegEx.Replace(UsesText, '\s+in\s+''[^'']*''', '');

    // Split by comma
    for UnitName in UsesText.Split([',']) do
    begin
      if Trim(UnitName) <> '' then
        Units.Add(Trim(UnitName));
    end;

    Result := Units.ToStringArray;
  finally
    Units.Free;
  end;
end;

function TUsesGraphGenerator.ExtractProjectFileReferences(const ASource: string): TArray<TProjectFileReference>;
var
  UsesStart, UsesEnd: Integer;
  UsesText: string;
  Matches: TMatchCollection;
  Match: TMatch;
  Refs: TList<TProjectFileReference>;
  Ref: TProjectFileReference;
begin
  Result := [];
  Refs := TList<TProjectFileReference>.Create;
  try
    // Find "uses" keyword after "program" declaration
    var UsesMatch := TRegEx.Match(ASource, '(?i)\buses\b');
    if not UsesMatch.Success then
      Exit;

    UsesStart := UsesMatch.Index;

    // Find the semicolon that ends the uses clause
    UsesEnd := Pos(';', ASource, UsesStart);
    if UsesEnd = 0 then
      Exit;

    UsesText := Copy(ASource, UsesStart, UsesEnd - UsesStart);

    // Pattern to match: UnitName in 'FilePath' or UnitName in 'FilePath' {TClassName}
    // Examples:
    //   UsesGraphGenerator in 'UsesGraphGenerator.pas'
    //   MainForm in 'MainForm.pas' {TMainForm}
    var Pattern := '([a-z_][a-z0-9_.]*)\s+in\s+''([^'']+)''';
    Matches := TRegEx.Matches(UsesText, Pattern, [roIgnoreCase]);

    for Match in Matches do
    begin
      if Match.Success and (Match.Groups.Count >= 3) then
      begin
        Ref.UnitName := Match.Groups[1].Value;
        Ref.FilePath := Match.Groups[2].Value;
        Refs.Add(Ref);
      end;
    end;

    Result := Refs.ToArray;
  finally
    Refs.Free;
  end;
end;

function TUsesGraphGenerator.ParseUnit(const AFileName: string): TUnitDependency;
var
  Source, CleanSource: string;
begin
  Result := Default(TUnitDependency);

  try
    Source := TFile.ReadAllText(AFileName, TEncoding.Default);
  except
    on E: Exception do
    begin
      Writeln('  Error reading file: ', E.Message);
      Exit;
    end;
  end;

  CleanSource := StripComments(Source);

  Result.UnitName := ExtractUnitName(CleanSource);
  if Result.UnitName = '' then
  begin
    // Might be a .dpr file
    var ProgramMatch := TRegEx.Match(CleanSource, '(?i)^\s*program\s+([a-z_][a-z0-9_.]*)\s*;');
    if ProgramMatch.Success then
      Result.UnitName := ProgramMatch.Groups[1].Value;
  end;

  if Result.UnitName = '' then
    Exit;

  Result.InterfaceUses := ExtractUsesClause(CleanSource, usInterface);
  Result.ImplementationUses := ExtractUsesClause(CleanSource, usImplementation);
end;

procedure TUsesGraphGenerator.ScanProjectFiles(const AProjectFile: string);
var
  ProjectSource, CleanSource: string;
  FileRefs: TArray<TProjectFileReference>;
  FileRef: TProjectFileReference;
  FullPath: string;
  Dependency: TUnitDependency;
begin
  // Read and parse the project file
  try
    ProjectSource := TFile.ReadAllText(AProjectFile, TEncoding.Default);
  except
    on E: Exception do
    begin
      Writeln('Error reading project file: ', E.Message);
      Exit;
    end;
  end;

  CleanSource := StripComments(ProjectSource);

  // First, parse the project file itself
  Write('Parsing: ', ExtractFileName(AProjectFile), '... ');
  Dependency := ParseUnit(AProjectFile);
  if Dependency.UnitName <> '' then
  begin
    FProjectUnits.AddOrSetValue(LowerCase(Dependency.UnitName), Dependency);
    Writeln('OK (', Length(Dependency.InterfaceUses), ' intf, ',
            Length(Dependency.ImplementationUses), ' impl uses)');
  end
  else
    Writeln('Skipped (no unit name found)');

  // Extract file references from the project uses clause
  FileRefs := ExtractProjectFileReferences(CleanSource);

  Writeln;
  Writeln('Found ', Length(FileRefs), ' explicitly referenced unit(s) in project file');
  Writeln;

  // Parse each referenced unit file
  for FileRef in FileRefs do
  begin
    // Resolve relative path based on project directory
    if TPath.IsPathRooted(FileRef.FilePath) then
      FullPath := FileRef.FilePath
    else
      FullPath := TPath.Combine(FProjectDir, FileRef.FilePath);

    // Normalize path
    FullPath := TPath.GetFullPath(FullPath);

    Write('Parsing: ', ExtractFileName(FullPath), '... ');

    if not TFile.Exists(FullPath) then
    begin
      Writeln('Not found at: ', FullPath);
      Continue;
    end;

    Dependency := ParseUnit(FullPath);
    if Dependency.UnitName <> '' then
    begin
      FProjectUnits.AddOrSetValue(LowerCase(Dependency.UnitName), Dependency);
      Writeln('OK (', Length(Dependency.InterfaceUses), ' intf, ',
              Length(Dependency.ImplementationUses), ' impl uses)');
    end
    else
      Writeln('Skipped (no unit name found)');
  end;
end;

procedure TUsesGraphGenerator.WriteDotFile(const AFileName: string);
var
  Output: TStringList;
  Pair: TPair<string, TUnitDependency>;
  UsedUnit: string;
  EdgeSet: TDictionary<string, Boolean>;
  EdgeKey: string;

  function IsProjectUnit(const AName: string): Boolean;
  begin
    Result := FProjectUnits.ContainsKey(LowerCase(AName));
  end;

  function ShouldInclude(const AName: string): Boolean;
  begin
    if FIncludeRTL then
      Result := True
    else
      Result := IsProjectUnit(AName);
  end;

  function SanitizeName(const AName: string): string;
  begin
    // Replace dots with underscores for DOT format
    Result := StringReplace(AName, '.', '_', [rfReplaceAll]);
  end;

begin
  Output := TStringList.Create;
  EdgeSet := TDictionary<string, Boolean>.Create;  // Prevent duplicate edges
  try
    Output.Add('digraph DelphiUses {');
    Output.Add('  // Graph settings');
    Output.Add('  rankdir=LR;');
    Output.Add('  node [shape=box, style=filled, fillcolor=lightblue, fontname="Consolas"];');
    Output.Add('  edge [fontname="Consolas", fontsize=9];');
    Output.Add('');
    Output.Add('  // Legend');
    Output.Add('  subgraph cluster_legend {');
    Output.Add('    label="Legend";');
    Output.Add('    style=dashed;');
    Output.Add('    legend_intf [label="Interface uses", shape=plaintext];');
    Output.Add('    legend_impl [label="Implementation uses", shape=plaintext];');
    Output.Add('    legend_intf -> legend_impl [style=solid, label="interface"];');
    Output.Add('    legend_impl -> legend_intf [style=dashed, label="impl", constraint=false];');
    Output.Add('  }');
    Output.Add('');

    // Define nodes for project units
    Output.Add('  // Project units');
    for Pair in FProjectUnits do
      Output.Add(Format('  %s [fillcolor=lightgreen];', [SanitizeName(Pair.Value.UnitName)]));
    Output.Add('');

    // Define edges
    Output.Add('  // Dependencies');
    for Pair in FProjectUnits do
    begin
      // Interface uses - solid lines
      for UsedUnit in Pair.Value.InterfaceUses do
      begin
        if ShouldInclude(UsedUnit) then
        begin
          EdgeKey := LowerCase(Pair.Value.UnitName + '->' + UsedUnit + '_intf');
          if not EdgeSet.ContainsKey(EdgeKey) then
          begin
            EdgeSet.Add(EdgeKey, True);
            if IsProjectUnit(UsedUnit) then
              Output.Add(Format('  %s -> %s [color=blue];',
                [SanitizeName(Pair.Value.UnitName), SanitizeName(UsedUnit)]))
            else
              Output.Add(Format('  %s -> %s [color=gray];',
                [SanitizeName(Pair.Value.UnitName), SanitizeName(UsedUnit)]));
          end;
        end;
      end;

      // Implementation uses - dashed lines
      for UsedUnit in Pair.Value.ImplementationUses do
      begin
        if ShouldInclude(UsedUnit) then
        begin
          EdgeKey := LowerCase(Pair.Value.UnitName + '->' + UsedUnit + '_impl');
          if not EdgeSet.ContainsKey(EdgeKey) then
          begin
            EdgeSet.Add(EdgeKey, True);
            if IsProjectUnit(UsedUnit) then
              Output.Add(Format('  %s -> %s [style=dashed, color=darkgreen];',
                [SanitizeName(Pair.Value.UnitName), SanitizeName(UsedUnit)]))
            else
              Output.Add(Format('  %s -> %s [style=dashed, color=lightgray];',
                [SanitizeName(Pair.Value.UnitName), SanitizeName(UsedUnit)]));
          end;
        end;
      end;
    end;

    Output.Add('}');

    Output.SaveToFile(AFileName);
    Writeln('DOT file saved to: ', AFileName);
  finally
    EdgeSet.Free;
    Output.Free;
  end;
end;

procedure TUsesGraphGenerator.WriteStats;
var
  TotalIntf, TotalImpl: Integer;
  Pair: TPair<string, TUnitDependency>;
begin
  TotalIntf := 0;
  TotalImpl := 0;

  for Pair in FProjectUnits do
  begin
    Inc(TotalIntf, Length(Pair.Value.InterfaceUses));
    Inc(TotalImpl, Length(Pair.Value.ImplementationUses));
  end;

  Writeln;
  Writeln('=== Statistics ===');
  Writeln('Units parsed: ', FProjectUnits.Count);
  Writeln('Interface dependencies: ', TotalIntf);
  Writeln('Implementation dependencies: ', TotalImpl);
  Writeln('Total dependencies: ', TotalIntf + TotalImpl);
end;

procedure TUsesGraphGenerator.Generate(const AProjectFile, AOutputFile: string; AIncludeRTL: Boolean);
begin
  FProjectFile := AProjectFile;
  FProjectDir := TPath.GetDirectoryName(AProjectFile);
  FIncludeRTL := AIncludeRTL;
  FProjectUnits.Clear;

  Writeln('Analyzing project: ', ExtractFileName(AProjectFile));
  Writeln('Project directory: ', FProjectDir);
  Writeln;

  ScanProjectFiles(AProjectFile);
  WriteStats;

  Writeln;
  WriteDotFile(AOutputFile);
end;

procedure ShowHelp;
begin
  Writeln('DelphiUsesGraph - Generate Graphviz dependency graph from Delphi project');
  Writeln;
  Writeln('Usage: DelphiUsesGraph <project_file.dpr> [output_file] [options]');
  Writeln;
  Writeln('Arguments:');
  Writeln('  project_file  Path to Delphi project file (.dpr)');
  Writeln('  output_file   Output .dot file (default: uses_graph.dot)');
  Writeln;
  Writeln('Options:');
  Writeln('  -rtl          Include RTL/VCL units in the graph');
  Writeln('  -h, --help    Show this help');
  Writeln;
  Writeln('Description:');
  Writeln('  This tool analyzes the uses clause in the .dpr file and creates a');
  Writeln('  dependency graph for all units explicitly referenced with the');
  Writeln('  "in ''filename.pas''" syntax.');
  Writeln;
  Writeln('Examples:');
  Writeln('  DelphiUsesGraph MyProject.dpr');
  Writeln('  DelphiUsesGraph MyProject.dpr output.dot');
  Writeln('  DelphiUsesGraph MyProject.dpr output.dot -rtl');
  Writeln;
  Writeln('To render the graph:');
  Writeln('  1. Install Graphviz from https://graphviz.org/');
  Writeln('  2. Run: dot -Tpng uses_graph.dot -o uses_graph.png');
  Writeln('  Or use online viewers like https://dreampuf.github.io/GraphvizOnline/');
end;

end.
