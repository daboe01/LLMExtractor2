@import <AppKit/AppKit.j>
@import <Foundation/CPObject.j>

@global CPBackgroundColorAttributeName;
var ExtractionIdentifierAttributeName = @"ExtractionIdentifierAttributeName";

// Model representing a single Schema node
@implementation SchemaNode : CPObject
{
    CPString _key @accessors(property=key);
    CPString _type @accessors(property=type);
    CPString _desc @accessors(property=desc);
    CPString _retrievalSource @accessors(property=retrievalSource);
    CPMutableArray _children @accessors(property=children);
}

- (id)init
{
    self = [super init];
    if (self)
    {
        _key = @"new_field";
        _type = @"string";
        _desc = @"Instructions";
        _retrievalSource = @"- none -";
        _children = [CPMutableArray array];
    }
    return self;
}

- (BOOL)isLeaf
{
    return !(_type === @"array" || _type === @"object");
}

- (id)valueForKey:(CPString)aKey
{
    if (aKey === @"key") return _key;
    if (aKey === @"type") return _type;
    if (aKey === @"desc") return _desc;
    if (aKey === @"retrievalSource") return _retrievalSource;
    if (aKey === @"children") return _children;
    return [super valueForKey:aKey];
}

- (void)setValue:(id)aValue forKey:(CPString)aKey
{
    if (aKey === @"key") { _key = aValue; return; }
    if (aKey === @"type") { _type = aValue; return; }
    if (aKey === @"desc") { _desc = aValue; return; }
    if (aKey === @"retrievalSource") { _retrievalSource = aValue; return; }
    if (aKey === @"children") { _children = aValue; return; }
    [super setValue:aValue forKey:aKey];
}

@end

