#import "FlutterDownloaderPlugin.h"
#import "DBManager.h"

#define STATUS_UNDEFINED 0
#define STATUS_ENQUEUED 1
#define STATUS_RUNNING 2
#define STATUS_COMPLETE 3
#define STATUS_FAILED 4
#define STATUS_CANCELED 5
#define STATUS_PAUSED 6

#define KEY_URL @"url"
#define KEY_SAVED_DIR @"saved_dir"
#define KEY_FILE_NAME @"file_name"
#define KEY_PROGRESS @"progress"
#define KEY_ID @"id"
#define KEY_IDS @"ids"
#define KEY_TASK_ID @"task_id"
#define KEY_STATUS @"status"
#define KEY_HEADERS @"headers"
#define KEY_RESUMABLE @"resumable"
#define KEY_MAX_CONCURRENT_TASKS @"max_concurrent_tasks"
#define KEY_MESSAGES @"messages"
#define KEY_SHOW_NOTIFICATION @"show_notification"
#define KEY_OPEN_FILE_FROM_NOTIFICATION @"open_file_from_notification"
#define KEY_QUERY @"query"
#define KEY_TIME_CREATED @"time_created"

#define NULL_VALUE @"<null>"

#define ERROR_NOT_INITIALIZED [FlutterError errorWithCode:@"not_initialized" message:@"initialize() must called first" details:nil]
#define ERROR_INVALID_TASK_ID [FlutterError errorWithCode:@"invalid_task_id" message:@"not found task corresponding to given task id" details:nil]

#define STEP_UPDATE 10

@interface FlutterDownloaderPlugin()<NSURLSessionTaskDelegate, NSURLSessionDownloadDelegate, UIDocumentInteractionControllerDelegate>
{
    FlutterMethodChannel *_flutterChannel;
    NSURLSession *_session;
    DBManager *_dbManager;
    BOOL _initialized;
    dispatch_queue_t _databaseQueue;
    NSMutableDictionary<NSString*, NSMutableDictionary*> *_runningTaskById;
    NSString *_allFilesDownloadedMsg;
}

@end

@implementation FlutterDownloaderPlugin

- (instancetype)initWithBinaryMessenger: (NSObject<FlutterBinaryMessenger>*) messenger;
{
    if (self = [super init]) {
        _flutterChannel = [FlutterMethodChannel
                           methodChannelWithName:@"vn.hunghd/downloader"
                           binaryMessenger:messenger];
        NSBundle *frameworkBundle = [NSBundle bundleForClass:FlutterDownloaderPlugin.class];
        NSURL *bundleUrl = [[frameworkBundle resourceURL] URLByAppendingPathComponent:@"FlutterDownloaderDatabase.bundle"];
        NSBundle *resourceBundle = [NSBundle bundleWithURL:bundleUrl];
        NSString *dbPath = [resourceBundle pathForResource:@"download_tasks" ofType:@"sql"];
        NSLog(@"database path: %@", dbPath);
        _databaseQueue = dispatch_queue_create("vn.hunghd.flutter_downloader", 0);
        _dbManager = [[DBManager alloc] initWithDatabaseFilePath:dbPath];
        _runningTaskById = [[NSMutableDictionary alloc] init];
        _initialized = NO;
    }

    return self;
}

-(FlutterMethodChannel *)channel {
    return _flutterChannel;
}

- (NSURLSession*)currentSession {
    return _session;
}

- (NSString*)downloadTaskWithURL: (NSURL*) url fileName: (NSString*) fileName andSavedDir: (NSString*) savedDir andHeaders: (NSString*) headers
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    if (headers != nil && [headers length] > 0) {
        NSError *jsonError;
        NSData *data = [headers dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&jsonError];

        for (NSString *key in json) {
            NSString *value = json[key];
            NSLog(@"Header(%@: %@)", key, value);
            [request setValue:value forHTTPHeaderField:key];
        }
    }
    NSURLSessionDownloadTask *task = [[self currentSession] downloadTaskWithRequest:request];
    NSString *taskId = [self identifierForTask:task];
    [task resume];

    return taskId;
}

- (NSString*)identifierForTask:(NSURLSessionDownloadTask*) task
{
    return [NSString stringWithFormat: @"%@.%lu", [[[self currentSession] configuration] identifier], [task taskIdentifier]];
}

