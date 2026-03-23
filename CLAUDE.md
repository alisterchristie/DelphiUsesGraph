# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DelphiUsesGraph is a command-line tool that generates Graphviz dependency graphs from Delphi source code. It analyzes `.pas` and `.dpr` files to extract `uses` clauses from both interface and implementation sections, then outputs a DOT format graph showing the dependency relationships.

## Building and Running

This is a Delphi console application built with Embarcadero Delphi.

**Build the project:**
- Open `DelphiUsesGraph.dproj` in Delphi IDE and build (F9)
- Or use MSBuild from command line: `msbuild DelphiUsesGraph.dproj /p:Config=Release`

**Run the tool:**
```
DelphiUsesGraph <project_file.dpr> [output_file] [options]
```

Arguments:
- `project_file.dpr`: Path to Delphi project file (required, must be .dpr)
- `output_file`: Output .dot file (default: uses_graph.dot)
- `-rtl`: Include RTL/VCL units in the graph
- `-h, --help`: Show help

**Visualize output:**
```
dot -Tpng uses_graph.dot -o uses_graph.png
dot -Tsvg uses_graph.dot -o uses_graph.svg
```

## Architecture

The application consists of two files:
- `DelphiUsesGraph.dpr` - Main program with command-line argument parsing
- `UsesGraphGenerator.pas` - Core parsing and graph generation logic

### Core Components

**TUnitSection** (enum): Identifies which section of a unit is being parsed
- `usInterface`: Interface section
- `usImplementation`: Implementation section

**TUnitDependency** (record): Stores parsed information about a single unit
- `UnitName`: The unit or program name
- `InterfaceUses`: Array of units used in interface section
- `ImplementationUses`: Array of units used in implementation section

**TProjectFileReference** (record): Maps unit names to their file paths from `in 'path'` syntax in .dpr files

**TUsesGraphGenerator** (class): Main engine that orchestrates the entire process

### Processing Pipeline

1. **Project File Parsing** - `ScanProjectFiles()` reads the .dpr file and extracts unit references using `ExtractProjectFileReferences()` which finds `UnitName in 'FilePath'` patterns
2. **Comment Stripping** - `StripComments()` removes all Delphi comment styles (// { } (* *)) while preserving strings and compiler directives ({$...})
3. **Name Extraction** - `ExtractUnitName()` uses regex to parse unit/program declarations
4. **Uses Extraction** - `ExtractUsesClause()` parses interface and implementation uses clauses, handling multi-line syntax and `in 'path'` specifications
5. **Graph Generation** - `WriteDotFile()` outputs DOT format with color-coded edges and nodes

### Critical Implementation Details

**Comment Stripping (`UsesGraphGenerator.pas:66-172`):**
The parser uses a character-by-character state machine tracking:
- `InLineComment` for `//` comments (terminates at newline)
- `InBraceComment` for `{ }` comments (skips compiler directives `{$...}`)
- `InParenComment` for `(* *)` comments
- `InString` for single-quoted strings (prevents false positives on `'//'` etc.)

**Uses Clause Extraction (`UsesGraphGenerator.pas:185-253`):**
- Finds section keyword (`interface`/`implementation`) first
- Locates `uses` keyword after section start
- For interface uses: validates we don't cross into implementation section
- Handles multi-line uses clauses up to semicolon
- Strips `in 'path'` syntax via regex
- Returns deduplicated, sorted array of unit names

**DOT Format Output (`UsesGraphGenerator.pas:410-514`):**
- Sanitizes unit names (replaces `.` with `_` for Graphviz compatibility)
- Edge deduplication via EdgeKey dictionary (source->target+type)
- Color coding:
  - `lightgreen` fill: Project units
  - `lightblue` fill: RTL units (default node style)
  - `blue` solid line: Interface dependency on project unit
  - `gray` solid line: Interface dependency on RTL unit
  - `darkgreen` dashed line: Implementation dependency on project unit
  - `lightgray` dashed line: Implementation dependency on RTL unit

### Data Flow

1. User provides `.dpr` project file path
2. `ScanProjectFiles()` parses the project file and extracts `in 'path'` references
3. For each referenced unit file:
   - `ParseUnit()` reads file content
   - `StripComments()` preprocesses source
   - `ExtractUnitName()` gets the unit name
   - `ExtractUsesClause()` extracts interface and implementation uses
   - Store in `FProjectUnits` dictionary (keyed by lowercase unit name)
4. `WriteDotFile()` iterates all parsed units and generates DOT graph
5. `WriteStats()` outputs summary statistics

## Configuration

The project uses MSBuild/Delphi project format (.dproj):
- Target platform: Win32 (primary)
- Configuration: Debug (with range checking, overflow checking) and Release
- No external dependencies beyond standard RTL units (System.SysUtils, System.Classes, System.IOUtils, System.Generics.Collections, System.RegularExpressions)