// --------------------------------------------------------------------------------
// AppController: Master Prompt, Editable Outline Schema, and Results Grid Table
// --------------------------------------------------------------------------------
@implementation AppController : CPObject
{
    CPTextView          _editorTextView;
    
    // Config controls
    CPTextView          _promptTextView;
    
    // Graphical Schema Outline Editor & Controller
    CPOutlineView       _schemaOutlineView;
    CPTreeController    _treeController;
    
    // Extraction Results Table view
    CPTableView         _resultsTableView;
    CPArray             _tableData;
    
    CPButton            _extractButton;
    CPProgressIndicator _progressBar;
    CPTextField         _statusLabel;
    CPPopUpButton       _modelPopUp;
    
    CPArray             _highlights;
    CPDictionary        _extractedFlatData;
    BOOL                _isProgrammaticSelection;
    
    // Import-Export JSON Panel
    CPPanel             _debugPanel;
    CPTextView          _jsonDebugTextView;
    
    // Backend Base URL Definition (Port 4005)
    CPString            backendBaseURL;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    // Backend-URL für alle API-Aufrufe festlegen
    backendBaseURL = @"";

    _tableData = [CPArray array];
    _highlights = [CPArray array];

    var theWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1300, 850) styleMask:CPBorderlessBridgeWindowMask];
    [theWindow setTitle:@"Editable Chunked Data Extraction & Schema Editor"];
    [theWindow center];

    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    // --- TOP BAR CONTROL PANEL ---
    var topBar = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), 60)];
    [topBar setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [topBar setBackgroundColor:[CPColor colorWithWhite:0.96 alpha:1.0]];
    [contentView addSubview:topBar];

    var modelLabel = [CPTextField labelWithTitle:@"Model:"];
    [modelLabel setFrameOrigin:CGPointMake(20, 20)];
    [modelLabel setFont:[CPFont boldSystemFontOfSize:12]];
    [topBar addSubview:modelLabel];

    _modelPopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(70, 16, 180, 26) pullsDown:NO];
    [_modelPopUp addItemWithTitle:@"gpt-oss-120b"];
    [[_modelPopUp lastItem] setRepresentedObject:@"gpt-oss-120b"];
    [_modelPopUp addItemWithTitle:@"qwen36-35b-a3b"];
    [[_modelPopUp lastItem] setRepresentedObject:@"qwen36-35b-a3b"];
    [topBar addSubview:_modelPopUp];
    [_modelPopUp addItemWithTitle:@"ollama"];
    [[_modelPopUp lastItem] setRepresentedObject:@"ollama"];

    _extractButton = [[CPButton alloc] initWithFrame:CGRectMake(265, 16, 170, 26)];
    [_extractButton setTitle:@"Extract Structured Chunks"];
    [_extractButton setTarget:self];
    [_extractButton setAction:@selector(runExtraction:)];
    [_extractButton setToolTip:@"Run structural chunked document extraction across active segments."];
    [topBar addSubview:_extractButton];

    _progressBar = [[CPProgressIndicator alloc] initWithFrame:CGRectMake(450, 22, 120, 14)];
    [_progressBar setStyle:CPProgressIndicatorBarStyle];
    [_progressBar setIndeterminate:YES];
    [_progressBar setHidden:YES];
    [topBar addSubview:_progressBar];

    var schemaJsonBtn = [[CPButton alloc] initWithFrame:CGRectMake(585, 16, 130, 26)];
    [schemaJsonBtn setTitle:@"Schema JSON"];
    [schemaJsonBtn setTarget:self];
    [schemaJsonBtn setAction:@selector(openSchemaJSONPanel:)];
    [topBar addSubview:schemaJsonBtn];

    _statusLabel = [CPTextField labelWithTitle:@"Analyze or alter the visual tree nodes to begin."];
    [_statusLabel setFrame:CGRectMake(725, 20, 550, 20)];
    [_statusLabel setTextColor:[CPColor colorWithWhite:0.4 alpha:1.0]];
    [_statusLabel setAutoresizingMask:CPViewWidthSizable];
    [topBar addSubview:_statusLabel];

    // --- MAIN SPLIT CONTAINER VIEW ---
    var splitHeight = CGRectGetHeight(bounds) - 60;
    var mainSplitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 60, CGRectGetWidth(bounds), splitHeight)];
    [mainSplitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [mainSplitView setVertical:YES];
    [mainSplitView setDelegate:self];

    var dividerWidth = [mainSplitView dividerThickness];
    var leftWidth = (CGRectGetWidth([mainSplitView bounds]) - dividerWidth) * 0.50;
    var rightWidth = (CGRectGetWidth([mainSplitView bounds]) - dividerWidth) - leftWidth;

    // --- LEFT PANE ---
    var editorScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [editorScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [editorScroll setAutohidesScrollers:YES];

    _editorTextView = [[CPTextView alloc] initWithFrame:[editorScroll bounds]];
    [_editorTextView setAutoresizingMask:CPViewWidthSizable];
    [_editorTextView setMinSize:CGSizeMake(0, 0)];
    [_editorTextView setMaxSize:CGSizeMake(100000, 100000)];
    [_editorTextView setHorizontallyResizable:NO];
    [_editorTextView setVerticallyResizable:YES];
    [_editorTextView setRichText:YES];
    [_editorTextView setFont:[CPFont fontWithName:@"Arial" size:13.0]];
    [_editorTextView setDelegate:self];
    [[_editorTextView textContainer] setWidthTracksTextView:YES];

    [editorScroll setDocumentView:_editorTextView];
    [mainSplitView addSubview:editorScroll];

    // --- RIGHT PANE ---
    var rightSplitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight)];
    [rightSplitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightSplitView setVertical:NO];
    [rightSplitView setDelegate:self];

    var promptHeight = 120.0;
    var remainingHeight = splitHeight - promptHeight;
    var halfHeight = remainingHeight / 2.0;

    var promptBox = [[CPBox alloc] initWithFrame:CGRectMake(0, 0, rightWidth, promptHeight)];
    [promptBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [promptBox setFillColor:[CPColor colorWithWhite:0.98 alpha:1.0]];
    [promptBox setBorderType:CPLineBorder];
    [promptBox setBorderColor:[CPColor colorWithWhite:0.90 alpha:1.0]];
    [promptBox setBorderWidth:1.0];
    [promptBox setTitle:@"Master Extraction Prompt"];

    var promptScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 20, rightWidth - 30, promptHeight - 40)];
    [promptScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    _promptTextView = [[CPTextView alloc] initWithFrame:[promptScroll bounds]];
    [_promptTextView setFont:[CPFont systemFontOfSize:12]];
    [promptScroll setDocumentView:_promptTextView];
    [promptBox addSubview:promptScroll];

    // Box 2: Graphical Schema Outline Editor
    var outlineBox = [[CPBox alloc] initWithFrame:CGRectMake(0, 0, rightWidth, halfHeight)];
    [outlineBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [outlineBox setFillColor:[CPColor colorWithWhite:0.98 alpha:1.0]];
    [outlineBox setBorderType:CPLineBorder];
    [outlineBox setBorderColor:[CPColor colorWithWhite:0.90 alpha:1.0]];
    [outlineBox setBorderWidth:1.0];
    [outlineBox setTitle:@"Graphical Schema Tree Editor (CPOutlineView)"];

    var outlineScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 20, rightWidth - 30, halfHeight - 65)];
    [outlineScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [outlineScroll setAutohidesScrollers:YES];

    _schemaOutlineView = [[CPOutlineView alloc] initWithFrame:[outlineScroll bounds]];
    [_schemaOutlineView setRowHeight:22.0];
    [_schemaOutlineView setCornerView:nil];
    
    _treeController = [[CPTreeController alloc] init];
    [_treeController setChildrenKeyPath:@"children"];
    [_treeController setLeafKeyPath:@"isLeaf"];
    
    [_schemaOutlineView bind:@"content" toObject:_treeController withKeyPath:@"arrangedObjects" options:nil];
    [_schemaOutlineView bind:@"selectionIndexPaths" toObject:_treeController withKeyPath:@"selectionIndexPaths" options:nil];
    [_schemaOutlineView setDelegate:self];

    var colKey = [[CPTableColumn alloc] initWithIdentifier:@"key"];
    [[colKey headerView] setStringValue:@"Field Key"];
    [colKey setWidth:140];
    [colKey setEditable:YES];
    var colKeyField = [[CPTextField alloc] initWithFrame:CGRectMakeZero()];
    [colKeyField setEditable:YES];
    [colKey setDataView:colKeyField];
    [_schemaOutlineView addTableColumn:colKey];

    var colType = [[CPTableColumn alloc] initWithIdentifier:@"type"];
    [[colType headerView] setStringValue:@"Type"];
    [colType setWidth:110];
    [colType setEditable:YES];
    
    var colTypePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMakeZero() pullsDown:NO];
    [colTypePopUp addItemsWithTitles:[@"string", @"number", @"array", @"object"]];
    [colTypePopUp setTarget:self];
    [colTypePopUp setAction:@selector(typeDidChange:)];
    [colType setDataView:colTypePopUp];
    [_schemaOutlineView addTableColumn:colType];

    // Dense Retrieval Column
    var colRetrieval = [[CPTableColumn alloc] initWithIdentifier:@"retrievalSource"];
    [[colRetrieval headerView] setStringValue:@"Coding via vectorsearch"];
    [colRetrieval setWidth:160];
    [colRetrieval setEditable:YES];

    var colRetrievalPopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMakeZero() pullsDown:NO];
    // Pre-populate prototype with fallback options from the start so that initial selections work
    var defaultItems = [
        @"- none -",
        @"TEXT2ATC",
        @"hpo_vaa_e5",
        @"hpo_fd_e5",
        @"GOA_orig_english",
        @"GOA_Phi",
        @"HPO_full",
        @"HPO_modifiers",
        @"TEXT2ICD"
    ];
    [colRetrievalPopUp addItemsWithTitles:defaultItems];
    [colRetrievalPopUp setTarget:self];
    [colRetrievalPopUp setAction:@selector(retrievalSourceDidChange:)];
    [colRetrieval setDataView:colRetrievalPopUp];
    [_schemaOutlineView addTableColumn:colRetrieval];

    var colDesc = [[CPTableColumn alloc] initWithIdentifier:@"desc"];
    [[colDesc headerView] setStringValue:@"Instructions / Description"];
    [colDesc setWidth:180];
    [colDesc setEditable:YES];
    var colDescField = [[CPTextField alloc] initWithFrame:CGRectMakeZero()];
    [colDescField setEditable:YES];
    [colDesc setDataView:colDescField];
    [_schemaOutlineView addTableColumn:colDesc];

    [outlineScroll setDocumentView:_schemaOutlineView];
    [outlineBox addSubview:outlineScroll];

    var addBtn = [[CPButton alloc] initWithFrame:CGRectMake(15, halfHeight - 36, 120, 24)];
    [addBtn setAutoresizingMask:CPViewMinYMargin];
    [addBtn setTitle:@"Add Schema Field"];
    [addBtn setTarget:self];
    [addBtn setAction:@selector(addOutlineNode:)];
    [outlineBox addSubview:addBtn];

    var remBtn = [[CPButton alloc] initWithFrame:CGRectMake(145, halfHeight - 36, 140, 24)];
    [remBtn setAutoresizingMask:CPViewMinYMargin];
    [remBtn setTitle:@"Remove Selected"];
    [remBtn setTarget:self];
    [remBtn setAction:@selector(removeOutlineNode:)];
    [outlineBox addSubview:remBtn];

    // Box 3: Table Results Container
    var resultsBox = [[CPBox alloc] initWithFrame:CGRectMake(0, 0, rightWidth, halfHeight)];
    [resultsBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [resultsBox setFillColor:[CPColor colorWithWhite:0.95 alpha:1.0]];
    [resultsBox setBorderType:CPLineBorder];
    [resultsBox setBorderColor:[CPColor colorWithWhite:0.90 alpha:1.0]];
    [resultsBox setBorderWidth:1.0];
    [resultsBox setTitle:@"Extracted Field Results"];

    var tableScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 20, rightWidth - 30, halfHeight - 65)];
    [tableScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [tableScroll setAutohidesScrollers:YES];

    _resultsTableView = [[CPTableView alloc] initWithFrame:[tableScroll bounds]];
    [_resultsTableView setUsesAlternatingRowBackgroundColors:YES];
    [_resultsTableView setCornerView:nil];
    [_resultsTableView setRowHeight:22.0];
    [_resultsTableView setDelegate:self];
    [_resultsTableView setDataSource:self];

    var colResPath = [[CPTableColumn alloc] initWithIdentifier:@"field_path"];
    [[colResPath headerView] setStringValue:@"Resolved Key Path"];
    [colResPath setWidth:140];
    [colResPath setEditable:YES];
    var colResPathField = [[CPTextField alloc] initWithFrame:CGRectMakeZero()];
    [colResPathField setEditable:YES];
    [colResPath setDataView:colResPathField];
    [_resultsTableView addTableColumn:colResPath];

    var colResVal = [[CPTableColumn alloc] initWithIdentifier:@"value"];
    [[colResVal headerView] setStringValue:@"Extracted Value"];
    [colResVal setWidth:240];
    [colResVal setEditable:YES];
    var colResValField = [[CPTextField alloc] initWithFrame:CGRectMakeZero()];
    [colResValField setEditable:YES];
    [colResVal setDataView:colResValField];
    [_resultsTableView addTableColumn:colResVal];

    var colResVerbatim = [[CPTableColumn alloc] initWithIdentifier:@"exact_text"];
    [[colResVerbatim headerView] setStringValue:@"Source Verbatim Match"];
    [colResVerbatim setWidth:240];
    [colResVerbatim setEditable:YES];
    var colResVerbatimField = [[CPTextField alloc] initWithFrame:CGRectMakeZero()];
    [colResVerbatimField setEditable:YES];
    [colResVerbatim setDataView:colResVerbatimField];
    [_resultsTableView addTableColumn:colResVerbatim];

    [tableScroll setDocumentView:_resultsTableView];
    [resultsBox addSubview:tableScroll];

    var exportCsvBtn = [[CPButton alloc] initWithFrame:CGRectMake(15, halfHeight - 38, 180, 24)];
    [exportCsvBtn setAutoresizingMask:CPViewMinYMargin];
    [exportCsvBtn setTitle:@"Export Results as CSV"];
    [exportCsvBtn setTarget:self];
    [exportCsvBtn setAction:@selector(exportResultsToCSV:)];
    [resultsBox addSubview:exportCsvBtn];

    [rightSplitView addSubview:promptBox];
    [rightSplitView addSubview:outlineBox];
    [rightSplitView addSubview:resultsBox];

    [mainSplitView addSubview:rightSplitView];
    [contentView addSubview:mainSplitView];

    [theWindow orderFront:self];

    [self setupDebugPanel];

    [self loadInitialDemoSetup];

    [self fetchVectorstores];
}