- (NSString*)identifierForTask:(NSURLSessionDownloadTask*) task ofSession:(NSURLSession *)session
{
    return [NSString stringWithFormat: @"%@.%lu", [[session configuration] identifier], [task taskIdentifier]];
}

- (void)pauseTaskWithId: (NSString*)taskId
{
    NSLog(@"pause task with id: %@", taskId);
    __weak id weakSelf = self;
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data, NSArray<NSURLSessionUploadTask *> *uploads, NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            NSURLSessionTaskState state = download.state;
            NSString *taskIdValue = [weakSelf identifierForTask:download];
            if ([taskId isEqualToString:taskIdValue] && (state == NSURLSessionTaskStateRunning)) {
                int64_t bytesReceived = download.countOfBytesReceived;
                int64_t bytesExpectedToReceive = download.countOfBytesExpectedToReceive;
                int progress = round(bytesReceived * 100 / (double)bytesExpectedToReceive);
                NSDictionary *task = [weakSelf loadTaskWithId:taskIdValue];
                [download cancelByProducingResumeData:^(NSData * _Nullable resumeData) {
                    // Save partial downloaded data to a file
                    NSFileManager *fileManager = [NSFileManager defaultManager];
                    NSURL *destinationURL = [weakSelf fileUrlFromDict:task];

                    if ([fileManager fileExistsAtPath:[destinationURL path]]) {
                        [fileManager removeItemAtURL:destinationURL error:nil];
                    }

                    BOOL success = [resumeData writeToURL:destinationURL atomically:YES];
                    NSLog(@"save partial downloaded data to a file: %s", success ? "success" : "failure");
                }];

                _runningTaskById[taskId][KEY_PROGRESS] = @(progress);
                _runningTaskById[taskId][KEY_STATUS] = @(STATUS_PAUSED);
                _runningTaskById[taskId][KEY_RESUMABLE] = @(YES);

                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_PAUSED) andProgress:@(progress)];

                dispatch_sync(_databaseQueue, ^{
                    [weakSelf updateTask:taskId status:STATUS_PAUSED progress:progress resumable:YES];
                });
                return;
            }
        };
    }];
}

- (void)cancelTaskWithId: (NSString*)taskId
{
    NSLog(@"cancel task with id: %@", taskId);
    __weak id weakSelf = self;
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data, NSArray<NSURLSessionUploadTask *> *uploads, NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            NSURLSessionTaskState state = download.state;
            NSString *taskIdValue = [self identifierForTask:download];
            if ([taskId isEqualToString:taskIdValue] && (state == NSURLSessionTaskStateRunning)) {
                [download cancel];
                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_CANCELED) andProgress:@(-1)];
                dispatch_sync(_databaseQueue, ^{
                    [weakSelf updateTask:taskId status:STATUS_CANCELED progress:-1];
                });
                return;
            }
        };
    }];
}

- (void)cancelAllTasks {
    __weak id weakSelf = self;
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *data, NSArray<NSURLSessionUploadTask *> *uploads, NSArray<NSURLSessionDownloadTask *> *downloads) {
        for (NSURLSessionDownloadTask *download in downloads) {
            NSURLSessionTaskState state = download.state;
            if (state == NSURLSessionTaskStateRunning) {
                [download cancel];
                NSString *taskId = [self identifierForTask:download];
                [weakSelf sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_CANCELED) andProgress:@(-1)];
                dispatch_sync(_databaseQueue, ^{
                    [weakSelf updateTask:taskId status:STATUS_CANCELED progress:-1];
                });
            }
        };
    }];
}

- (void)sendUpdateProgressForTaskId: (NSString*)taskId inStatus: (NSNumber*) status andProgress: (NSNumber*) progress
{
    NSDictionary *info = @{KEY_TASK_ID: taskId,
                           KEY_STATUS: status,
                           KEY_PROGRESS: progress};
    [_flutterChannel invokeMethod:@"updateProgress" arguments:info];
}

