package vn.hunghd.flutterdownloader;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.Bundle;
import android.provider.BaseColumns;
import android.support.v4.content.LocalBroadcastManager;
import android.util.Log;


import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingDeque;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

import androidx.work.BackoffPolicy;
import androidx.work.Configuration;
import androidx.work.Constraints;
import androidx.work.Data;
import androidx.work.NetworkType;
import androidx.work.OneTimeWorkRequest;
import androidx.work.WorkManager;
import androidx.work.WorkRequest;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.PluginRegistry;

public class FlutterDownloaderPlugin implements MethodCallHandler {
    private static final String CHANNEL = "vn.hunghd/downloader";
    private static final String TAG = "flutter_download_task";

    private MethodChannel flutterChannel;
    private TaskDbHelper dbHelper;

    public static int maximumConcurrentTask;

    private final BroadcastReceiver updateProcessEventReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String id = intent.getStringExtra(DownloadWorker.EXTRA_ID);
            int progress = intent.getIntExtra(DownloadWorker.EXTRA_PROGRESS, 0);
            int status = intent.getIntExtra(DownloadWorker.EXTRA_STATUS, DownloadStatus.UNDEFINED);
            sendUpdateProgress(id, status, progress);
        }
    };

    private FlutterDownloaderPlugin(Context context, BinaryMessenger messenger) {
        flutterChannel = new MethodChannel(messenger, CHANNEL);
        flutterChannel.setMethodCallHandler(this);
        dbHelper = TaskDbHelper.getInstance(context);
        Log.d(TAG, "maximumConcurrentTask = " + maximumConcurrentTask);
        WorkManager.initialize(context, new Configuration.Builder()
                .setExecutor(Executors.newFixedThreadPool(Math.max(maximumConcurrentTask, 1)))
                .build());
    }

    @SuppressLint("NewApi")
    public static void registerWith(PluginRegistry.Registrar registrar) {
        final FlutterDownloaderPlugin plugin = new FlutterDownloaderPlugin(registrar.context(), registrar.messenger());
        registrar.activity().getApplication()
                .registerActivityLifecycleCallbacks(new Application.ActivityLifecycleCallbacks() {
                    @Override
                    public void onActivityCreated(Activity activity, Bundle bundle) {

                    }

                    @Override
                    public void onActivityStarted(Activity activity) {
                        plugin.onStart(activity);
                    }

                    @Override
                    public void onActivityResumed(Activity activity) {

                    }

                    @Override
                    public void onActivityPaused(Activity activity) {

                    }

                    @Override
                    public void onActivityStopped(Activity activity) {
                        plugin.onStop(activity);
                    }

                    @Override
                    public void onActivitySaveInstanceState(Activity activity, Bundle bundle) {

                    }

                    @Override
                    public void onActivityDestroyed(Activity activity) {

                    }
                });
    }

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if (call.method.equals("enqueue")) {
            String url = call.argument("url");
            String savedDir = call.argument("saved_dir");
            String filename = call.argument("file_name");
            String headers = call.argument("headers");
            boolean showNotification = call.argument("show_notification");
            boolean clickToOpenDownloadedFile = call.argument("click_to_open_downloaded_file");
            WorkRequest request = buildRequest(url, savedDir, filename, headers, showNotification, clickToOpenDownloadedFile, false);
            String taskId = request.getId().toString();
            sendUpdateProgress(taskId, DownloadStatus.ENQUEUED, 0);
            insertOrUpdateNewTask(taskId, url, DownloadStatus.ENQUEUED, 0, filename, savedDir, headers, showNotification, clickToOpenDownloadedFile);
            WorkManager.getInstance().enqueue(request);
            result.success(taskId);
        } else if (call.method.equals("loadTasks")) {
            List<DownloadTask> tasks = loadAllTasks();
            List<Map> array = new ArrayList<>();
            for (DownloadTask task : tasks) {
                Map<String, Object> item = new HashMap<>();
                item.put("task_id", task.taskId);
                item.put("status", task.status);
                item.put("progress", task.progress);
                item.put("url", task.url);
                item.put("file_name", task.filename);
                item.put("saved_dir", task.savedDir);
                array.add(item);
            }
            result.success(array);
        } else if (call.method.equals("cancel")) {
            String taskId = call.argument("task_id");
            cancel(taskId);
            result.success(null);
        } else if (call.method.equals("cancelAll")) {
            cancelAll();
            result.success(null);
        } else if (call.method.equals("pause")) {
            String taskId = call.argument("task_id");
            pause(taskId);
            result.success(null);
        } else if (call.method.equals("resume")) {
            String taskId = call.argument("task_id");
            String newTaskId = resume(taskId);
            result.success(newTaskId);
        } else {
            result.notImplemented();
        }
    }

    private void onStart(Context context) {
        LocalBroadcastManager.getInstance(context)
                .registerReceiver(updateProcessEventReceiver,
                        new IntentFilter(DownloadWorker.UPDATE_PROCESS_EVENT));
    }

    private void onStop(Context context) {
        LocalBroadcastManager.getInstance(context)
                .unregisterReceiver(updateProcessEventReceiver);
    }

    private WorkRequest buildRequest(String url, String savedDir, String filename, String headers, boolean showNotification, boolean clickToOpenDownloadedFile, boolean isResume) {
        WorkRequest request = new OneTimeWorkRequest.Builder(DownloadWorker.class)
                .setConstraints(new Constraints.Builder()
                        .setRequiresStorageNotLow(true)
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build())
                .addTag(TAG)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 5, TimeUnit.SECONDS)
                .setInputData(new Data.Builder()
                        .putString(DownloadWorker.ARG_URL, url)
                        .putString(DownloadWorker.ARG_SAVED_DIR, savedDir)
                        .putString(DownloadWorker.ARG_FILE_NAME, filename)
                        .putString(DownloadWorker.ARG_HEADERS, headers)
                        .putBoolean(DownloadWorker.ARG_SHOW_NOTIFICATION, showNotification)
                        .putBoolean(DownloadWorker.ARG_CLICK_TO_OPEN_DOWNLOADED_FILE, clickToOpenDownloadedFile)
                        .putBoolean(DownloadWorker.ARG_IS_RESUME, isResume)
                        .build()
                )
                .build();
        return request;
    }

    private void cancel(String taskId) {
        WorkManager.getInstance().cancelWorkById(UUID.fromString(taskId));
    }

    private void cancelAll() {
        WorkManager.getInstance().cancelAllWorkByTag(TAG);
    }

    private void pause(String taskId) {
        setTaskResumable(taskId, true);
        WorkManager.getInstance().cancelWorkById(UUID.fromString(taskId));
    }

    private String resume(String taskId) {
        DownloadTask task = loadTask(taskId);
        String filename = task.filename;
        if (filename == null) {
            filename = task.url.substring(task.url.lastIndexOf("/") + 1, task.url.length());
        }
        String partialFilePath = task.savedDir + File.separator + filename;
        File partialFile = new File(partialFilePath);
        if (partialFile.exists()) {
            WorkRequest request = buildRequest(task.url, task.savedDir, task.filename, task.headers, task.showNotification, task.clickToOpenDownloadedFile, true);
            String newTaskId = request.getId().toString();
            sendUpdateProgress(newTaskId, DownloadStatus.ENQUEUED, task.progress);
            updateTask(taskId, newTaskId, DownloadStatus.ENQUEUED, task.progress, false);
            WorkManager.getInstance().enqueue(request);
            return newTaskId;
        }
        return null;
    }

    private void sendUpdateProgress(String id, int status, int progress) {
        Map<String, Object> args = new HashMap<>();
        args.put("task_id", id);
        args.put("status", status);
        args.put("progress", progress);
        flutterChannel.invokeMethod("updateProgress", args);
    }

    private void insertOrUpdateNewTask(String taskId, String url, int status, int progress, String fileName,
                                       String savedDir, String headers, boolean showNotification, boolean clickToOpenDownloadedFile) {
        SQLiteDatabase db = dbHelper.getWritableDatabase();

        ContentValues values = new ContentValues();
        values.put(TaskContract.TaskEntry.COLUMN_NAME_TASK_ID, taskId);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_URL, url);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_STATUS, status);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_PROGRESS, progress);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_FILE_NAME, fileName);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_SAVED_DIR, savedDir);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_HEADERS, headers);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_SHOW_NOTIFICATION, showNotification ? 1 : 0);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_CLICK_TO_OPEN_DOWNLOADED_FILE, clickToOpenDownloadedFile ? 1 : 0);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_RESUMABLE, 0);

        db.insertWithOnConflict(TaskContract.TaskEntry.TABLE_NAME, null, values, SQLiteDatabase.CONFLICT_REPLACE);
    }

    private void setTaskResumable(String taskId, boolean resumable) {
        SQLiteDatabase db = dbHelper.getWritableDatabase();

        ContentValues values = new ContentValues();
        values.put(TaskContract.TaskEntry.COLUMN_NAME_RESUMABLE, resumable ? 1 : 0);

        db.beginTransaction();
        try {
            db.update(TaskContract.TaskEntry.TABLE_NAME, values, TaskContract.TaskEntry.COLUMN_NAME_TASK_ID + " = ?", new String[]{taskId});
            db.setTransactionSuccessful();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            db.endTransaction();
        }
    }

    final private String[] projection = new String[]{
            BaseColumns._ID,
            TaskContract.TaskEntry.COLUMN_NAME_TASK_ID,
            TaskContract.TaskEntry.COLUMN_NAME_PROGRESS,
            TaskContract.TaskEntry.COLUMN_NAME_STATUS,
            TaskContract.TaskEntry.COLUMN_NAME_URL,
            TaskContract.TaskEntry.COLUMN_NAME_FILE_NAME,
            TaskContract.TaskEntry.COLUMN_NAME_SAVED_DIR,
            TaskContract.TaskEntry.COLUMN_NAME_HEADERS,
            TaskContract.TaskEntry.COLUMN_NAME_RESUMABLE,
            TaskContract.TaskEntry.COLUMN_NAME_CLICK_TO_OPEN_DOWNLOADED_FILE,
            TaskContract.TaskEntry.COLUMN_NAME_SHOW_NOTIFICATION
    };

    private List<DownloadTask> loadAllTasks() {
        SQLiteDatabase db = dbHelper.getReadableDatabase();

        Cursor cursor = db.query(
                TaskContract.TaskEntry.TABLE_NAME,
                projection,
                null,
                null,
                null,
                null,
                null
        );

        List<DownloadTask> result = new ArrayList<>();
        while (cursor.moveToNext()) {
            result.add(parseCursor(cursor));
        }
        cursor.close();
        return result;
    }

    private DownloadTask loadTask(String taskId) {
        SQLiteDatabase db = dbHelper.getReadableDatabase();

        String whereClause = TaskContract.TaskEntry.COLUMN_NAME_TASK_ID + " = ?";
        String[] whereArgs = new String[]{taskId};

        Cursor cursor = db.query(
                TaskContract.TaskEntry.TABLE_NAME,
                projection,
                whereClause,
                whereArgs,
                null,
                null,
                BaseColumns._ID + " DESC",
                "1"
        );

        DownloadTask result = null;
        while (cursor.moveToNext()) {
            result = parseCursor(cursor);
        }
        cursor.close();
        return result;
    }

    private void updateTask(String currentTaskId, String newTaskId, int status, int progress, boolean resumable) {
        SQLiteDatabase db = dbHelper.getWritableDatabase();

        ContentValues values = new ContentValues();
        values.put(TaskContract.TaskEntry.COLUMN_NAME_TASK_ID, newTaskId);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_STATUS, status);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_PROGRESS, progress);
        values.put(TaskContract.TaskEntry.COLUMN_NAME_RESUMABLE, resumable ? 1 : 0);

        db.beginTransaction();
        try {
            db.update(TaskContract.TaskEntry.TABLE_NAME, values, TaskContract.TaskEntry.COLUMN_NAME_TASK_ID + " = ?", new String[]{currentTaskId});
            db.setTransactionSuccessful();
        } catch (Exception e) {
            e.printStackTrace();
        } finally {
            db.endTransaction();
        }
    }

    DownloadTask parseCursor(Cursor cursor) {
        int primaryId = cursor.getInt(cursor.getColumnIndexOrThrow(BaseColumns._ID));
        String taskId = cursor.getString(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_TASK_ID));
        int status = cursor.getInt(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_STATUS));
        int progress = cursor.getInt(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_PROGRESS));
        String url = cursor.getString(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_URL));
        String filename = cursor.getString(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_FILE_NAME));
        String savedDir = cursor.getString(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_SAVED_DIR));
        String headers = cursor.getString(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_HEADERS));
        int resumable = cursor.getShort(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_RESUMABLE));
        int showNotification = cursor.getShort(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_SHOW_NOTIFICATION));
        int clickToOpenDownloadedFile = cursor.getShort(cursor.getColumnIndexOrThrow(TaskContract.TaskEntry.COLUMN_NAME_CLICK_TO_OPEN_DOWNLOADED_FILE));
        return new DownloadTask(primaryId, taskId, status, progress, url, filename, savedDir, headers, resumable == 1, showNotification == 1, clickToOpenDownloadedFile == 1);
    }
}