// --- DYNAMIC VECTORSTORE METADATA RETRIEVAL ---
- (void)fetchVectorstores
{
    [_statusLabel setStringValue:@"Fetching active datasets from Patchbay..."];
    
    // Richtet die Abfrage explizit an das Backend auf Port 4005
    var requestUrl = backendBaseURL + @"/embedded_datasets";
    var request = [CPURLRequest requestWithURL:requestUrl
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:15.0];

    [request setHTTPMethod:@"GET"];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        var items = ["- none -", "TEXT2ATC", "hpo_vaa_e5", "hpo_fd_e5", "GOA_orig_english", "GOA_Phi", "HPO_full", "HPO_modifiers", "TEXT2ICD"];
        
        if (!error && data) {
            try {
                var res = JSON.parse(data);
                if (res.items && Array.isArray(res.items)) {
                    items = res.items;
                } else if (Array.isArray(res)) {
                    items = res;
                }
                
                // Ensure "- none -" remains at the top
                var noneIdx = items.indexOf("- none -");
                if (noneIdx !== -1) {
                    items.splice(noneIdx, 1);
                }
                items.unshift("- none -");
                
                // Ensure "TEXT2ATC" is also in the list if missing from live list
                if (items.indexOf("TEXT2ATC") === -1) {
                    items.push("TEXT2ATC");
                }
                
                [_statusLabel setStringValue:@"Datasets synchronized via Mojolicious backend."];
            } catch (e) {
                CPLog.error(@"Parsing error on vectorstores payload: " + e.message);
                [_statusLabel setStringValue:@"Synchronized using local fallback schemas."];
            }
        } else {
            [_statusLabel setStringValue:@"Backend or Patchbay offline. Using local defaults."];
        }
        
        var colRetrieval = [_schemaOutlineView tableColumnWithIdentifier:@"retrievalSource"];
        if (colRetrieval) {
            var colRetrievalPopUp = [colRetrieval dataView];
            if (colRetrievalPopUp) {
                [colRetrievalPopUp removeAllItems];
                [colRetrievalPopUp addItemsWithTitles:items];
            }
        }
        
        // Reload outline view so already rendered cell structures can synchronize their selections
        [_schemaOutlineView reloadData];
    }];
}