- (BOOL)openDocumentWithURL:(NSURL*)url {
    NSLog(@"try to open file in url: %@", url);
    BOOL result = NO;
    UIDocumentInteractionController* tmpDocController = [UIDocumentInteractionController
                                                         interactionControllerWithURL:url];
    if (tmpDocController)
    {
        NSLog(@"initialize UIDocumentInteractionController successfully");
        tmpDocController.delegate = self;
        result = [tmpDocController presentPreviewAnimated:YES];
    }
    return result;
}

- (NSURL*)fileUrlFromDict:(NSDictionary*)dict
{
    NSString *url = dict[KEY_URL];
    NSString *savedDir = dict[KEY_SAVED_DIR];
    NSString *filename = dict[KEY_FILE_NAME];
    if (filename == (NSString*) [NSNull null] || [NULL_VALUE isEqualToString: filename]) {
        filename = [NSURL URLWithString:url].lastPathComponent;
    }
    NSURL *savedDirURL = [NSURL fileURLWithPath:savedDir];
    return [savedDirURL URLByAppendingPathComponent:filename];
}

- (long)currentTimeInMilliseconds
{
    return [[NSDate date] timeIntervalSince1970]*1000;
}

# pragma mark - Database Accessing

- (void) addNewTask: (NSString*) taskId url: (NSString*) url status: (int) status progress: (int) progress filename: (NSString*) filename savedDir: (NSString*) savedDir headers: (NSString*) headers resumable: (BOOL) resumable showNotification: (BOOL) showNotification openFileFromNotification: (BOOL) openFileFromNotification
{
    NSString *query = [NSString stringWithFormat:@"INSERT INTO task (task_id,url,status,progress,file_name,saved_dir,headers,resumable,show_notification,open_file_from_notification,time_created) VALUES (\"%@\",\"%@\",%d,%d,\"%@\",\"%@\",\"%@\",%d,%d,%d,%ld)", taskId, url, status, progress, filename, savedDir, headers, resumable ? 1 : 0, showNotification ? 1 : 0, openFileFromNotification ? 1 : 0, [self currentTimeInMilliseconds]];
    [_dbManager executeQuery:query];
    if (_dbManager.affectedRows != 0) {
        NSLog(@"Query was executed successfully. Affected rows = %d", _dbManager.affectedRows);
    } else {
        NSLog(@"Could not execute the query.");
    }
}

- (void) updateTask: (NSString*) taskId status: (int) status progress: (int) progress
{
    NSString *query = [NSString stringWithFormat:@"UPDATE task SET status=%d, progress=%d WHERE task_id=\"%@\"", status, progress, taskId];
    [_dbManager executeQuery:query];
    if (_dbManager.affectedRows != 0) {
        NSLog(@"Query was executed successfully. Affected rows = %d", _dbManager.affectedRows);
    } else {
        NSLog(@"Could not execute the query.");
    }
}

- (void) updateTask: (NSString*) taskId status: (int) status progress: (int) progress resumable: (BOOL) resumable {
    NSString *query = [NSString stringWithFormat:@"UPDATE task SET status=%d, progress=%d, resumable=%d WHERE task_id=\"%@\"", status, progress, resumable ? 1 : 0, taskId];
    [_dbManager executeQuery:query];
    if (_dbManager.affectedRows != 0) {
        NSLog(@"Query was executed successfully. Affected rows = %d", _dbManager.affectedRows);
    } else {
        NSLog(@"Could not execute the query.");
    }
}

- (void) updateTask: (NSString*) currentTaskId newTaskId: (NSString*) newTaskId status: (int) status resumable: (BOOL) resumable {
    NSString *query = [NSString stringWithFormat:@"UPDATE task SET task_id=\"%@\", status=%d, resumable=%d, time_created=%ld WHERE task_id=\"%@\"", newTaskId, status, resumable ? 1 : 0, [self currentTimeInMilliseconds], currentTaskId];
    [_dbManager executeQuery:query];
    if (_dbManager.affectedRows != 0) {
        NSLog(@"Query was executed successfully. Affected rows = %d", _dbManager.affectedRows);
    } else {
        NSLog(@"Could not execute the query.");
    }
}

