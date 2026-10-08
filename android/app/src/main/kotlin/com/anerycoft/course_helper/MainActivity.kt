package com.anerycoft.coursehelper

import android.content.ContentValues
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity: FlutterActivity() {
    private val fileExportExecutor = Executors.newSingleThreadExecutor()

    private companion object {
        const val FILE_EXPORT_CHANNEL = "course_helper/file_export"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 同意百度定位 SDK 隐私政策
        try {
            val locationClientClass = Class.forName("com.baidu.location.LocationClient")
            val setAgreePrivacyMethod = locationClientClass.getMethod("setAgreePrivacy", Boolean::class.javaPrimitiveType)
            setAgreePrivacyMethod.invoke(null, true)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_EXPORT_CHANNEL
        ).setMethodCallHandler(::handleFileExportCall)
    }

    private fun handleFileExportCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAndroidSdkInt" -> result.success(Build.VERSION.SDK_INT)

            "savePdfToDownloads" -> {
                val sourcePath = call.argument<String>("sourcePath")
                val displayName = call.argument<String>("displayName")
                val subdirectory = call.argument<String>("subdirectory")

                if (sourcePath.isNullOrBlank() || displayName.isNullOrBlank()) {
                    result.error("invalid_args", "缺少 sourcePath 或 displayName", null)
                    return
                }

                fileExportExecutor.execute {
                    try {
                        val savedPath = savePdfToDownloads(
                            sourcePath = sourcePath,
                            displayName = displayName,
                            subdirectory = subdirectory
                        )
                        runOnUiThread { result.success(savedPath) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("save_pdf_failed", e.message, null) }
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDestroy() {
        fileExportExecutor.shutdown()
        super.onDestroy()
    }

    private fun savePdfToDownloads(
        sourcePath: String,
        displayName: String,
        subdirectory: String?
    ): String {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) {
            throw IOException("源文件不存在: $sourcePath")
        }

        val folderName = subdirectory?.trim()?.ifBlank { "Course Helper" } ?: "Course Helper"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = applicationContext.contentResolver
            val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$folderName"
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
                put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }

            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IOException("无法创建下载文件")

            try {
                resolver.openOutputStream(uri)?.use { outputStream ->
                    FileInputStream(sourceFile).use { inputStream ->
                        inputStream.copyTo(outputStream)
                    }
                } ?: throw IOException("无法打开下载目录输出流")

                val completedValues = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, completedValues, null, null)
                return "Downloads/$folderName/$displayName"
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        }

        val downloadDir =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val targetDir = File(downloadDir, folderName)
        if (!targetDir.exists() && !targetDir.mkdirs()) {
            throw IOException("无法创建目录: ${targetDir.absolutePath}")
        }

        val targetFile = File(targetDir, displayName)
        FileInputStream(sourceFile).use { inputStream ->
            targetFile.outputStream().use { outputStream ->
                inputStream.copyTo(outputStream)
            }
        }
        MediaScannerConnection.scanFile(
            this,
            arrayOf(targetFile.absolutePath),
            arrayOf("application/pdf"),
            null
        )
        return targetFile.absolutePath
    }
}