// --- DEBUG/IMPORT-EXPORT PANEL SETUP ---

- (void)setupDebugPanel
{
    _debugPanel = [[CPPanel alloc] initWithContentRect:CGRectMake(1320, 100, 480, 600) styleMask:CPTitledWindowMask | CPClosableWindowMask | CPResizableWindowMask];
    [_debugPanel setTitle:@"Schema JSON Import & Export Panel"];
    
    var panelContentView = [_debugPanel contentView];
    var panelBounds = [panelContentView bounds];
    
    var scroll = [[CPScrollView alloc] initWithFrame:CGRectMake(10, 10, CGRectGetWidth(panelBounds) - 20, CGRectGetHeight(panelBounds) - 100)];
    [scroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [scroll setAutohidesScrollers:YES];
    
    _jsonDebugTextView = [[CPTextView alloc] initWithFrame:[scroll bounds]];
    [_jsonDebugTextView setAutoresizingMask:CPViewWidthSizable];
    [_jsonDebugTextView setFont:[CPFont fontWithName:@"Courier" size:12]];
    [_jsonDebugTextView setEditable:YES];
    [scroll setDocumentView:_jsonDebugTextView];
    [panelContentView addSubview:scroll];
    
    var buttonWidth = (CGRectGetWidth(panelBounds) - 30) / 2;

    var refreshBtn = [[CPButton alloc] initWithFrame:CGRectMake(10, CGRectGetHeight(panelBounds) - 80, buttonWidth, 24)];
    [refreshBtn setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin | CPViewMaxXMargin];
    [refreshBtn setTitle:@"Export/Refresh JSON"];
    [refreshBtn setTarget:self];
    [refreshBtn setAction:@selector(refreshDebugJSON:)];
    [panelContentView addSubview:refreshBtn];
    
    var importBtn = [[CPButton alloc] initWithFrame:CGRectMake(10 + buttonWidth + 10, CGRectGetHeight(panelBounds) - 80, buttonWidth, 24)];
    [importBtn setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin | CPViewMinXMargin];
    [importBtn setTitle:@"Import JSON to Tree"];
    [importBtn setTarget:self];
    [importBtn setAction:@selector(importSchemaFromJSON:)];
    [panelContentView addSubview:importBtn];

    var closeBtn = [[CPButton alloc] initWithFrame:CGRectMake(10, CGRectGetHeight(panelBounds) - 45, CGRectGetWidth(panelBounds) - 20, 24)];
    [closeBtn setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin];
    [closeBtn setTitle:@"Close Panel"];
    [closeBtn setTarget:self];
    [closeBtn setAction:@selector(closeSchemaJSONPanel:)];
    [panelContentView addSubview:closeBtn];
}

- (void)openSchemaJSONPanel:(id)sender
{
    [self refreshDebugJSON:nil];
    [_debugPanel orderFront:self];
}

- (void)closeSchemaJSONPanel:(id)sender
{
    [_debugPanel orderOut:self];
}

- (void)refreshDebugJSON:(id)sender
{
    var jsonString = [self exportSchemaToJSONString];
    [_jsonDebugTextView setString:jsonString];
}

- (void)importSchemaFromJSON:(id)sender
{
    var jsonStr = [_jsonDebugTextView string];
    if (!jsonStr || [jsonStr length] === 0) {
        [_statusLabel setStringValue:@"Import failed: Schema JSON content is empty."];
        return;
    }
    
    try {
        [self loadSchemaFromJSONString:jsonStr];
        [_statusLabel setStringValue:@"Schema imported successfully."];
    } catch (e) {
        [_statusLabel setStringValue:@"Failed to parse or load schema JSON."];
        CPLog.error(@"Schema Import Error: " + e.message);
    }
}

// --- CSV EXPORT DOWNLOAD CONTROLLER ---

- (void)exportResultsToCSV:(id)sender
{
    if ([_tableData count] === 0) {
        [_statusLabel setStringValue:@"No extraction data available to export."];
        return;
    }

    var csv = "Resolved Key Path,Extracted Value,Source Verbatim Match\n";
    
    var escapeCSV = function(str) {
        if (str === null || str === undefined) return "";
        str = "" + str;
        if (str.indexOf(',') !== -1 || str.indexOf('\n') !== -1 || str.indexOf('"') !== -1) {
            return '"' + str.replace(/"/g, '""') + '"';
        }
        return str;
    };

    for (var i = 0; i < [_tableData count]; i++) {
        var rowItem = [_tableData objectAtIndex:i];
        var path = [rowItem objectForKey:@"field_path"] || @"";
        var val = [rowItem objectForKey:@"value"] || @"";
        var text = [rowItem objectForKey:@"exact_text"] || @"";

        csv += escapeCSV(path) + "," + escapeCSV(val) + "," + escapeCSV(text) + "\n";
    }

    try {
        var blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
        var url = URL.createObjectURL(blob);
        var link = document.createElement("a");
        link.setAttribute("href", url);
        link.setAttribute("download", "extracted_results.csv");
        link.style.visibility = 'hidden';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        [_statusLabel setStringValue:@"Results exported successfully as CSV."];
    } catch (e) {
        [_statusLabel setStringValue:@"Failed to export CSV."];
        CPLog.error(@"CSV Export Error: " + e.message);
    }
}

// --- TREE EXPANSION & SYNCHRONIZATION ---

- (void)refreshAndExpand
{
    [self expandAllNodes];
    [self refreshDebugJSON:nil];
}

- (void)expandAllNodes
{
    var rootNodes = [_treeController contentArray];
    if (!rootNodes) return;
    
    for (var i = 0; i < [rootNodes count]; i++)
    {
        var indexPath = [CPIndexPath indexPathWithIndex:i];
        [self expandNodeAtIndexPath:indexPath];
    }
}

- (void)expandNodeAtIndexPath:(CPIndexPath)indexPath
{
    var treeNode = [[_treeController arrangedObjects] descendantNodeAtIndexPath:indexPath];
    if (treeNode)
    {
        [_schemaOutlineView expandItem:treeNode];
        
        var representedNode = [treeNode representedObject];
        if (representedNode)
        {
            var children = [representedNode children];
            if (children && [children count] > 0)
            {
                for (var j = 0; j < [children count]; j++)
                {
                    var childIndexPath = [indexPath indexPathByAddingIndex:j];
                    [self expandNodeAtIndexPath:childIndexPath];
                }
            }
        }
    }
}

- (void)controlTextDidEndEditing:(CPNotification)aNotification
{
    [self performSelector:@selector(refreshAndExpand) withObject:nil afterDelay:0.0];
}

// --- JSON DESERIALIZATION SETUP ---

- (void)loadInitialDemoSetup
{
    [_editorTextView setString:@"PATIENT INTAKE RECORDS\n\nDate of Entry: October 14, 2025\nName: Clara Sterling\n\nClinical Diagnostics Summary:\n- Localized pulmonary hypertension with pulmonary vascular congestion.\n- Active severe emphysema.\n\nActive Prescriptions:\n1. Albuterol sulfate 2.5 mg nebulizer inhalation twice daily.\n2. Prednisone 40 mg oral tablet once daily."];

    [_promptTextView setString:@"Extract key administrative details, precise patient identification metadata, explicit clinical diagnostic summaries, and complete active pharmacological prescriptions detailing names and schedules."];

    var demoJSONString = '[' +
        '{"key":"patient_name", "type":"string", "desc":"The full name of the patient", "retrievalSource":"- none -", "children":[]},' +
        '{"key":"admission_date", "type":"string", "desc":"Date patient was admitted (YYYY-MM-DD)", "retrievalSource":"- none -", "children":[]},' +
        '{"key":"diagnoses", "type":"array", "desc":"List of active diagnoses", "retrievalSource":"TEXT2ICD", "children":[]},' +
        '{"key":"prescriptions", "type":"array", "desc":"List of prescribed medications", "retrievalSource":"- none -", "children":[' +
            '{"key":"drug_name", "type":"string", "desc":"Brand or generic label of drug", "retrievalSource":"TEXT2ATC", "children":[]},' +
            '{"key":"dosage_schedule", "type":"string", "desc":"Administration instructions", "retrievalSource":"- none -", "children":[]}' +
        ']}' +
    ']';

    [self loadSchemaFromJSONString:demoJSONString];
}

- (void)loadSchemaFromJSONString:(CPString)jsonString
{
    var jsArray = JSON.parse(jsonString);
    var rootNodes = [CPMutableArray array];
    
    for (var i = 0; i < jsArray.length; i++)
    {
        var node = [self nodeFromJSObject:jsArray[i]];
        [rootNodes addObject:node];
    }
    
    [_treeController setContent:rootNodes];
    
    [self refreshAndExpand];
}

- (SchemaNode)nodeFromJSObject:(id)jsObj
{
    var node = [[SchemaNode alloc] init];
    [node setKey:jsObj.key || @""];
    [node setType:jsObj.type || @"string"];
    [node setDesc:jsObj.desc || @""];
    [node setRetrievalSource:jsObj.retrievalSource || @"- none -"];
    
    var children = [CPMutableArray array];
    if (jsObj.children && jsObj.children.length > 0)
    {
        for (var i = 0; i < jsObj.children.length; i++)
            [children addObject:[self nodeFromJSObject:jsObj.children[i]]];
    }
    [node setChildren:children];
    return node;
}

// --- JSON SERIALIZATION EXPORT ---

- (CPString)exportSchemaToJSONString
{
    var rootNodes = [_treeController contentArray];
    if (!rootNodes) return @"[]";
    
    var jsArray = [];
    for (var i = 0; i < [rootNodes count]; i++)
    {
        var node = [rootNodes objectAtIndex:i];
        jsArray.push([self jsObjectFromNode:node]);
    }
    return JSON.stringify(jsArray, null, 2);
}

- (id)jsObjectFromNode:(SchemaNode)node
{
    var jsObj = {
        "key": [node key] || @"",
        "type": [node type] || @"string",
        "desc": [node desc] || @"",
        "retrievalSource": [node retrievalSource] || @"- none -",
        "children": []
    };
    
    var children = [node children];
    if (children)
    {
        for (var i = 0; i < [children count]; i++)
        {
            var childNode = [children objectAtIndex:i];
            jsObj.children.push([self jsObjectFromNode:childNode]);
        }
    }
    return jsObj;
}

// --- NODE MANIPULATION ---

- (void)addOutlineNode:(id)sender
{
    var selectedNodes = [_treeController selectedNodes];
    var selectedNode = [selectedNodes count] > 0 ? [selectedNodes objectAtIndex:0] : nil;
    var selectedSchemaNode = [selectedNode representedObject];
    
    var newItem = [[SchemaNode alloc] init];

    if (selectedSchemaNode) {
        var nodeType = [selectedSchemaNode type];
        if (nodeType === @"array" || nodeType === @"object") {
            [[selectedSchemaNode children] addObject:newItem];
            [_treeController rearrangeObjects];
        } else {
            var parentNode = [selectedNode parentNode];
            var parentSchemaNode = [parentNode representedObject];
            if (parentSchemaNode) {
                [[parentSchemaNode children] addObject:newItem];
            } else {
                [[_treeController contentArray] addObject:newItem];
            }
            [_treeController rearrangeObjects];
        }
    } else {
        [[_treeController contentArray] addObject:newItem];
        [_treeController rearrangeObjects];
    }
    
    [self refreshAndExpand];
}

- (void)removeOutlineNode:(id)sender
{
    var selectedNodes = [_treeController selectedNodes];
    if ([selectedNodes count] === 0) return;

    var selectedNode = [selectedNodes objectAtIndex:0];
    var selectedSchemaNode = [selectedNode representedObject];
    var parentNode = [selectedNode parentNode];
    var parentSchemaNode = [parentNode representedObject];

    if (parentSchemaNode) {
        [[parentSchemaNode children] removeObject:selectedSchemaNode];
    } else {
        [[_treeController contentArray] removeObject:selectedSchemaNode];
    }
    [_treeController rearrangeObjects];
    
    [self refreshAndExpand];
}

// --- RESULTS TABLE MANIPULATION ---

- (void)addResultRow:(id)sender
{
    var newRow = [CPMutableDictionary dictionaryWithObjectsAndKeys:
        @"custom_field", @"field_path",
        @"custom_value", @"value",
        @"custom_text", @"exact_text"
    ];
    [_tableData addObject:newRow];
    [_resultsTableView reloadData];
    
    var nextRowIdx = [_tableData count] - 1;
    [_resultsTableView selectRowIndexes:[CPIndexSet indexSetWithIndex:nextRowIdx] byExtendingSelection:NO];
    [_resultsTableView scrollRowToVisible:nextRowIdx];
}

- (void)removeResultRow:(id)sender
{
    var selectedRow = [_resultsTableView selectedRow];
    if (selectedRow === -1) return;
    
    var itemToRemove = [_tableData objectAtIndex:selectedRow];
    var pathKey = [itemToRemove objectForKey:@"field_path"];
    
    [_tableData removeObjectAtIndex:selectedRow];
    [_resultsTableView reloadData];
    
    var textStorage = [_editorTextView textStorage];
    for (var i = 0; i < [_highlights count]; i++) {
        var h = [_highlights objectAtIndex:i];
        if (h.field_path === pathKey) {
            var textRange = CPMakeRange(h.offset, h.length);
            [textStorage removeAttribute:CPBackgroundColorAttributeName range:textRange];
            [_highlights removeObjectAtIndex:i];
            break;
        }
    }
}

// --- RECURSIVE SCHEMA COMPILATION ---

- (id)compileSchemaFromNode:(SchemaNode)node
{
    var type = [node type];
    var desc = [node desc];
    var retrieval = [node retrievalSource] || @"- none -";

    if (type === @"string") {
        return { "type": "string", "description": desc, "retrievalSource": retrieval };
    }
    if (type === @"number") {
        return { "type": "number", "description": desc, "retrievalSource": retrieval };
    }
    if (type === @"array") {
        var itemsSchema = { "type": "string" };
        var children = [node children];
        
        if (children && [children count] > 0) {
            var properties = {};
            var required = [];
            for (var i = 0; i < [children count]; i++) {
                var child = [children objectAtIndex:i];
                var key = [child key];
                properties[key] = [self compileSchemaFromNode:child];
                required.push(key);
            }
            itemsSchema = {
                "type": "object",
                "properties": properties,
                "required": required
            };
        }
        return {
            "type": "array",
            "items": itemsSchema,
            "description": desc,
            "retrievalSource": retrieval
        };
    }
    if (type === @"object") {
        var properties = {};
        var required = [];
        var children = [node children];
        for (var i = 0; i < [children count]; i++) {
            var child = [children objectAtIndex:i];
            var key = [child key];
            properties[key] = [self compileSchemaFromNode:child];
            required.push(key);
        }
        return {
            "type": "object",
            "properties": properties,
            "required": required,
            "retrievalSource": retrieval
        };
    }
    return { "type": "string", "description": desc, "retrievalSource": retrieval };
}

- (id)generateJSONSchemaFromVisualTree
{
    var targetSchema = {
        "type": "object",
        "properties": {},
        "required": []
    };

    var rootNodes = [_treeController contentArray];
    for (var i = 0; i < [rootNodes count]; i++) {
        var node = [rootNodes objectAtIndex:i];
        var key = [node key];
        if (key && [key length] > 0) {
            key = key.trim().replace(/\s+/g, '_');
            targetSchema.properties[key] = [self compileSchemaFromNode:node];
            targetSchema.required.push(key);
        }
    }

    return targetSchema;
}

// --- TARGET-ACTION INLINE POPUP COMMIT ---

- (void)typeDidChange:(id)sender
{
    var row = [_schemaOutlineView rowForView:sender];

    if (row === CPNotFound || row === -1)
        return;

    var treeNode = [_schemaOutlineView itemAtRow:row];
    var schemaNode = [treeNode representedObject];
    var newType = [sender titleOfSelectedItem];

    if (schemaNode && newType)
    {
        [schemaNode setType:newType];
        [_treeController rearrangeObjects];
        [self refreshAndExpand];
    }
}

- (void)retrievalSourceDidChange:(id)sender
{
    var row = [_schemaOutlineView rowForView:sender];

    if (row === CPNotFound || row === -1)
        return;

    var treeNode = [_schemaOutlineView itemAtRow:row];
    var schemaNode = [treeNode representedObject];
    var newSource = [sender titleOfSelectedItem];

    if (schemaNode && newSource)
    {
        [schemaNode setRetrievalSource:newSource];
        [_treeController rearrangeObjects];
        [self refreshAndExpand];
    }
}

// --- CPOUTLINEVIEW DELEGATE ---

- (void)outlineView:(CPOutlineView)outlineView willDisplayView:(CPView)view forTableColumn:(CPTableColumn)tableColumn item:(id)item
{
    if ([[tableColumn identifier] isEqualToString:@"type"])
    {
        var schemaNode = [item representedObject];
        if (schemaNode)
        {
            var type = [schemaNode type];
            [view selectItemWithTitle:type];
        }
    }
    else if ([[tableColumn identifier] isEqualToString:@"retrievalSource"])
    {
        var schemaNode = [item representedObject];
        if (schemaNode)
        {
            var retrieval = [schemaNode retrievalSource];
            [view selectItemWithTitle:retrieval || @"- none -"];
        }
    }
}

- (BOOL)outlineView:(CPOutlineView)outlineView shouldEditTableColumn:(CPTableColumn)tableColumn item:(id)item
{
    return YES;
}

// --- ACTION EXTRACTION PROCESSOR ---

- (void)runExtraction:(id)sender
{
    var textPayload = [_editorTextView string];
    if (!textPayload || [textPayload length] === 0) {
        [_statusLabel setStringValue:@"Editor document is empty."];
        return;
    }

    var targetSchema = [self generateJSONSchemaFromVisualTree];
    if (Object.keys(targetSchema.properties).length === 0) {
        [_statusLabel setStringValue:@"Please configure schema fields."];
        return;
    }

    [_tableData removeAllObjects];
    [_resultsTableView reloadData];

    var textStorage = [_editorTextView textStorage];
    var fullRange = CPMakeRange(0, [textStorage length]);
    [textStorage removeAttribute:CPBackgroundColorAttributeName range:fullRange];
    [textStorage removeAttribute:ExtractionIdentifierAttributeName range:fullRange];

    [_progressBar setHidden:NO];
    [_extractButton setEnabled:NO];
    [_statusLabel setStringValue:@"Processing dynamic segment chunks and auto-correcting types..."];

    var requestUrl = backendBaseURL + @"/api/extract";
    var request = [CPURLRequest requestWithURL:requestUrl
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:3600.0];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "text": textPayload,
        "schema": targetSchema,
        "prompt": [_promptTextView string],
        "model": [[_modelPopUp selectedItem] representedObject]
    };

    [request setHTTPBody:[CPString stringWithString:JSON.stringify(payload)]];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        [_progressBar setHidden:YES];
        [_extractButton setEnabled:YES];

        if (!error && data) {
            try {
                var res = JSON.parse(data);

                _highlights = res.highlights || [];
                _extractedFlatData = [CPDictionary dictionary];

                var flatJS = [self flattenObject:res.extracted_data prefix:@""];
                for (var key in flatJS) {
                    if (flatJS.hasOwnProperty(key)) {
                        [_extractedFlatData setObject:flatJS[key] forKey:key];
                    }
                }

                [self populateTableDataAndApplyHighlights];
                [_statusLabel setStringValue:@"Extraction and dynamic merging complete."];
            } catch (e) {
                [_statusLabel setStringValue:@"Schema parse error or invalid payload."];
                CPLog.error(@"Operational error: " + e.message);
            }
        } else {
            [_statusLabel setStringValue:@"Extraction connection dropped."];
        }
    }];
}