- (void) updateTask: (NSString*) taskId resumable: (BOOL) resumable
{
    NSString *query = [NSString stringWithFormat:@"UPDATE task SET resumable=%d WHERE task_id=\"%@\"", resumable ? 1 : 0, taskId];
    [_dbManager executeQuery:query];
    if (_dbManager.affectedRows != 0) {
        NSLog(@"Query was executed successfully. Affected rows = %d", _dbManager.affectedRows);
    } else {
        NSLog(@"Could not execute the query.");
    }
}

- (NSArray*)loadAllTasks
{
    NSString *query = @"SELECT * FROM task";
    NSArray *records = [[NSArray alloc] initWithArray:[_dbManager loadDataFromDB:query]];
    NSLog(@"Load tasks successfully");
    NSMutableArray *results = [NSMutableArray new];
    for(NSArray *record in records) {
        [results addObject:[self taskDictFromRecordArray:record]];
    }
    return results;
}

- (NSArray*)loadTasksWithRawQuery: (NSString*)query
{
    NSArray *records = [[NSArray alloc] initWithArray:[_dbManager loadDataFromDB:query]];
    NSLog(@"Load tasks successfully");
    NSMutableArray *results = [NSMutableArray new];
    for(NSArray *record in records) {
        [results addObject:[self taskDictFromRecordArray:record]];
    }
    return results;
}

- (NSDictionary*)loadTaskWithId:(NSString*)taskId
{
    // check task in memory-cache first
    if ([_runningTaskById objectForKey:taskId]) {
        return [_runningTaskById objectForKey:taskId];
    } else {
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM task WHERE task_id = \"%@\" ORDER BY id DESC LIMIT 1", taskId];
        NSArray *records = [[NSArray alloc] initWithArray:[_dbManager loadDataFromDB:query]];
        NSLog(@"Load task successfully");
        if (records != nil && [records count] > 0) {
            NSArray *record = [records firstObject];
            NSDictionary *task = [self taskDictFromRecordArray:record];
            [_runningTaskById setObject:[NSMutableDictionary dictionaryWithDictionary:task] forKey:taskId];
            return task;
        }
        return nil;
    }
}

- (NSDictionary*) taskDictFromRecordArray:(NSArray*)record
{
    NSString *taskId = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"task_id"]];
    int status = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"status"]] intValue];
    int progress = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"progress"]] intValue];
    NSString *url = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"url"]];
    NSString *filename = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"file_name"]];
    NSString *savedDir = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"saved_dir"]];
    NSString *headers = [record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"headers"]];
    int resumable = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"resumable"]] intValue];
    int showNotification = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"show_notification"]] intValue];
    int openFileFromNotification = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"open_file_from_notification"]] intValue];
    long long timeCreated = [[record objectAtIndex:[_dbManager.arrColumnNames indexOfObject:@"time_created"]] longLongValue];
    return [NSDictionary dictionaryWithObjectsAndKeys:taskId, KEY_TASK_ID, @(status), KEY_STATUS, @(progress), KEY_PROGRESS, url, KEY_URL, filename, KEY_FILE_NAME, headers, KEY_HEADERS, savedDir, KEY_SAVED_DIR, [NSNumber numberWithBool:(resumable == 1)], KEY_RESUMABLE, [NSNumber numberWithBool:(showNotification == 1)], KEY_SHOW_NOTIFICATION, [NSNumber numberWithBool:(openFileFromNotification == 1)], KEY_OPEN_FILE_FROM_NOTIFICATION, @(timeCreated), KEY_TIME_CREATED, nil];
}