- (id)flattenObject:(id)obj prefix:(CPString)prefix
{
    var res = {};
    if (obj === null || obj === undefined) return res;

    if (Array.isArray(obj)) {
        for (var idx = 0; idx < obj.length; idx++) {
            var deepKey = (prefix === "") ? "" + idx : prefix + @"/" + idx;
            var subFlat = [self flattenObject:obj[idx] prefix:deepKey];
            Object.assign(res, subFlat);
        }
    } else if (typeof obj === 'object') {
        for (var k in obj) {
            if (obj.hasOwnProperty(k)) {
                var deepKey = (prefix === "") ? k : prefix + @"/" + k;
                var subFlat = [self flattenObject:obj[k] prefix:deepKey];
                Object.assign(res, subFlat);
            }
        }
    } else {
        res[prefix] = obj;
    }
    return res;
}

- (void)populateTableDataAndApplyHighlights
{
    [_tableData removeAllObjects];

    var textStorage = [_editorTextView textStorage];
    var docString = [_editorTextView string];

    for (var i = 0; i < _highlights.length; i++) {
        var h = _highlights[i];
        var textRange = CPMakeRange(h.offset, h.length);

        if (h.offset + h.length <= [docString length]) {
            var colorPalette = [self colorForPath:h.field_path];

            [textStorage addAttribute:CPBackgroundColorAttributeName value:colorPalette range:textRange];
            [textStorage addAttribute:ExtractionIdentifierAttributeName value:h.field_path range:textRange];

            var resolvedVal = [_extractedFlatData objectForKey:h.field_path] || @"—";

            var rowDict = [CPMutableDictionary dictionaryWithObjectsAndKeys:
                h.field_path, @"field_path",
                resolvedVal, @"value",
                h.exact_text, @"exact_text"
            ];
            [_tableData addObject:rowDict];
        }
    }

    [_resultsTableView reloadData];
}