# pragma mark - FlutterPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {

    FlutterDownloaderPlugin* instance = [[FlutterDownloaderPlugin alloc] initWithBinaryMessenger:registrar.messenger];
    [registrar addMethodCallDelegate:instance channel:[instance channel]];
    [registrar addApplicationDelegate: instance];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    NSLog(@"methodCallHandler: %@", call.method);
    if ([@"initialize" isEqualToString:call.method]) {
        if (!_initialized) {
            NSNumber *maxConcurrentTasks = call.arguments[KEY_MAX_CONCURRENT_TASKS];
            NSDictionary *messages = call.arguments[KEY_MESSAGES];

            _allFilesDownloadedMsg = messages[@"all_finished"];

            NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[NSString stringWithFormat:@"%@.download.background.%f", NSBundle.mainBundle.bundleIdentifier, [[NSDate date] timeIntervalSince1970]]];
            sessionConfiguration.HTTPMaximumConnectionsPerHost = [maxConcurrentTasks intValue];
            _session = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
            NSLog(@"init NSURLSession with id: %@", [[_session configuration] identifier]);
            _initialized = YES;
        }
        result([NSNull null]);
    } else if ([@"enqueue" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *urlString = call.arguments[KEY_URL];
            NSString *savedDir = call.arguments[KEY_SAVED_DIR];
            NSString *fileName = call.arguments[KEY_FILE_NAME];
            NSString *headers = call.arguments[KEY_HEADERS];
            NSNumber *showNotification = call.arguments[KEY_SHOW_NOTIFICATION];
            NSNumber *openFileFromNotification = call.arguments[KEY_OPEN_FILE_FROM_NOTIFICATION];

            NSString *taskId = [self downloadTaskWithURL:[NSURL URLWithString:urlString] fileName:fileName andSavedDir:savedDir andHeaders:headers];

            [_runningTaskById setObject: [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                          urlString, KEY_URL,
                                          fileName, KEY_FILE_NAME,
                                          savedDir, KEY_SAVED_DIR,
                                          headers, KEY_HEADERS,
                                          showNotification, KEY_SHOW_NOTIFICATION,
                                          openFileFromNotification, KEY_OPEN_FILE_FROM_NOTIFICATION,
                                          @(NO), KEY_RESUMABLE,
                                          @(STATUS_ENQUEUED), KEY_STATUS,
                                          @(0), KEY_PROGRESS, nil]
                                 forKey:taskId];

            __weak id weakSelf = self;
            dispatch_sync(_databaseQueue, ^{
                [weakSelf addNewTask:taskId url:urlString status:STATUS_ENQUEUED progress:0 filename:fileName savedDir:savedDir headers:headers resumable:NO showNotification: [showNotification boolValue] openFileFromNotification: [openFileFromNotification boolValue]];
            });
            result(taskId);
            [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_ENQUEUED) andProgress:@0];
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"loadTasks" isEqualToString:call.method]) {
        if (_initialized) {
            __weak id weakSelf = self;
            dispatch_sync(_databaseQueue, ^{
                NSArray* tasks = [weakSelf loadAllTasks];
                result(tasks);
            });
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"loadTasksWithRawQuery" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *query = call.arguments[KEY_QUERY];
            __weak id weakSelf = self;
            dispatch_sync(_databaseQueue, ^{
                NSArray* tasks = [weakSelf loadTasksWithRawQuery:query];
                result(tasks);
            });
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"cancel" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *taskId = call.arguments[KEY_TASK_ID];
            [self cancelTaskWithId:taskId];
            result([NSNull null]);
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"cancelAll" isEqualToString:call.method]) {
        if (_initialized) {
            [self cancelAllTasks];
            result([NSNull null]);
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"pause" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *taskId = call.arguments[KEY_TASK_ID];
            [self pauseTaskWithId:taskId];
            result([NSNull null]);
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"resume" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *taskId = call.arguments[KEY_TASK_ID];
            NSDictionary* taskDict = [self loadTaskWithId:taskId];
            if (taskDict != nil) {
                NSNumber* status = taskDict[KEY_STATUS];
                if ([status intValue] == STATUS_PAUSED) {
                    NSURL *partialFileURL = [self fileUrlFromDict:taskDict];

                    NSLog(@"Try to load resume data at url: %@", partialFileURL);

                    NSData *resumeData = [NSData dataWithContentsOfURL:partialFileURL];

                    if (resumeData != nil) {
                        NSURLSessionDownloadTask *task = [[self currentSession] downloadTaskWithResumeData:resumeData];
                        NSString *newTaskId = [self identifierForTask:task];
                        [task resume];

                        // update memory-cache, assign a new taskId for paused task
                        NSMutableDictionary *newTask = [NSMutableDictionary dictionaryWithDictionary:taskDict];
                        newTask[KEY_STATUS] = @(STATUS_RUNNING);
                        newTask[KEY_RESUMABLE] = @(NO);
                        [_runningTaskById setObject:newTask forKey:newTaskId];
                        [_runningTaskById removeObjectForKey:taskId];

                        result(newTaskId);

                        __weak id weakSelf = self;
                        dispatch_sync(_databaseQueue, ^{
                            [weakSelf updateTask:taskId newTaskId:newTaskId status:STATUS_RUNNING resumable:NO];
                            NSDictionary *task = [weakSelf loadTaskWithId:newTaskId];
                            NSNumber *progress = task[KEY_PROGRESS];
                            [weakSelf sendUpdateProgressForTaskId:newTaskId inStatus:@(STATUS_RUNNING) andProgress:progress];
                        });
                    } else {
                        result([FlutterError errorWithCode:@"invalid_data"
                                                   message:@"not found resume data, this task cannot be resumed"
                                                   details:nil]);
                    }
                } else {
                    result([FlutterError errorWithCode:@"invalid_status"
                                               message:@"only paused task can be resumed"
                                               details:nil]);
                }
            } else {
                result(ERROR_INVALID_TASK_ID);
            }
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"retry" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *taskId = call.arguments[KEY_TASK_ID];
            NSDictionary* taskDict = [self loadTaskWithId:taskId];
            if (taskDict != nil) {
                NSNumber* status = taskDict[KEY_STATUS];
                if ([status intValue] == STATUS_FAILED) {
                    NSString *urlString = taskDict[KEY_URL];
                    NSString *savedDir = taskDict[KEY_SAVED_DIR];
                    NSString *fileName = taskDict[KEY_FILE_NAME];
                    NSString *headers = taskDict[KEY_HEADERS];

                    NSString *newTaskId = [self downloadTaskWithURL:[NSURL URLWithString:urlString] fileName:fileName andSavedDir:savedDir andHeaders:headers];

                    // update memory-cache
                    NSMutableDictionary *newTask = [NSMutableDictionary dictionaryWithDictionary:taskDict];
                    newTask[KEY_STATUS] = @(STATUS_ENQUEUED);
                    newTask[KEY_PROGRESS] = @(0);
                    newTask[KEY_RESUMABLE] = @(NO);
                    [_runningTaskById setObject:newTask forKey:newTaskId];
                    [_runningTaskById removeObjectForKey:taskId];

                    __weak id weakSelf = self;
                    dispatch_sync(_databaseQueue, ^{
                        [weakSelf updateTask:taskId newTaskId:newTaskId status:STATUS_ENQUEUED resumable:NO];
                    });
                    result(newTaskId);
                    [self sendUpdateProgressForTaskId:newTaskId inStatus:@(STATUS_ENQUEUED) andProgress:@(0)];
                } else {
                    result([FlutterError errorWithCode:@"invalid_status"
                                               message:@"only failed task can be retried"
                                               details:nil]);
                }
            } else {
                result(ERROR_INVALID_TASK_ID);
            }
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else if ([@"open" isEqualToString:call.method]) {
        if (_initialized) {
            NSString *taskId = call.arguments[KEY_TASK_ID];
            NSDictionary* taskDict = [self loadTaskWithId:taskId];
            if (taskDict != nil) {
                NSNumber* status = taskDict[KEY_STATUS];
                if ([status intValue] == STATUS_COMPLETE) {
                    NSURL *downloadedFileURL = [self fileUrlFromDict:taskDict];

                    BOOL success = [self openDocumentWithURL:downloadedFileURL];
                    result([NSNumber numberWithBool:success]);
                } else {
                    result([FlutterError errorWithCode:@"invalid_status"
                                               message:@"only success task can be opened"
                                               details:nil]);
                }
            } else {
                result(ERROR_INVALID_TASK_ID);
            }
        } else {
            result(ERROR_NOT_INITIALIZED);
        }
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (BOOL)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    self.backgroundTransferCompletionHandler = completionHandler;
    return YES;
}

- (void)applicationWillTerminate:(nonnull UIApplication *)application
{
    NSLog(@"applicationWillTerminate:");
    for (NSString* key in _runningTaskById) {
        [self updateTask:key status:STATUS_CANCELED progress:-1];
    }
    _session = nil;
    _flutterChannel = nil;
    _dbManager = nil;
    _databaseQueue = nil;
    _runningTaskById = nil;
}

# pragma mark - NSURLSessionTaskDelegate
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown) {
        NSLog(@"Unknown transfer size");
    } else {
        NSString *taskId = [self identifierForTask:downloadTask];
        int progress = round(totalBytesWritten * 100 / (double)totalBytesExpectedToWrite);
        NSNumber *lastProgress = _runningTaskById[taskId][KEY_PROGRESS];
        if (([lastProgress intValue] == 0 || (progress > [lastProgress intValue] + STEP_UPDATE) || progress == 100) && progress != [lastProgress intValue]) {
            [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_RUNNING) andProgress:@(progress)];
            _runningTaskById[taskId][KEY_PROGRESS] = @(progress);
        }
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    NSString *taskId = [self identifierForTask:downloadTask ofSession:session];
    NSDictionary *task = [self loadTaskWithId:taskId];
    NSURL *destinationURL = [self fileUrlFromDict:task];

    [_runningTaskById removeObjectForKey:taskId];

    NSError *error;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:[destinationURL path]]) {
        [fileManager removeItemAtURL:destinationURL error:nil];
    }

    BOOL success = [fileManager copyItemAtURL:location
                                        toURL:destinationURL
                                        error:&error];

    __weak id weakSelf = self;
    if (success) {
        [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_COMPLETE) andProgress:@100];
        dispatch_sync(_databaseQueue, ^{
            [weakSelf updateTask:taskId status:STATUS_COMPLETE progress:100];
        });
    } else {
        NSLog(@"Unable to copy temp file. Error: %@", [error localizedDescription]);
        [self sendUpdateProgressForTaskId:taskId inStatus:@(STATUS_FAILED) andProgress:@(-1)];
        dispatch_sync(_databaseQueue, ^{
            [weakSelf updateTask:taskId status:STATUS_FAILED progress:-1];
        });
    }
}