// --- CPVIEW TABLE DELEGATE & DATASOURCE ---

- (int)numberOfRowsInTableView:(CPTableView)tableView
{
    return [_tableData count];
}

- (id)tableView:(CPTableView)tableView objectValueForTableColumn:(CPTableColumn)tableColumn row:(int)row
{
    var rowItem = [_tableData objectAtIndex:row];
    return [rowItem objectForKey:[tableColumn identifier]];
}

- (void)tableView:(CPTableView)tableView setObjectValue:(id)object forTableColumn:(CPTableColumn)tableColumn row:(int)row
{
    if (object === nil)
        return;

    var rowItem = [_tableData objectAtIndex:row];
    var oldPath = [rowItem objectForKey:@"field_path"];
    [rowItem setObject:object forKey:[tableColumn identifier]];
    
    if ([tableColumn identifier] === @"field_path") {
        for (var i = 0; i < [_highlights count]; i++) {
            var h = [_highlights objectAtIndex:i];
            if (h.field_path === oldPath) {
                h.field_path = object;
                break;
            }
        }
    }
}

- (void)tableViewSelectionDidChange:(CPNotification)aNotification
{
    var tableView = [aNotification object];
    var selectedRow = [tableView selectedRow];
    if (selectedRow === -1) return;

    var selectedItem = [_tableData objectAtIndex:selectedRow];
    var pathKey = [selectedItem objectForKey:@"field_path"];

    for (var i = 0; i < _highlights.length; i++) {
        var h = _highlights[i];
        if (h.field_path === pathKey) {
            var textRange = CPMakeRange(h.offset, h.length);
            
            _isProgrammaticSelection = YES;
            [_editorTextView setSelectedRange:textRange];
            [_editorTextView scrollRangeToVisible:textRange];
            _isProgrammaticSelection = NO;
            break;
        }
    }
}

- (BOOL)tableView:(CPTableView)tableView shouldEditTableColumn:(CPTableColumn)tableColumn row:(CPInteger)row
{
    return YES;
}

- (void)returnFocusToEditor
{
    [[_editorTextView window] makeFirstResponder:_editorTextView];
}

- (void)splitViewDidResizeSubviews:(CPNotification)aNotification
{
    if (_editorTextView)
    {
        var editorWidth = CGRectGetWidth([[_editorTextView superview] bounds]);
        if (editorWidth > 0)
            [_editorTextView setFrameSize:CGSizeMake(editorWidth, CGRectGetHeight([_editorTextView frame]))];
    }
}

// --- HIGHLIGHT STYLING BANDS ---

- (CPColor)colorForPath:(CPString)fieldPath
{
    var colors = [
        [CPColor colorWithRed:1.0 green:0.90 blue:0.90 alpha:1.0], // Rose
        [CPColor colorWithRed:1.0 green:0.95 blue:0.85 alpha:1.0], // Amber
        [CPColor colorWithRed:0.92 green:1.0 blue:0.92 alpha:1.0], // Emerald
        [CPColor colorWithRed:0.90 green:0.95 blue:1.0 alpha:1.0], // Sky
        [CPColor colorWithRed:0.95 green:0.92 blue:1.0 alpha:1.0], // Lavender
        [CPColor colorWithRed:0.90 green:1.0 blue:1.0 alpha:1.0]   // Teal
    ];

    if (!fieldPath || typeof fieldPath === 'undefined' || [fieldPath length] === 0) {
        return colors[0];
    }

    var hash = 0;
    try {
        for (var i = 0; i < [fieldPath length]; i++) {
            hash = [fieldPath characterAtIndex:i] + ((hash << 5) - hash);
        }
        var index = Math.abs(hash) % colors.length;
        if (isNaN(index)) {
            return colors[0];
        }
        return colors[index];
    } catch (e) {
        return colors[0];
    }
}

- (CPColor)focusColorForPath:(CPString)fieldPath
{
    if (!fieldPath || typeof fieldPath === 'undefined' || [fieldPath length] === 0) {
        var fallbackColors = [
            [CPColor colorWithRed:1.0 green:0.40 blue:0.40 alpha:1.0]
        ];
        return fallbackColors[0];
    }

    var hash = 0;
    for (var i = 0; i < [fieldPath length]; i++) {
        hash = [fieldPath characterAtIndex:i] + ((hash << 5) - hash);
    }
    var focusColors = [
        [CPColor colorWithRed:1.0 green:0.40 blue:0.40 alpha:1.0],
        [CPColor colorWithRed:1.0 green:0.65 blue:0.00 alpha:1.0],
        [CPColor colorWithRed:0.20 green:0.80 blue:0.20 alpha:1.0],
        [CPColor colorWithRed:0.20 green:0.60 blue:1.00 alpha:1.0],
        [CPColor colorWithRed:0.70 green:0.30 blue:0.90 alpha:1.0],
        [CPColor colorWithRed:0.00 green:0.75 blue:0.75 alpha:1.0]
    ];
    return focusColors[Math.abs(hash) % focusColors.length];
}

@end