-(void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error != nil) {
        NSLog(@"Download completed with error: %@", [error localizedDescription]);
        NSString *taskId = [self identifierForTask:task ofSession:session];
        NSDictionary *task = [self loadTaskWithId:taskId];
        NSNumber *resumable = task[KEY_RESUMABLE];
        if (![resumable boolValue]) {
            int status = [error code] == -999 ? STATUS_CANCELED : STATUS_FAILED;
            [_runningTaskById removeObjectForKey:taskId];
            [self sendUpdateProgressForTaskId:taskId inStatus:@(status) andProgress:@(-1)];
            __weak id weakSelf = self;
            dispatch_sync(_databaseQueue, ^{
                [weakSelf updateTask:taskId status:status progress:-1];
            });
        }
    }
}

-(void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    NSLog(@"URLSessionDidFinishEventsForBackgroundURLSession:");
    // Check if all download tasks have been finished.
    [[self currentSession] getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        if ([downloadTasks count] == 0) {
            NSLog(@"all download tasks have been finished");

            if (self.backgroundTransferCompletionHandler != nil) {
                // Copy locally the completion handler.
                void(^completionHandler)(void) = self.backgroundTransferCompletionHandler;

                // Make nil the backgroundTransferCompletionHandler.
                self.backgroundTransferCompletionHandler = nil;

                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    // Call the completion handler to tell the system that there are no other background transfers.
                    completionHandler();

                    // Show a local notification when all downloads are over.
                    UILocalNotification *localNotification = [[UILocalNotification alloc] init];
                    localNotification.alertBody = _allFilesDownloadedMsg;
                    [[UIApplication sharedApplication] presentLocalNotificationNow:localNotification];
                }];
            }
        }
    }];
}


# pragma mark - UIDocumentInteractionControllerDelegate

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    return [UIApplication sharedApplication].delegate.window.rootViewController;
}

- (void)documentInteractionController:(UIDocumentInteractionController *)controller willBeginSendingToApplication:(NSString *)application
{
    NSLog(@"Send the document to app %@  ...", application);
}

- (void)documentInteractionController:(UIDocumentInteractionController *)controller didEndSendingToApplication:(NSString *)application
{
    NSLog(@"Finished sending the document to app %@  ...", application);

}

- (void)documentInteractionControllerDidDismissOpenInMenu:(UIDocumentInteractionController *)controller
{
    NSLog(@"Finished previewing the document");
}

@end
